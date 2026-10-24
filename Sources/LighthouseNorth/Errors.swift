import Foundation

/// Erros tipados do SDK — espelha a hierarquia `sealed` do SDK Flutter
/// (`packages/client-flutter/lib/src/errors/errors.dart`) e a sealed class do
/// SDK Android. Divergência de comportamento entre as pontas = bug
/// (docs/NATIVE_CONTRACT.md).
public enum LighthouseNorthError: Error, Sendable, CustomStringConvertible {
    /// `apiBaseUrl` com `http://` fora de localhost — o SDK é TLS-only.
    case insecureBaseUrl(String)
    /// `apiBaseUrl` que não parseia como URL http(s) com host.
    case invalidBaseUrl
    /// App key evidentemente inválida (vazia, curta demais ou com espaços).
    case invalidAppKey(String)
    /// `LighthouseNorthClient.shared` usado antes de `initialize`.
    case notInitialized
    /// Método chamado em um cliente já fechado (`close()`).
    case clientClosed
    /// Entrada inválida do integrador (token fora de 16..4096, contactRef
    /// fora de 1..200) — espelha as regras da API para falhar antes de rede.
    case invalidInput(field: String, reason: String)
    /// Usuário NEGOU a permissão de notificação — o device NÃO é registrado.
    case pushPermissionDenied
    /// O token push não pôde ser obtido (qualquer causa que não a negação).
    case pushTokenUnavailable(String)
    /// Host sem Firebase — o SDK não embute Firebase (provider injetável).
    case firebaseNotConfigured(String)
    /// Rede/timeout após todas as tentativas.
    case network(String)
    /// Erro HTTP da API fora da política de retry.
    case api(statusCode: Int, errorCode: String?, message: String)
    /// X-App-Key rejeitada (401 uniforme da API).
    case unauthorizedAppKey(String)
    /// Falha ao ler/escrever o estado local (Keychain).
    case storage(String)
    /// Falha da camada nativa (UNUserNotifications etc.).
    case native(code: String, message: String)

    public var description: String {
        switch self {
        case .insecureBaseUrl(let url):
            return "LighthouseNorth: base URL insegura: http:// só é aceito em localhost (dev/testes); use https:// (\(url))"
        case .invalidBaseUrl:
            return "LighthouseNorth: base URL inválida — informe algo como https://api.exemplo.com (sem query/fragmento)"
        case .invalidAppKey(let reason):
            return "LighthouseNorth: app key inválida — \(reason)"
        case .notInitialized:
            return "LighthouseNorth: LighthouseNorthClient não inicializado — chame LighthouseNorthClient.initialize(...) antes"
        case .clientClosed:
            return "LighthouseNorth: LighthouseNorthClient já foi fechado — chame initialize(...) novamente"
        case .invalidInput(let field, let reason):
            return "LighthouseNorth: entrada inválida (\(field)): \(reason)"
        case .pushPermissionDenied:
            return "LighthouseNorth: permissão de notificação negada pelo usuário — device não registrado"
        case .pushTokenUnavailable(let detail):
            return "LighthouseNorth: token push indisponível — \(detail)"
        case .firebaseNotConfigured(let detail):
            return "LighthouseNorth: Firebase não configurado no app hospedeiro — \(detail)"
        case .network(let detail):
            return "LighthouseNorth: falha de rede — \(detail)"
        case .api(let statusCode, let errorCode, let message):
            return "LighthouseNorth: erro \(statusCode) da API \(errorCode.map { "(\($0))" } ?? "") — \(message)"
        case .unauthorizedAppKey(let detail):
            return "LighthouseNorth: app key rejeitada pela API (401) — \(detail)"
        case .storage(let detail):
            return "LighthouseNorth: falha de storage local — \(detail)"
        case .native(let code, let message):
            return "LighthouseNorth: falha nativa (\(code)) — \(message)"
        }
    }
}

/// Máscaras de segredo — token e app key NUNCA aparecem inteiros em log,
/// erro ou evento (paridade exata com o redactSecret do Flutter/Android).
public func redactSecret(_ value: String) -> String {
    if value.count <= 8 { return "***" }
    return "\(value.prefix(4))...\(value.suffix(4))"
}

/// Níveis de log do SDK (silencioso por padrão).
public enum SdkLogLevel: String, Sendable {
    case debug, info, warning, error
}

/// Log estruturado opcional — o integrador pluga o próprio sink.
/// Segredos nunca chegam inteiros aqui (passam por `redactSecret`).
public protocol SdkLogger: Sendable {
    func log(_ level: SdkLogLevel, _ event: String, _ fields: [String: Any])
}

/// Logger que descarta tudo (default).
public struct NoopLogger: SdkLogger {
    public init() {}
    public func log(_ level: SdkLogLevel, _ event: String, _ fields: [String: Any]) {}
}

/// Logger em memória — usado pelos testes e para depuração.
public final class InMemoryLogger: SdkLogger, @unchecked Sendable {
    public struct Entry: Sendable {
        public let level: SdkLogLevel
        public let event: String
        public let fields: [String: Any]
    }

    private let lock = NSLock()
    private var _entries: [Entry] = []
    public var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    public init() {}

    public func log(_ level: SdkLogLevel, _ event: String, _ fields: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        _entries.append(Entry(level: level, event: event, fields: fields))
    }
}
