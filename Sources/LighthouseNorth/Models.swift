import Foundation

/// Plataforma do device — ESPELHO exato do enum da API (`android|ios|web`).
public enum DevicePlatform: String, Sendable {
    case android
    case ios
    case web
}

/// Evidência do consentimento push capturada no app (LGPD art. 11 — a
/// plataforma grava a trilha no contato quando acompanhada de `contactRef`).
public struct ConsentEvidence: Sendable, Equatable {
    public let granted: Bool
    public let capturedAt: Date
    public let policyVersion: String?

    public init(granted: Bool, capturedAt: Date, policyVersion: String? = nil) {
        self.granted = granted
        self.capturedAt = capturedAt
        self.policyVersion = policyVersion
    }

    /// Serialização EXATA do contrato — nenhum campo extra (minimização).
    public func jsonObject(clockNow: Date? = nil) -> [String: Any] {
        var json: [String: Any] = [
            "granted": granted,
            "capturedAt": Iso8601.utc.string(from: capturedAt),
        ]
        if let policyVersion = policyVersion {
            json["policyVersion"] = policyVersion
        }
        return json
    }
}

/// Resultado de um `registerForPush` bem-sucedido (token só mascarado).
public struct RegistrationResult: Sendable, Equatable {
    public let platform: DevicePlatform
    public let maskedToken: String
    public let contactRef: String?
    public let consent: ConsentEvidence
    /// `true` quando a API respondeu 200 (token já conhecido — update);
    /// `false` para 201 (device novo).
    public let updatedExisting: Bool
}

/// Etapas do opt-out (para reportar falha por passo).
public enum OptOutStep: String, Sendable {
    case consentRevoke
    case unregister
}

/// Falha de UMA etapa do opt-out (o fluxo continua — best-effort).
public struct OptOutStepFailure: Sendable, Equatable {
    public let step: OptOutStep
    public let reason: String
}

/// Resultado de `optOut()` — o método NÃO lança por rede: opt-out é
/// requisito legal "fácil e gratuito" (best-effort com resultado explícito).
public struct OptOutResult: Sendable, Equatable {
    public let hadRegistration: Bool
    /// `true`/`false`; `nil` = etapa não aplicável (sem contactRef).
    public let consentRevoked: Bool?
    /// `true` quando o device foi removido OU não havia o que remover.
    public let unregistered: Bool
    /// Estado local limpo. Em falha TOTAL de rede o SDK mantém o mínimo.
    public let stateCleared: Bool
    public let failures: [OptOutStepFailure]

    public var fullyOptedOut: Bool { failures.isEmpty && stateCleared }
}

/// Evento pós-unregister automático quando o usuário revoga a permissão de
/// notificação no OS (cobrança honesta — o SDK JÃO removeu o device).
public struct PermissionRevocation: Sendable, Equatable {
    public let unregistered: Bool
    public let error: String?
}

/// Resultado da rotação de token (onNewToken) — nova na 3.3: registra o NOVO
/// token (upsert, reafirmando consent quando há contactRef) e faz unregister
/// best-effort do antigo (sem isto, push duplicado até o expurgo de 90d).
public struct TokenRotationResult: Sendable, Equatable {
    public let changed: Bool
    public let registered: Bool
    public let oldRemoved: Bool?
    public let updatedExisting: Bool
}

// ---------------------------------------------------------------------------
// Estado local (formato versionado §5 — idêntico ao Flutter/Android)
// ---------------------------------------------------------------------------

/// Estado local do SDK — o MÍNIMO para heartbeat e opt-out funcionarem.
/// Nada além desses campos é persistido (minimização LGPD por construção).
public struct DeviceState: Sendable, Equatable {
    public var platform: DevicePlatform?
    public var token: String?
    public var contactRef: String?
    public var policyVersion: String?
    public var registeredAt: Date?
    public var heartbeatActive: Bool
    public var heartbeatIntervalMs: Int?

    public init(
        platform: DevicePlatform? = nil,
        token: String? = nil,
        contactRef: String? = nil,
        policyVersion: String? = nil,
        registeredAt: Date? = nil,
        heartbeatActive: Bool = false,
        heartbeatIntervalMs: Int? = nil
    ) {
        self.platform = platform
        self.token = token
        self.contactRef = contactRef
        self.policyVersion = policyVersion
        self.registeredAt = registeredAt
        self.heartbeatActive = heartbeatActive
        self.heartbeatIntervalMs = heartbeatIntervalMs
    }
}

/// Codec do JSON de estado (§5 do contrato) — puro e testável.
/// Estado corrompido/versão desconhecida ⇒ `nil` (descartar e recomeçar
/// limpo: o servidor é a fonte da verdade, o registro é upsert).
public enum StateCodec {
    public static let version = 1

    public static func toJsonString(_ state: DeviceState) -> String {
        var json: [String: Any] = [
            "v": version,
            "heartbeatActive": state.heartbeatActive,
        ]
        if let platform = state.platform { json["platform"] = platform.rawValue }
        if let token = state.token { json["token"] = token }
        if let contactRef = state.contactRef { json["contactRef"] = contactRef }
        if let policyVersion = state.policyVersion { json["policyVersion"] = policyVersion }
        if let registeredAt = state.registeredAt {
            json["registeredAt"] = Iso8601.utc.string(from: registeredAt)
        }
        if let interval = state.heartbeatIntervalMs { json["heartbeatIntervalMs"] = interval }
        return Json.encode(json)
    }

    public static func fromJsonString(_ raw: String) -> DeviceState? {
        guard let decoded = Json.decode(raw) as? [String: Any] else { return nil }
        guard (decoded["v"] as? Int) == version else { return nil }
        var platform: DevicePlatform?
        if let wire = decoded["platform"] as? String {
            guard let parsed = DevicePlatform(rawValue: wire) else { return nil }
            platform = parsed
        }
        return DeviceState(
            platform: platform,
            token: decoded["token"] as? String,
            contactRef: decoded["contactRef"] as? String,
            policyVersion: decoded["policyVersion"] as? String,
            registeredAt: (decoded["registeredAt"] as? String).flatMap { Iso8601.utc.date(from: $0) },
            heartbeatActive: (decoded["heartbeatActive"] as? Bool) ?? false,
            heartbeatIntervalMs: decoded["heartbeatIntervalMs"] as? Int
        )
    }
}

/// ISO-8601 UTC com milissegundos — mesmo wire format do Flutter/Android
/// (aceito pela API; o smoke 3.2 provou o par ISO↔zod).
public enum Iso8601 {
    public static let utc: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

/// JSON mínimo sem dependências (JSONSerialization — Foundation).
public enum Json {
    public static func encode(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func decode(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }
}
