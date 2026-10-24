import Foundation
import Security

// ---------------------------------------------------------------------------
// Persistência do estado local
// ---------------------------------------------------------------------------

/// Persistência do estado local. Implementação iOS: [KeychainStateStore]
/// (kSecClassGenericPassword — fecha a pendência P2 da 3.2: estado NUNCA em
/// UserDefaults plaintext).
public protocol StateStore: Sendable {
    /// `nil` = sem estado OU corrompido (descartar e recomeçar limpo).
    func read() throws -> DeviceState?
    func write(_ state: DeviceState) throws
    func clear() throws
}

/// Store em memória para testes.
public final class InMemoryStateStore: StateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: DeviceState?

    public init() {}

    public var state: DeviceState? {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public func read() -> DeviceState? { state }

    public func write(_ state: DeviceState) {
        lock.lock(); defer { lock.unlock() }
        _state = state
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        _state = nil
    }
}

/// Estado na **Keychain** (kSecClassGenericPassword, service/account
/// dedicados, acessível após primeira desbloqueio — WhenUnlockedThisDeviceOnly
/// não exige backup do item):
///
/// - o token nunca fica em texto plano no filesystem (plist de backup de
///   UserDefaults LEVA o estado junto — Keychain com ThisDeviceOnly não);
/// - MIGRAÇÃO transparente do plaintext legado em
///   UserDefaults["lighthouse_north_client_state"] (formato escrito pelos nativos da
///   3.2): lê, regrava na Keychain, REMOVE o default;
/// - estado corrompido (JSON inválido/versão desconhecida) ⇒ `nil` + log;
/// - outros status de Keychain ⇒ `LighthouseNorthError.storage` (FAIL CLOSED —
///   nunca degrada para plaintext).
public final class KeychainStateStore: StateStore, @unchecked Sendable {
    private let service: String
    private let account: String
    private let logger: SdkLogger
    private let legacyDefaultsKey = "lighthouse_north_client_state"

    public init(service: String = "lighthouse_north_client", account: String = "state", logger: SdkLogger = NoopLogger()) {
        self.service = service
        self.account = account
        self.logger = logger
    }

    public func read() throws -> DeviceState? {
        // 1) Keychain (formato atual).
        if let raw = try readKeychain() {
            let state = StateCodec.fromJsonString(raw)
            if state == nil {
                logger.log(.warning, "storage.state_discarded", ["reason": "corrompido/versão desconhecida"])
            }
            return state
        }
        // 2) Legado plaintext (nativos da 3.2) — migra e remove.
        let defaults = UserDefaults.standard
        if let legacy = defaults.string(forKey: legacyDefaultsKey) {
            let state = StateCodec.fromJsonString(legacy)
            if let state = state {
                do {
                    try write(state)
                } catch {
                    logger.log(.warning, "storage.legacy_migration_failed", ["error": "\(error)"])
                    return state // plaintext legível permanece válido nesta leitura
                }
            } else {
                logger.log(.warning, "storage.state_discarded", ["reason": "legado corrompido"])
            }
            defaults.removeObject(forKey: legacyDefaultsKey)
            return state
        }
        return nil
    }

    public func write(_ state: DeviceState) throws {
        let data = Data(StateCodec.toJsonString(state).utf8)
        var query = baseQuery()
        query[kSecValueData as String] = data

        // Update-ou-insert atômico:
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw LighthouseNorthError.storage("SecItemUpdate falhou (OSStatus \(updateStatus))")
        }
        var add = query
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw LighthouseNorthError.storage("SecItemAdd falhou (OSStatus \(addStatus))")
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LighthouseNorthError.storage("SecItemDelete falhou (OSStatus \(status))")
        }
    }

    private func readKeychain() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw LighthouseNorthError.storage("SecItemCopyMatching falhou (OSStatus \(status))")
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
