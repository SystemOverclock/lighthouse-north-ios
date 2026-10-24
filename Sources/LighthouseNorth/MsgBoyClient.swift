import Foundation

/// SDK iOS nativo (codinome — nome de publicação SPM/CocoaPods pendente do
/// dono) para integrar o app do cliente à plataforma LighthouseNorth de disparo push.
/// A plataforma cuida do disparo e da segmentação; o SDK coleta o MÍNIMO
/// (platform/token/contactRef/consent) e oferece opt-out fácil e gratuito.
///
/// Ciclo de vida típico:
/// ```swift
/// let client = try LighthouseNorthClient.initialize(
///     appKey: appKey,                    // do painel do tenant — NUNCA hardcoded
///     apiBaseUrl: "https://api.seu-ambiente.lighthouse"
/// )
/// do {
///     let reg = try await client.registerForPush(
///         contactRef: "cliente-42", policyVersion: "2026-09")
///     _ = client.startHeartbeat()        // 24h com jitter ±10%
/// } catch LighthouseNorthError.pushPermissionDenied {
///     // usuário negou no OS — device NÃO registrado; trate e siga
/// }
/// // o usuário pede para sair de push em qualquer tela:
/// let result = await client.optOut()     // nunca lança por rede
/// ```
public final class LighthouseNorthClient: @unchecked Sendable {

    /// Default provisório — o domínio oficial acompanha o nome de publicação
    /// do produto (pendência do dono). Aponte `apiBaseUrl` explicitamente em
    /// dev/staging.
    public static let defaultApiBaseUrl = "https://api.lighthouse-north.example"

    public static let defaultHeartbeatIntervalMs: Int64 = 24 * 60 * 60 * 1000

    private static var sharedClient: LighthouseNorthClient?
    private static let sharedLock = NSLock()

    /// Instância ativa (ou `nil`).
    public static var shared: LighthouseNorthClient? {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return sharedClient
    }

    // Dependências (todas injetáveis — testável sem device/rede):
    let api: HttpTransport
    let store: StateStore
    let tokenProvider: TokenProvider
    let permissions: PermissionGateway
    let scheduler: SdkScheduler
    let random: SdkRandom
    let clock: SdkClock
    let logger: SdkLogger
    let watcher: PermissionWatcher

    private let stateLock = NSLock()
    private var heartbeatRunning = false
    private var heartbeatIntervalMs: Int64 = LighthouseNorthClient.defaultHeartbeatIntervalMs
    private var heartbeatCancellable: Cancellable?
    private var closed = false

    /// Listener da revogação da permissão no OS (contrato §3.4) — o SDK JÁ
    /// removeu o device (cobrança honesta); o host usa isto apenas para UX.
    public var onPermissionRevoked: (@Sendable (PermissionRevocation) -> Void)?

    /// Listener da rotação do token FCM do host (3.3 — onNewToken).
    public var onTokenRotated: (@Sendable (TokenRotationResult) -> Void)?

    // -----------------------------------------------------------------
    // Inicialização
    // -----------------------------------------------------------------

    /// Injeções opcionais (testes/dev: engine fake, provider fake, store fake).
    public struct Configuration: Sendable {
        public var logger: SdkLogger
        public var engine: HttpEngine?
        public var tokenProvider: TokenProvider?
        public var stateStore: StateStore?
        public var permissions: PermissionGateway?
        public var clock: SdkClock?
        public var random: SdkRandom?
        public var scheduler: SdkScheduler?

        public init(
            logger: SdkLogger = NoopLogger(),
            engine: HttpEngine? = nil,
            tokenProvider: TokenProvider? = nil,
            stateStore: StateStore? = nil,
            permissions: PermissionGateway? = nil,
            clock: SdkClock? = nil,
            random: SdkRandom? = nil,
            scheduler: SdkScheduler? = nil
        ) {
            self.logger = logger
            self.engine = engine
            self.tokenProvider = tokenProvider
            self.stateStore = stateStore
            self.permissions = permissions
            self.clock = clock
            self.random = random
            self.scheduler = scheduler
        }
    }

    /// Inicializa (e define) o cliente singleton. Se um heartbeat estava
    /// ativo, o timer é RETOMADO aqui (sobrevive a restart) com um refresh
    /// imediato fire-and-forget (last_seen honesto — expurgo da plataforma
    /// é 90d sem last_seen).
    @discardableResult
    public static func initialize(
        appKey: String,
        apiBaseUrl: String = defaultApiBaseUrl,
        configuration: Configuration = Configuration()
    ) throws -> LighthouseNorthClient {
        try validateAppKey(appKey, logger: configuration.logger)

        sharedLock.lock()
        sharedClient?.close()
        let client = try LighthouseNorthClient(
            appKey: appKey,
            apiBaseUrl: apiBaseUrl,
            configuration: configuration,
            ownScheduler: configuration.scheduler == nil
        )
        sharedClient = client
        sharedLock.unlock()

        client.scheduler.executeAsync { await client.resumeAfterInitialize() }
        return client
    }

    private init(
        appKey: String,
        apiBaseUrl: String,
        configuration: Configuration,
        ownScheduler: Bool
    ) throws {
        let scheduler = configuration.scheduler ?? DispatchSdkScheduler()
        let random = configuration.random ?? SystemSdkRandom()
        self.api = try HttpTransport(
            engine: configuration.engine ?? URLSessionEngine(),
            baseUrl: apiBaseUrl,
            appKey: appKey,
            scheduler: scheduler,
            random: random,
            logger: configuration.logger
        )
        self.store = configuration.stateStore ?? KeychainStateStore(logger: configuration.logger)
        self.tokenProvider = configuration.tokenProvider ?? UnconfiguredTokenProvider()
        self.permissions = configuration.permissions ?? NotificationPermissionGateway()
        self.scheduler = scheduler
        self.random = random
        self.clock = configuration.clock ?? SystemSdkClock()
        self.logger = configuration.logger
        self.watcher = PermissionWatcher()
        self.ownScheduler = ownScheduler
        startWatcher()
    }

    private let ownScheduler: Bool

    deinit {
        watcher.stop()
    }

    private func startWatcher() {
        watcher.start { [weak self] in
            guard let self = self else { return }
            self.scheduler.executeAsync {
                let event = await self.handlePermissionRevoked()
                self.onPermissionRevoked?(event)
            }
        }
    }

    // -----------------------------------------------------------------
    // Estado (visão p/ UI)
    // -----------------------------------------------------------------

    /// Última visão síncrona do estado local (para UI).
    public var currentState: DeviceState? {
        (try? store.read()) ?? nil
    }

    public var isRegistered: Bool { currentState?.token != nil }

    public var isHeartbeatRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return heartbeatRunning
    }

    // -----------------------------------------------------------------
    // registerForPush
    // -----------------------------------------------------------------

    /// Registra o device para push — o fluxo COMPLETO:
    /// (1) permissão OS; (2) token do host; (3) `POST /v1/devices` com
    /// `consent {granted: true, capturedAt, policyVersion}` — evidência do
    /// opt-in que a plataforma grava no contato; (4) persiste o mínimo.
    ///
    /// Permissão NEGADA ⇒ `LighthouseNorthError.pushPermissionDenied` e o device NÃO
    /// é registrado (não é crash — trate e siga).
    public func registerForPush(
        contactRef: String? = nil,
        policyVersion: String? = nil
    ) async throws -> RegistrationResult {
        try ensureUsable()
        try validateContactRef(contactRef)

        let platform = tokenProvider.platform()

        let granted: Bool
        do {
            granted = try await permissions.request()
        } catch let error as LighthouseNorthError {
            throw error
        } catch {
            throw LighthouseNorthError.native(code: "request_permission_failed", message: "\(error)")
        }
        watcher.recordGranted(granted)
        if !granted {
            logger.log(.info, "register.permission_denied", ["platform": platform.rawValue])
            throw LighthouseNorthError.pushPermissionDenied
        }

        let token: String
        do {
            token = try await tokenProvider.getToken()
        } catch let error as LighthouseNorthError {
            throw error
        } catch {
            throw LighthouseNorthError.pushTokenUnavailable("falha ao obter token push: \(error)")
        }

        if token.count < 16 || token.count > 4096 {
            throw LighthouseNorthError.invalidInput(
                field: "token",
                reason: "deve ter entre 16 e 4096 caracteres (recebido: \(token.count))"
            )
        }

        let consent = ConsentEvidence(
            granted: true,
            capturedAt: clock.now(),
            policyVersion: policyVersion
        )
        let previous = try store.read()
        let effectiveContactRef = contactRef ?? previous?.contactRef

        // MINIMIZAÇÃO: corpo fechado em platform/token/contactRef/consent.
        var body: [String: Any] = [
            "platform": platform.rawValue,
            "token": token,
            "consent": consent.jsonObject(),
        ]
        if let effectiveContactRef = effectiveContactRef {
            body["contactRef"] = effectiveContactRef
        }
        let status = try await api.postJson("/v1/devices", body: body, idempotent: true)

        try store.write(
            DeviceState(
                platform: platform,
                token: token,
                contactRef: effectiveContactRef,
                policyVersion: policyVersion ?? previous?.policyVersion,
                registeredAt: clock.now(),
                heartbeatActive: previous?.heartbeatActive ?? false,
                heartbeatIntervalMs: previous?.heartbeatIntervalMs
            )
        )

        logger.log(.info, "register.success", [
            "platform": platform.rawValue,
            "token": redactSecret(token),
            "statusCode": status,
        ])
        return RegistrationResult(
            platform: platform,
            maskedToken: redactSecret(token),
            contactRef: effectiveContactRef,
            consent: consent,
            updatedExisting: status == 200
        )
    }

    // -----------------------------------------------------------------
    // optOut — REQUISITO LEGAL BLOQUEANTE
    // -----------------------------------------------------------------

    /// OPT-OUT COMPLETO — best-effort, em ordem: (1) revoga a base de
    /// marketing (`consent granted=false` + contactRef); (2) remove o device
    /// (`unregister`). Nunca lança por rede; o resultado reporta cada passo.
    ///
    /// Estado local: limpo sempre que um passo efetivo teve sucesso. Em
    /// falha TOTAL o SDK preserva o mínimo p/ re-tentar — descartar o token
    /// descartaria a capacidade de concluir o opt-out.
    public func optOut() async -> OptOutResult {
        // optOut é requisito legal "fácil e gratuito": falhas internas de
        // storage aqui não podem virar crash — seguem como falha de etapa.
        // read() nil = sem estado OU corrompido (contrato do StateStore:
        // descartar e recomeçar limpo) → no-op; só throw real é falha.
        let state: DeviceState?
        do {
            state = try store.read()
        } catch {
            return OptOutResult(
                hadRegistration: false, consentRevoked: nil,
                unregistered: true, stateCleared: false,
                failures: [OptOutStepFailure(step: .unregister, reason: "storage indisponível")]
            )
        }
        let token = state?.token
        let contactRef = state?.contactRef
        let platform = state?.platform
        let policyVersion = state?.policyVersion

        if token == nil && contactRef == nil {
            stopHeartbeatInternal(persist: false)
            try? store.clear()
            logger.log(.info, "opt_out.noop", ["reason": "sem registro local"])
            return OptOutResult(
                hadRegistration: false, consentRevoked: nil,
                unregistered: true, stateCleared: true, failures: []
            )
        }

        var failures: [OptOutStepFailure] = []
        var consentRevoked: Bool?

        // PASSO 1 — revogar a base marketing ANTES do unregister: revogar
        // depois recriaria o device (o POST de registro é upsert por token).
        if let contactRef = contactRef, let token = token, let platform = platform {
            do {
                let consent = ConsentEvidence(
                    granted: false,
                    capturedAt: clock.now(),
                    policyVersion: policyVersion
                )
                _ = try await api.postJson(
                    "/v1/devices",
                    body: [
                        "platform": platform.rawValue,
                        "token": token,
                        "contactRef": contactRef,
                        "consent": consent.jsonObject(),
                    ],
                    idempotent: true
                )
                consentRevoked = true
            } catch {
                consentRevoked = false
                failures.append(OptOutStepFailure(step: .consentRevoke, reason: "\(error)"))
                logger.log(.error, "opt_out.consent_revoke_failed", [
                    "error": "\(error)", "token": redactSecret(token),
                ])
            }
        } else if contactRef != nil {
            // Sem token (ex.: permissão do OS já revogada e device já
            // removido) — a base permanece mas SEM device não há push para
            // este aparelho. Registrado para rastreio legal.
            logger.log(.warning, "opt_out.consent_revoke_skipped", [
                "reason": "sem token local — device já removido; base permanece sem alvo",
            ])
        }

        // PASSO 2 — remover o device (hard delete na plataforma).
        var unregistered = false
        if let token = token {
            do {
                _ = try await api.postJson(
                    "/v1/devices/unregister",
                    body: ["token": token],
                    idempotent: true
                )
                unregistered = true
            } catch {
                failures.append(OptOutStepFailure(step: .unregister, reason: "\(error)"))
                logger.log(.error, "opt_out.unregister_failed", [
                    "error": "\(error)", "token": redactSecret(token),
                ])
            }
        } else {
            unregistered = true // nada a remover
        }

        let somethingSucceeded = consentRevoked == true || unregistered
        var stateCleared = false
        stopHeartbeatInternal(persist: false)
        if somethingSucceeded {
            try? store.clear()
            stateCleared = true
        }

        logger.log(.info, "opt_out.completed", [
            "consentRevoked": consentRevoked.map { "\($0)" } ?? "null",
            "unregistered": "\(unregistered)",
            "stateCleared": "\(stateCleared)",
            "failures": "\(failures.count)",
        ])
        return OptOutResult(
            hadRegistration: true,
            consentRevoked: consentRevoked,
            unregistered: unregistered,
            stateCleared: stateCleared,
            failures: failures
        )
    }

    // -----------------------------------------------------------------
    // Rotação de token (3.3 — onNewToken do host)
    // -----------------------------------------------------------------

    /// Notifica o SDK de um token NOVO (onNewToken do FirebaseMessaging do
    /// host). Registra o novo upsert SEM consent — o estado legal do contato
    /// NÃO muda com a rotação; reafirmar `granted=true` ressuscitaria
    /// consentimento revogado no intervalo (optOut parcial preserva
    /// contactRef/token localmente; retirada pelo painel idem) — a base
    /// vigente no servidor é a autoridade (@gate QA 3.3, paridade nas 3
    /// pontas + NATIVE_CONTRACT §3). Faz unregister best-effort do antigo
    /// (evita push duplicado até o expurgo de 90d) e atualiza o estado local.
    @discardableResult
    public func onNewToken(_ newToken: String) async throws -> TokenRotationResult {
        try ensureUsable()
        if newToken.count < 16 || newToken.count > 4096 {
            throw LighthouseNorthError.invalidInput(
                field: "token",
                reason: "rotação: novo token fora de 16..4096 (recebido: \(newToken.count))"
            )
        }
        let platform = tokenProvider.platform()
        let previous = try store.read()
        let oldToken = previous?.token

        if oldToken == newToken {
            return TokenRotationResult(
                changed: false, registered: false, oldRemoved: nil, updatedExisting: true
            )
        }

        // SEM consent (ver docstring): rotação não é ato de consentimento —
        // o contactRef segue para manter o device vinculado ao contato.
        var body: [String: Any] = [
            "platform": platform.rawValue,
            "token": newToken,
        ]
        if let contactRef = previous?.contactRef {
            body["contactRef"] = contactRef
        }
        let status = try await api.postJson("/v1/devices", body: body, idempotent: true)

        var oldRemoved: Bool?
        if let oldToken = oldToken {
            do {
                _ = try await api.postJson(
                    "/v1/devices/unregister",
                    body: ["token": oldToken],
                    idempotent: true
                )
                oldRemoved = true
            } catch {
                logger.log(.warning, "rotation.old_unregister_failed", [
                    "error": "\(error)", "token": redactSecret(oldToken),
                ])
                oldRemoved = false
            }
        }

        try store.write(
            DeviceState(
                platform: platform,
                token: newToken,
                contactRef: previous?.contactRef,
                policyVersion: previous?.policyVersion,
                registeredAt: clock.now(),
                heartbeatActive: previous?.heartbeatActive ?? false,
                heartbeatIntervalMs: previous?.heartbeatIntervalMs
            )
        )
        let result = TokenRotationResult(
            changed: true, registered: true, oldRemoved: oldRemoved, updatedExisting: status == 200
        )
        logger.log(.info, "rotation.completed", [
            "token": redactSecret(newToken),
            "oldRemoved": oldRemoved.map { "\($0)" } ?? "null",
            "statusCode": status,
        ])
        onTokenRotated?(result)
        return result
    }

    // -----------------------------------------------------------------
    // Heartbeat
    // -----------------------------------------------------------------

    /// Liga o heartbeat (default 24h com jitter ±10%; persiste — sobrevive a
    /// restart). Retorna `false` se não há token registrado.
    @discardableResult
    public func startHeartbeat(
        intervalMs: Int64 = LighthouseNorthClient.defaultHeartbeatIntervalMs
    ) -> Bool {
        stopHeartbeatInternal(persist: false)
        heartbeatIntervalMs = intervalMs
        guard let state = try? store.read(), let token = state.token else {
            logger.log(.warning, "heartbeat.start_skipped", ["reason": "sem token registrado"])
            return false
        }
        var next = state
        next.heartbeatActive = true
        next.heartbeatIntervalMs = Int(intervalMs)
        try? store.write(next)
        stateLock.lock()
        heartbeatRunning = true
        stateLock.unlock()
        _ = token // leitura acima apenas valida existência
        scheduleNextHeartbeat()
        logger.log(.info, "heartbeat.started", ["intervalMs": intervalMs])
        return true
    }

    /// Desliga o heartbeat (o registro do device permanece).
    public func stopHeartbeat() {
        stopHeartbeatInternal(persist: true)
    }

    private func stopHeartbeatInternal(persist: Bool) {
        stateLock.lock()
        heartbeatRunning = false
        heartbeatCancellable?.cancel()
        heartbeatCancellable = nil
        stateLock.unlock()
        guard persist else { return }
        guard var state = try? store.read(), state.heartbeatActive else { return }
        state.heartbeatActive = false
        state.heartbeatIntervalMs = nil
        try? store.write(state)
    }

    private func scheduleNextHeartbeat() {
        stateLock.lock()
        let running = heartbeatRunning
        let interval = heartbeatIntervalMs
        stateLock.unlock()
        guard running else { return }
        let jitterFactor = 0.9 + random.nextDouble() * 0.2 // ±10%
        let delay = Int64((Double(interval) * jitterFactor).rounded())
        heartbeatCancellable = scheduler.schedule(afterMilliseconds: delay) { [weak self] in
            await self?.heartbeatTick()
        }
    }

    private func heartbeatTick() async {
        stateLock.lock()
        let running = heartbeatRunning
        stateLock.unlock()
        guard running else { return }
        guard let state = try? store.read(), let token = state.token else {
            logger.log(.warning, "heartbeat.stopped", ["reason": "token sumiu do estado"])
            stateLock.lock()
            heartbeatRunning = false
            stateLock.unlock()
            if var stale = try? store.read() {
                stale.heartbeatActive = false
                stale.heartbeatIntervalMs = nil
                try? store.write(stale)
            }
            return
        }
        do {
            _ = try await api.postJson(
                "/v1/devices/refresh",
                body: ["token": token],
                idempotent: true
            )
            logger.log(.debug, "heartbeat.refresh_ok", [:])
        } catch {
            // Falha de refresh NÃO derruba o heartbeat; o próximo tick tenta.
            logger.log(.error, "heartbeat.refresh_failed", ["error": "\(error)"])
        }
        scheduleNextHeartbeat()
    }

    // -----------------------------------------------------------------
    // Permission watcher + ciclo de vida
    // -----------------------------------------------------------------

    /// Revogação da permissão no OS: unregister automático (cobrança honesta)
    /// + evento para o host. Nunca lança (roda em background).
    private func handlePermissionRevoked() async -> PermissionRevocation {
        if isClosed { return PermissionRevocation(unregistered: false, error: "client fechado") }
        logger.log(.warning, "permission.revoked", [:])
        var unregistered = false
        var failure: String?
        if let state = try? store.read(), let token = state.token {
            do {
                _ = try await api.postJson(
                    "/v1/devices/unregister",
                    body: ["token": token],
                    idempotent: true
                )
                unregistered = true
            } catch {
                failure = "\(error)"
            }
            if unregistered {
                // Token sai; contactRef/policyVersion ficam para re-consentimento.
                stopHeartbeatInternal(persist: false)
                var next = state
                next.token = nil
                next.heartbeatActive = false
                next.heartbeatIntervalMs = nil
                try? store.write(next)
            }
        } else {
            unregistered = true
        }
        if failure != nil {
            logger.log(.error, "permission.revoked_unregister_failed", ["error": failure ?? ""])
        }
        return PermissionRevocation(unregistered: unregistered, error: failure)
    }

    /// Retoma o heartbeat pós-restart + refresh imediato fire-and-forget.
    private func resumeAfterInitialize() async {
        guard let state = try? store.read(),
              state.heartbeatActive,
              let token = state.token
        else { return }
        let interval = state.heartbeatIntervalMs.map(Int64.init)
            ?? LighthouseNorthClient.defaultHeartbeatIntervalMs
        _ = startHeartbeat(intervalMs: interval)
        logger.log(.info, "heartbeat.resumed", ["intervalMs": interval])
        do {
            _ = try await api.postJson(
                "/v1/devices/refresh",
                body: ["token": token],
                idempotent: true
            )
            logger.log(.debug, "heartbeat.resume_refresh_ok", [:])
        } catch {
            logger.log(.error, "heartbeat.resume_refresh_failed", ["error": "\(error)"])
        }
    }

    var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closed
    }

    /// Libera o SDK (watcher, heartbeat). O app normalmente não chama isto.
    public func close() {
        stopHeartbeatInternal(persist: false)
        watcher.stop()
        stateLock.lock()
        closed = true
        stateLock.unlock()
        LighthouseNorthClient.sharedLock.lock()
        if LighthouseNorthClient.sharedClient === self {
            LighthouseNorthClient.sharedClient = nil
        }
        LighthouseNorthClient.sharedLock.unlock()
    }

    // -----------------------------------------------------------------
    // internals
    // -----------------------------------------------------------------

    private func ensureUsable() throws {
        if isClosed { throw LighthouseNorthError.clientClosed }
    }

    private func validateContactRef(_ contactRef: String?) throws {
        if let contactRef = contactRef, contactRef.isEmpty || contactRef.count > 200 {
            throw LighthouseNorthError.invalidInput(
                field: "contactRef", reason: "deve ter entre 1 e 200 caracteres"
            )
        }
    }

    private static func validateAppKey(_ appKey: String, logger: SdkLogger) throws {
        if appKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LighthouseNorthError.invalidAppKey("app key vazia — gere uma no painel do tenant (Apps > Chaves)")
        }
        if appKey.contains(where: { $0.isWhitespace }) {
            throw LighthouseNorthError.invalidAppKey("app key contém espaços/quebras — recopie o valor do painel")
        }
        if appKey.count < 16 {
            throw LighthouseNorthError.invalidAppKey("app key curta demais — material ak_... tem tamanho fixo")
        }
        if !appKey.hasPrefix("ak_") {
            logger.log(.warning, "init.app_key_unexpected_prefix", [
                "hint": "material de app key começa com ak_ — o servidor responderá 401 se estiver errada",
            ])
        }
    }
}
