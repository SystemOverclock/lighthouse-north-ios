import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#endif

// ---------------------------------------------------------------------------
// Fonte de permissão + token push (tudo injetável — testável sem device)
// ---------------------------------------------------------------------------

/// Fonte de permissão + token push — TODO acesso a OS/Firebase passa por
/// esta interface (o SDK não embute Firebase; decisão 3.2):
///
/// - **testável** sem device/emulador (FakeTokenProvider);
/// - **extensível**: um host que já usa FirebaseMessaging implementa esta
///   interface em ~8 linhas (ver README "Token via Firebase do hospedeiro").
public protocol TokenProvider: Sendable {
    /// Obtém o token push do app HOSPEDEIRO. Lança
    /// `LighthouseNorthError.firebaseNotConfigured` quando o host não tem Firebase.
    func getToken() async throws -> String
    /// Plataforma atual para o registro na API (`android|ios|web`).
    func platform() -> DevicePlatform
}

/// Default do SDK iOS: host SEM provider configurado — erro tipado com
/// mensagem acionável (nunca crash; paridade das outras pontas).
public struct UnconfiguredTokenProvider: TokenProvider {
    public init() {}

    public func getToken() async throws -> String {
        throw LighthouseNorthError.firebaseNotConfigured(
            "injete um TokenProvider no initialize (ex.: FirebaseMessaging do host — " +
                "ver README do SDK, seção Token; para dev/testes use FakeTokenProvider)"
        )
    }

    public func platform() -> DevicePlatform { .ios }
}

/// Provider de desenvolvimento/testes: sem OS, sem Firebase, sem rede.
public final class FakeTokenProvider: TokenProvider, @unchecked Sendable {
    public var token: String?
    public var permissionGranted: Bool
    public private(set) var tokenRequestCount = 0
    public private(set) var permissionRequestCount = 0

    public init(
        token: String? = "fake-apns-token-0123456789abcdef",
        permissionGranted: Bool = true
    ) {
        self.token = token
        self.permissionGranted = permissionGranted
    }

    public func getToken() async throws -> String {
        tokenRequestCount += 1
        guard let token = token, !token.isEmpty else {
            throw LighthouseNorthError.pushTokenUnavailable("FakeTokenProvider.token vazio")
        }
        return token
    }

    public func platform() -> DevicePlatform { .ios }
}

// ---------------------------------------------------------------------------
// Gateway de permissão de notificação (UNUserNotifications)
// ---------------------------------------------------------------------------

public protocol PermissionGateway: Sendable {
    /// Permissão atual SEM pedir (informativa; falha ⇒ true — ver contrato).
    func isGranted() async -> Bool
    /// Pede a permissão (dialog do OS). `false` = negada (não é erro).
    func request() async throws -> Bool
}

/// Gateway real via UNUserNotifications.
public struct NotificationPermissionGateway: PermissionGateway {
    public init() {}

    public func isGranted() async -> Bool {
        #if canImport(UserNotifications)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.isGranted(settings.authorizationStatus)
        #else
        return true
        #endif
    }

    public func request() async throws -> Bool {
        #if canImport(UserNotifications)
        let granted = try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        return granted
        #else
        return true
        #endif
    }

    static func isGranted(_ status: UNAuthorizationStatus) -> Bool {
        if status == .authorized || status == .provisional { return true }
        // .ephemeral (App Clips) existe apenas no iOS — indisponível no macOS
        #if os(iOS)
        if #available(iOS 14.0, *) { return status == .ephemeral }
        #endif
        return false
    }
}

// ---------------------------------------------------------------------------
// Permission watcher (revogação detectada na volta ao 1º plano — §3.4)
// ---------------------------------------------------------------------------

/// Observa a revogação da permissão quando o app volta ao primeiro plano
/// (willEnterForeground + getNotificationSettings) — a janela entre a
/// revogação nas Configurações e a reabertura NÃO é observada (limite
/// conhecido documentado; idem nas outras pontas).
public final class PermissionWatcher: @unchecked Sendable {
    private var observer: (any NSObjectProtocol)?
    private let lock = NSLock()
    private var lastKnownGranted: Bool?

    public init() {}

    /// Liga o watcher. [onRevoked] roda fora da main thread.
    public func start(onRevoked: @escaping @Sendable () -> Void) {
        stop()
        #if canImport(UIKit) && canImport(UserNotifications)
        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task.detached {
                guard let self = self else { return }
                let granted = await self.currentlyGranted()
                let revoked = self.recordTransition(to: granted)
                if revoked { onRevoked() }
            }
        }
        lock.lock()
        self.observer = observer
        lock.unlock()
        #endif
    }

    /// Atualiza a baseline (após request/check) para evitar falso positivo
    /// de revogação no primeiro foreground seguinte.
    public func recordGranted(_ granted: Bool) {
        lock.lock(); defer { lock.unlock() }
        lastKnownGranted = granted
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    private func currentlyGranted() async -> Bool {
        #if canImport(UserNotifications)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationPermissionGateway.isGranted(settings.authorizationStatus)
        #else
        return true
        #endif
    }

    private func recordTransition(to granted: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let last = lastKnownGranted
        lastKnownGranted = granted
        return last == true && !granted
    }
}
