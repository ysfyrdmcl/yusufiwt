import Crypto
import Foundation
import JWTKit
@preconcurrency import Redis
import Vapor

public enum APNSDeliveryResult: Sendable, Equatable {
    case accepted
    case invalidToken
    case retryable
    case permanentFailure(String)
}

public protocol PushNotificationProviding: Sendable {
    func sendEnvelopeHint(envelopeID: UUID, category: String, to token: String) async -> APNSDeliveryResult
}

public struct DisabledPushProvider: PushNotificationProviding {
    public init() {}
    public func sendEnvelopeHint(envelopeID: UUID, category: String, to token: String) async -> APNSDeliveryResult {
        .retryable
    }
}

public protocol LiveActivityPushProviding: Sendable {
    func sendLiveActivityUpdate(_ update: LiveActivityUpdateRequest, to token: String) async -> APNSDeliveryResult
}

public struct DisabledLiveActivityPushProvider: LiveActivityPushProviding {
    public init() {}
    public func sendLiveActivityUpdate(
        _ update: LiveActivityUpdateRequest,
        to token: String
    ) async -> APNSDeliveryResult {
        .retryable
    }
}

public protocol APNSBearerTokenProviding: Sendable {
    func bearerToken(now: Date) async throws -> String
}

private struct APNSJWTClaims: JWTPayload {
    let iss: IssuerClaim
    let iat: IssuedAtClaim
    func verify(using algorithm: some JWTAlgorithm) async throws {}
}

public actor APNSJWTBearerTokenProvider: APNSBearerTokenProviding {
    private let keys: JWTKeyCollection
    private let keyID: JWKIdentifier
    private let teamID: String
    private var cached: (token: String, createdAt: Date)?

    private init(keys: JWTKeyCollection, keyID: String, teamID: String) {
        self.keys = keys; self.keyID = JWKIdentifier(string: keyID); self.teamID = teamID
    }

    public static func make(keyID: String, teamID: String, privateKeyPEM: String) async throws -> Self {
        let key = try ES256PrivateKey(pem: privateKeyPEM)
        let keys = JWTKeyCollection()
        await keys.add(ecdsa: key, kid: JWKIdentifier(string: keyID))
        return .init(keys: keys, keyID: keyID, teamID: teamID)
    }

    public func bearerToken(now: Date) async throws -> String {
        if let cached, now.timeIntervalSince(cached.createdAt) < 3000 {
            return cached.token
        }
        let token = try await keys.sign(
            APNSJWTClaims(iss: .init(value: teamID), iat: .init(value: now)), kid: keyID
        )
        cached = (token, now)
        return token
    }
}

public struct HTTPAPNSProvider: PushNotificationProviding {
    private let client: any Client
    private let bearerTokens: any APNSBearerTokenProviding
    private let topic: String
    private let host: String

    public init(
        client: any Client,
        bearerTokens: any APNSBearerTokenProviding,
        topic: String,
        production: Bool
    ) {
        self.client = client; self.bearerTokens = bearerTokens; self.topic = topic
        host = production ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com"
    }

    public func sendEnvelopeHint(envelopeID: UUID, category: String, to token: String) async -> APNSDeliveryResult {
        do {
            let bearer = try await bearerTokens.bearerToken(now: Date())
            let response = try await client.post(URI(string: "\(host)/3/device/\(token)")) { request in
                request.headers.bearerAuthorization = .init(token: bearer)
                request.headers.replaceOrAdd(name: "apns-topic", value: topic)
                request.headers.replaceOrAdd(name: "apns-push-type", value: "alert")
                try request.content.encode(APNSHintPayload(
                    aps: .init(
                        mutableContent: 1,
                        category: category,
                        alert: .init(
                            title: "yusufiwt",
                            body: "Open yusufiwt to review a new agent event."
                        ),
                        sound: "default"
                    ),
                    envelopeID: envelopeID.uuidString.lowercased()
                ))
            }
            switch response.status.code {
            case 200: return .accepted
            case 400, 410: return .invalidToken
            case 429, 500 ... 599: return .retryable
            default: return .permanentFailure("apns-status-\(response.status.code)")
            }
        } catch {
            return .retryable
        }
    }
}

public struct HTTPAPNSLiveActivityProvider: LiveActivityPushProviding {
    private let client: any Client
    private let bearerTokens: any APNSBearerTokenProviding
    private let topic: String
    private let host: String

    public init(
        client: any Client,
        bearerTokens: any APNSBearerTokenProviding,
        topic: String,
        production: Bool
    ) {
        self.client = client
        self.bearerTokens = bearerTokens
        self.topic = topic
        host = production ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com"
    }

    public func sendLiveActivityUpdate(
        _ update: LiveActivityUpdateRequest,
        to token: String
    ) async -> APNSDeliveryResult {
        do {
            let bearer = try await bearerTokens.bearerToken(now: Date())
            let response = try await client.post(URI(string: "\(host)/3/device/\(token)")) { request in
                request.headers.bearerAuthorization = .init(token: bearer)
                request.headers.replaceOrAdd(name: "apns-topic", value: topic)
                request.headers.replaceOrAdd(name: "apns-push-type", value: "liveactivity")
                request.headers.replaceOrAdd(name: "apns-priority", value: "10")
                try request.content.encode(LiveActivityAPNSPayload(update: update))
            }
            switch response.status.code {
            case 200: return .accepted
            case 400, 410: return .invalidToken
            case 429, 500 ... 599: return .retryable
            default: return .permanentFailure("apns-liveactivity-status-\(response.status.code)")
            }
        } catch {
            return .retryable
        }
    }
}

struct LiveActivityAPNSContentState: Codable {
    let state: String
    let updatedAtEpochSeconds: Int
    let staleAtEpochSeconds: Int
}

struct LiveActivityAPNSBody: Codable {
    let timestamp: Int
    let event: String
    let contentState: LiveActivityAPNSContentState
    let staleDate: Int
    let dismissalDate: Int?

    enum CodingKeys: String, CodingKey {
        case timestamp, event
        case contentState = "content-state"
        case staleDate = "stale-date"
        case dismissalDate = "dismissal-date"
    }
}

struct LiveActivityAPNSPayload: Content {
    let aps: LiveActivityAPNSBody

    init(update: LiveActivityUpdateRequest) {
        let terminal = ["completed", "failed", "cancelled"].contains(update.state)
        let updated = Int(update.updatedAt.timeIntervalSince1970)
        let stale = Int(update.staleAt.timeIntervalSince1970)
        aps = LiveActivityAPNSBody(
            timestamp: updated,
            event: terminal ? "end" : "update",
            contentState: .init(
                state: update.state,
                updatedAtEpochSeconds: updated,
                staleAtEpochSeconds: stale
            ),
            staleDate: stale,
            dismissalDate: terminal ? updated + 60 : nil
        )
    }
}

private struct APNSPayloadAPS: Codable {
    struct Alert: Codable { let title: String; let body: String }
    let mutableContent: Int
    let category: String
    let alert: Alert
    let sound: String
    enum CodingKeys: String, CodingKey { case mutableContent = "mutable-content"; case category, alert, sound }
}

private struct APNSHintPayload: Content {
    let aps: APNSPayloadAPS
    let envelopeID: String
    enum CodingKeys: String, CodingKey { case aps; case envelopeID = "envelope_id" }
}

public protocol PresenceProviding: Sendable {
    func markOnline(deviceID: UUID) async
    func markOffline(deviceID: UUID) async
    func isOnline(deviceID: UUID) async -> Bool
}

public protocol TransientEnvelopeQueueing: Sendable {
    func enqueue(deviceID: UUID, envelopeID: UUID) async
}

public actor MemoryPresenceProvider: PresenceProviding {
    private var online: Set<UUID> = []
    public init() {}
    public func markOnline(deviceID: UUID) {
        online.insert(deviceID)
    }

    public func markOffline(deviceID: UUID) {
        online.remove(deviceID)
    }

    public func isOnline(deviceID: UUID) -> Bool {
        online.contains(deviceID)
    }
}

extension MemoryPresenceProvider: TransientEnvelopeQueueing {
    public func enqueue(deviceID: UUID, envelopeID: UUID) {}
}

public struct RedisEphemeralProvider: PresenceProviding, TransientEnvelopeQueueing {
    private let client: Application.Redis
    private let presenceTTL: Int
    private let envelopeTTL: Int

    public init(client: Application.Redis, presenceTTL: Int = 90, envelopeTTL: Int = 600) {
        self.client = client; self.presenceTTL = presenceTTL; self.envelopeTTL = envelopeTTL
    }

    public func markOnline(deviceID: UUID) async {
        _ = try? await client.set(
            RedisKey("presence:\(deviceID.uuidString.lowercased())"), to: "1",
            onCondition: .none, expiration: .seconds(presenceTTL)
        ).get()
    }

    public func markOffline(deviceID: UUID) async {
        _ = try? await client.delete(RedisKey("presence:\(deviceID.uuidString.lowercased())")).get()
    }

    public func isOnline(deviceID: UUID) async -> Bool {
        await (try? client.get(RedisKey("presence:\(deviceID.uuidString.lowercased())"), as: String.self).get()) != nil
    }

    public func enqueue(deviceID: UUID, envelopeID: UUID) async {
        let key = RedisKey("pending:\(deviceID.uuidString.lowercased())")
        _ = try? await client.lpush(envelopeID.uuidString.lowercased(), into: key).get()
        _ = try? await client.expire(key, after: .seconds(Int64(envelopeTTL))).get()
    }
}

private struct PushProviderKey: StorageKey { typealias Value = any PushNotificationProviding }
private struct LiveActivityPushProviderKey: StorageKey { typealias Value = any LiveActivityPushProviding }
private struct PresenceProviderKey: StorageKey { typealias Value = any PresenceProviding }
private struct TransientQueueKey: StorageKey { typealias Value = any TransientEnvelopeQueueing }

public extension Application {
    var pushProvider: any PushNotificationProviding {
        get {
            guard let value = storage[PushProviderKey.self] else {
                preconditionFailure("Push provider was not installed")
            }
            return value
        }
        set { storage[PushProviderKey.self] = newValue }
    }

    var liveActivityPushProvider: any LiveActivityPushProviding {
        get {
            guard let value = storage[LiveActivityPushProviderKey.self] else {
                preconditionFailure("Live Activity push provider was not installed")
            }
            return value
        }
        set { storage[LiveActivityPushProviderKey.self] = newValue }
    }

    var presenceProvider: any PresenceProviding {
        get {
            guard let value = storage[PresenceProviderKey.self] else {
                preconditionFailure("Presence provider was not installed")
            }
            return value
        }
        set { storage[PresenceProviderKey.self] = newValue }
    }

    var transientEnvelopeQueue: any TransientEnvelopeQueueing {
        get {
            guard let value = storage[TransientQueueKey.self] else {
                preconditionFailure("Transient queue was not installed")
            }
            return value
        }
        set { storage[TransientQueueKey.self] = newValue }
    }
}

struct PushTokenVault: Sendable {
    private let key: SymmetricKey
    init(secret: String) {
        key = .init(data: Data(SHA256.hash(data: Data((secret + "/apns").utf8))))
    }

    func seal(_ token: String) throws -> Data {
        try ChaChaPoly.seal(Data(token.utf8), using: key).combined
    }

    func open(_ ciphertext: Data) throws -> String {
        let clear = try ChaChaPoly.open(.init(combined: ciphertext), using: key)
        guard let token = String(data: clear, encoding: .utf8) else { throw Abort(.internalServerError) }
        return token
    }
}

struct PushTokenVaultKey: StorageKey { typealias Value = PushTokenVault }
extension Application {
    var pushTokenVault: PushTokenVault {
        guard let value = storage[PushTokenVaultKey.self] else {
            preconditionFailure("Push token vault was not installed")
        }
        return value
    }
}
