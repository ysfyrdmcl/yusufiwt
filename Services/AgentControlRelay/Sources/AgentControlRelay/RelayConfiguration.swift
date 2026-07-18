import Foundation
import Vapor

public struct RelayConfiguration: Sendable {
    public let publicBaseURL: URL
    public let accessTokenTTL: TimeInterval
    public let refreshTokenTTL: TimeInterval
    public let pairingTTL: TimeInterval
    public let envelopeTTL: TimeInterval
    public let maxEnvelopeBytes: Int
    public let maxPendingPerDevice: Int
    public let rateLimitPerMinute: Int
    public let tokenSecret: String
    public let tokenHashPepper: String
    public let allowedAppleAudiences: Set<String>
    public let dataRetentionHours: Int

    public init(
        publicBaseURL: URL,
        accessTokenTTL: TimeInterval = 900,
        refreshTokenTTL: TimeInterval = 2_592_000,
        pairingTTL: TimeInterval = 300,
        envelopeTTL: TimeInterval = 600,
        maxEnvelopeBytes: Int = 65536,
        maxPendingPerDevice: Int = 1000,
        rateLimitPerMinute: Int = 120,
        tokenSecret: String,
        tokenHashPepper: String,
        allowedAppleAudiences: Set<String>,
        dataRetentionHours: Int = 24
    ) {
        self.publicBaseURL = publicBaseURL
        self.accessTokenTTL = accessTokenTTL
        self.refreshTokenTTL = refreshTokenTTL
        self.pairingTTL = pairingTTL
        self.envelopeTTL = envelopeTTL
        self.maxEnvelopeBytes = maxEnvelopeBytes
        self.maxPendingPerDevice = maxPendingPerDevice
        self.rateLimitPerMinute = rateLimitPerMinute
        self.tokenSecret = tokenSecret
        self.tokenHashPepper = tokenHashPepper
        self.allowedAppleAudiences = allowedAppleAudiences
        self.dataRetentionHours = dataRetentionHours
    }

    public static func fromEnvironment(_ environment: Environment) throws -> Self {
        let values = ProcessInfo.processInfo.environment
        func required(_ name: String) throws -> String {
            guard let value = values[name], !value.isEmpty, value != "example-required" else {
                throw Abort(.internalServerError, reason: "Missing required relay configuration: \(name)")
            }
            return value
        }
        func integer(_ name: String, _ fallback: Int) -> Int {
            values[name].flatMap(Int.init) ?? fallback
        }
        guard let baseURL = URL(string: values["PUBLIC_BASE_URL"] ?? "http://localhost:8080") else {
            throw Abort(.internalServerError, reason: "Invalid PUBLIC_BASE_URL")
        }
        let isProduction = environment == .production
        let secret = isProduction ? try required("JWT_SIGNING_PRIVATE_KEY_B64") : values["JWT_SIGNING_PRIVATE_KEY_B64"] ?? "development-only-token-key"
        let pepper = isProduction ? try required("TOKEN_HASH_PEPPER") : values["TOKEN_HASH_PEPPER"] ?? "development-only-pepper"
        let audiences = Set((values["SIWA_ALLOWED_AUDIENCES"] ?? "com.yusuf.agentcontrol.ios,com.yusuf.agentcontrol.service")
            .split(separator: ",").map(String.init))
        return .init(
            publicBaseURL: baseURL,
            accessTokenTTL: TimeInterval(integer("ACCESS_TOKEN_TTL_SECONDS", 900)),
            refreshTokenTTL: TimeInterval(integer("REFRESH_TOKEN_TTL_DAYS", 30) * 86400),
            pairingTTL: TimeInterval(integer("PAIRING_TTL_SECONDS", 300)),
            envelopeTTL: TimeInterval(integer("ENVELOPE_TTL_SECONDS", 600)),
            maxEnvelopeBytes: integer("MAX_ENVELOPE_BYTES", 65536),
            maxPendingPerDevice: integer("MAX_PENDING_ENVELOPES_PER_DEVICE", 1000),
            rateLimitPerMinute: integer("RATE_LIMIT_REQUESTS_PER_MINUTE", 120),
            tokenSecret: secret,
            tokenHashPepper: pepper,
            allowedAppleAudiences: audiences,
            dataRetentionHours: integer("DATA_RETENTION_HOURS", 24)
        )
    }
}

private struct RelayConfigurationKey: StorageKey { typealias Value = RelayConfiguration }

public extension Application {
    var relayConfiguration: RelayConfiguration {
        get {
            guard let value = storage[RelayConfigurationKey.self] else {
                preconditionFailure("Relay configuration was not installed")
            }
            return value
        }
        set { storage[RelayConfigurationKey.self] = newValue }
    }
}
