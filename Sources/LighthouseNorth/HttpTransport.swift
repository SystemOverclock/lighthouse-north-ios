import Foundation

// ---------------------------------------------------------------------------
// Ports de infra (tempo/aleatoriedade/agenda) — injetáveis p/ testes
// ---------------------------------------------------------------------------

/// Fonte de tempo — injetável para testes.
public protocol SdkClock: Sendable {
    func now() -> Date
}

/// Fonte real (wall clock).
public struct SystemSdkClock: SdkClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Clock fixo para testes.
public final class FakeSdkClock: SdkClock, @unchecked Sendable {
    public var date: Date
    public init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }
    public func now() -> Date { date }
}

/// Fonte de aleatoriedade para jitter (heartbeat e backoff).
public protocol SdkRandom: Sendable {
    func nextDouble() -> Double
}

/// Fonte real.
public struct SystemSdkRandom: SdkRandom {
    public init() {}
    public func nextDouble() -> Double { Double.random(in: 0...1) }
}

/// Devolve sempre o mesmo valor — pina os fatores de jitter nos limites.
public struct FixedSdkRandom: SdkRandom {
    public let value: Double
    public init(_ value: Double) {
        precondition(value >= 0 && value <= 1)
        self.value = value
    }
    public func nextDouble() -> Double { value }
}

/// Tarefa agendada cancelável (heartbeat).
public protocol Cancellable: Sendable {
    func cancel()
}

/// Agenda/executa trabalho — port injetável para testes (tempo virtual).
public protocol SdkScheduler: Sendable {
    /// Suspende a task corrente pelo delay (backoff de retry).
    func sleep(milliseconds: Int64) async
    /// Agenda a ação; retorna handle cancelável.
    func schedule(afterMilliseconds delay: Int64, action: @escaping @Sendable () async -> Void) -> Cancellable
    /// Fire-and-forget em worker do SDK.
    func executeAsync(_ action: @escaping @Sendable () async -> Void)
}

/// Scheduler de produção: DispatchQueue global (rede NUNCA na main thread).
public struct DispatchSdkScheduler: SdkScheduler {
    public init() {}

    public func sleep(milliseconds: Int64) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    public func schedule(
        afterMilliseconds delay: Int64,
        action: @escaping @Sendable () async -> Void
    ) -> Cancellable {
        let workItem = DispatchWorkItem {
            Task.detached { await action() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .milliseconds(Int(delay)),
            execute: workItem
        )
        return DispatchCancellable(workItem: workItem)
    }

    public func executeAsync(_ action: @escaping @Sendable () async -> Void) {
        Task.detached { await action() }
    }
}

struct DispatchCancellable: Cancellable {
    let workItem: DispatchWorkItem
    func cancel() { workItem.cancel() }
}

// ---------------------------------------------------------------------------
// Engine HTTP (a ÚNICA fronteira com a rede; testes injetam URLProtocol)
// ---------------------------------------------------------------------------

public struct HttpRequestData: Sendable, Equatable {
    public let method: String
    public let url: String
    public let headers: [String: String]
    public let body: String

    public init(method: String, url: String, headers: [String: String], body: String) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HttpResponseData: Sendable, Equatable {
    public let statusCode: Int
    public let body: String

    public init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol HttpEngine: Sendable {
    /// Falhas de rede/timeout saem como Error — o transport decide
    /// retry/backoff. Status 4xx/5xx NÃO é erro: volta como resposta normal.
    func execute(_ request: HttpRequestData) async throws -> HttpResponseData
}

/// Engine de produção sobre **URLSession** (zero dependências externas —
/// mesma decisão de higiene do client-android com HttpURLConnection).
/// Camadas TLS/certificados: as do OS.
public struct URLSessionEngine: HttpEngine {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 10) {
        self.session = session
        self.timeout = timeout
    }

    public init(configuration: URLSessionConfiguration, timeout: TimeInterval = 10) {
        self.session = URLSession(configuration: configuration)
        self.timeout = timeout
    }

    public func execute(_ request: HttpRequestData) async throws -> HttpResponseData {
        guard let url = URL(string: request.url) else {
            throw LighthouseNorthError.network("URL malformada no engine: \(request.url)")
        }
        // Belt de defesa em profundidade: só https (ou http loopback validado
        // no transport) chega aqui.
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host ?? ""
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw LighthouseNorthError.network("esquema recusado pelo engine: \(scheme)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = timeout
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body.data(using: .utf8)

        let (data, response) = try await session.data(for: urlRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let capped = data.prefix(4096)
        let body = String(data: capped, encoding: .utf8) ?? ""
        return HttpResponseData(statusCode: statusCode, body: body)
    }
}

// ---------------------------------------------------------------------------
// Retry + Transport
// ---------------------------------------------------------------------------

/// Política de retry: backoff exponencial (500ms → 1s → 2s) com jitter
/// multiplicativo de ±25%, máx. [maxAttempts] tentativas — paridade exata
/// com Flutter/Android.
public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelayMs: Int64

    public init(maxAttempts: Int = 3, baseDelayMs: Int64 = 500) {
        self.maxAttempts = maxAttempts
        self.baseDelayMs = baseDelayMs
    }

    /// Delay após a tentativa `failedAttempt` (1-based). Com
    /// `FixedSdkRandom(0.5)` o fator é exatamente 1.0 (determinístico).
    public func delay(for failedAttempt: Int, random: SdkRandom) -> Int64 {
        let exponential = baseDelayMs << (failedAttempt - 1)
        let factor = 0.75 + 0.5 * random.nextDouble()
        return Int64((Double(exponential) * factor).rounded())
    }

    /// HTTP que vale retry: 408 (timeout), 429 (rate limit) e 5xx.
    public static func isRetryableStatus(_ statusCode: Int) -> Bool {
        return statusCode == 408 || statusCode == 429 || statusCode >= 500
    }
}

/// Transporte HTTP do SDK — ÚNICA saída de rede da library.
/// TLS-only (http só em loopback), timeout 10s/tentativa (engine), retry
/// com backoff+jitter, User-Agent próprio fixo, corpo fechado do contrato.
public final class HttpTransport: Sendable {
    public static let sdkVersion = "0.1.0"

    public let engine: HttpEngine
    public let baseUrl: URL
    public let appKey: String
    private let scheduler: SdkScheduler
    private let random: SdkRandom
    private let logger: SdkLogger
    private let retryPolicy: RetryPolicy

    /// User-Agent de toda requisição — identidade do SDK apenas
    /// (contrato de minimização: NADA do app hospedeiro aqui).
    public var userAgent: String {
        "lighthouse-north-client-ios/\(Self.sdkVersion) (swift;ios)"
    }

    public init(
        engine: HttpEngine,
        baseUrl raw: String,
        appKey: String,
        scheduler: SdkScheduler,
        random: SdkRandom,
        logger: SdkLogger,
        retryPolicy: RetryPolicy = RetryPolicy()
    ) throws {
        self.engine = engine
        self.baseUrl = try HttpTransport.validateBaseUrl(raw)
        self.appKey = appKey
        self.scheduler = scheduler
        self.random = random
        self.logger = logger
        self.retryPolicy = retryPolicy
    }

    /// POST JSON — retorna o status HTTP (200 ou 200/201 para register).
    /// `idempotent` habilita o retry (as 3 rotas de devices são idempotentes
    /// por contrato; o parâmetro existe para futuras rotas nunca pegarem
    /// retry por engano).
    public func postJson(
        _ path: String,
        body: [String: Any],
        idempotent: Bool = true
    ) async throws -> Int {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let response = try await engine.execute(buildRequest(path, body: body))
                let status = response.statusCode
                if (200..<300).contains(status) { return status }
                if RetryPolicy.isRetryableStatus(status), idempotent,
                   attempt < retryPolicy.maxAttempts {
                    await sleepBackoff(attempt, path: path, status: status)
                    continue
                }
                throw exception(for: status, body: response.body)
            } catch let error as LighthouseNorthError {
                switch error {
                case .network:
                    if !idempotent || attempt >= retryPolicy.maxAttempts { throw error }
                    await sleepBackoff(attempt, path: path)
                    continue
                default:
                    throw error
                }
            } catch {
                // Erro de rede cru do engine (URLError etc.) — mesmo caminho.
                if !idempotent || attempt >= retryPolicy.maxAttempts {
                    throw LighthouseNorthError.network(
                        "falha de rede/timeout após \(attempt) tentativa(s) em \(path): \(error)"
                    )
                }
                await sleepBackoff(attempt, path: path)
            }
        }
    }

    public func buildRequest(_ path: String, body: [String: Any]) -> HttpRequestData {
        HttpRequestData(
            method: "POST",
            url: baseUrl.appendingPathComponent(path).absoluteString,
            headers: [
                "x-app-key": appKey,
                "accept": "application/json",
                "user-agent": userAgent,
                "content-type": "application/json; charset=utf-8",
            ],
            body: Json.encode(body)
        )
    }

    private func sleepBackoff(_ failedAttempt: Int, path: String, status: Int? = nil) async {
        let delay = retryPolicy.delay(for: failedAttempt, random: random)
        var fields: [String: Any] = [
            "path": path,
            "attempt": failedAttempt,
            "delayMs": delay,
        ]
        if let status = status { fields["statusCode"] = status }
        logger.log(.warning, "http.retry", fields)
        await scheduler.sleep(milliseconds: delay)
    }

    private func exception(for status: Int, body bodyText: String) -> LighthouseNorthError {
        var errorCode: String?
        if let decoded = Json.decode(bodyText) as? [String: Any] {
            errorCode = (decoded["error"] ?? decoded["code"]) as? String
        }
        let snippet = String(bodyText.prefix(200))
        if status == 401 {
            return .unauthorizedAppKey(
                "confira a key gerada no painel do tenant" + (errorCode.map { " (\($0))" } ?? "")
            )
        }
        return .api(
            statusCode: status,
            errorCode: errorCode,
            message: snippet.isEmpty ? "sem corpo" : snippet
        )
    }

    /// Valida e normaliza a base URL — `https://` sempre; `http://` SOMENTE
    /// em localhost/127.0.0.1/[::1] (dev/testes); sem query/fragmento/user.
    public static func validateBaseUrl(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() as String?,
              let host = components.host, !host.isEmpty,
              components.query == nil,
              components.fragment == nil,
              components.user == nil,
              components.password == nil
        else {
            throw LighthouseNorthError.invalidBaseUrl
        }
        guard ["http", "https"].contains(scheme) else {
            throw LighthouseNorthError.invalidBaseUrl
        }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        if scheme == "https" || (scheme == "http" && loopback) {
            return components.url!
        }
        throw LighthouseNorthError.insecureBaseUrl(raw)
    }
}
