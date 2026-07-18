import Crypto
import Fluent
import Foundation
import JWTKit
import Vapor

public struct AuthenticatedDevice: Authenticatable, Sendable {
    public let userID: UUID
    public let deviceID: UUID
    public let role: ServerDeviceRole
}

private struct AccessTokenClaims: Codable, Sendable {
    let userID: UUID
    let deviceID: UUID
    let role: ServerDeviceRole
    let expiresAt: Date
    let tokenID: UUID
}

public struct AccessTokenService: Sendable {
    private let key: SymmetricKey
    public init(secret: String) {
        key = SymmetricKey(data: Data(secret.utf8))
    }

    public func issue(for device: AuthenticatedDevice, expiresAt: Date) throws -> String {
        let claims = AccessTokenClaims(
            userID: device.userID, deviceID: device.deviceID, role: device.role,
            expiresAt: expiresAt, tokenID: UUID()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(claims).base64URLEncodedString()
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)).base64URLEncodedString()
        return payload + "." + signature
    }

    public func verify(_ token: String, now: Date = Date()) throws -> AuthenticatedDevice {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let signature = Data(base64URL: String(parts[1])) else { throw Abort(.unauthorized) }
        let payload = String(parts[0])
        guard HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Data(payload.utf8), using: key),
              let data = Data(base64URL: payload)
        else { throw Abort(.unauthorized) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let claims = try? decoder.decode(AccessTokenClaims.self, from: data), claims.expiresAt > now else {
            throw Abort(.unauthorized)
        }
        return .init(userID: claims.userID, deviceID: claims.deviceID, role: claims.role)
    }
}

extension Data {
    init?(base64URL value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public protocol AppleIdentityVerifying: Sendable {
    func verify(identityToken: String, nonce: String?, client: any Client) async throws -> String
}

struct AppleIdentityClaims: JWTPayload {
    let iss: IssuerClaim
    let sub: SubjectClaim
    let aud: AudienceClaim
    let exp: ExpirationClaim
    let nonce: String?

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
        guard iss.value == "https://appleid.apple.com" else { throw Abort(.unauthorized) }
    }
}

public actor AppleIdentityTokenVerifier: AppleIdentityVerifying {
    private let audiences: Set<String>
    private let keys = JWTKeyCollection()
    private var loadedAt: Date?

    public init(audiences: Set<String>) {
        self.audiences = audiences
    }

    public func verify(identityToken: String, nonce: String?, client: any Client) async throws -> String {
        if loadedAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
            let response = try await client.get(URI(string: "https://appleid.apple.com/auth/keys"))
            guard response.status == .ok, var body = response.body,
                  let json = body.readString(length: body.readableBytes)
            else { throw Abort(.serviceUnavailable, reason: "Apple key service unavailable") }
            try await keys.add(jwksJSON: json)
            loadedAt = Date()
        }
        let claims = try await keys.verify(identityToken, as: AppleIdentityClaims.self)
        let hasAllowedAudience = audiences.contains { audience in
            do {
                try claims.aud.verifyIntendedAudience(includes: audience)
                return true
            } catch {
                return false
            }
        }
        guard hasAllowedAudience else { throw Abort(.unauthorized, reason: "Invalid Sign in with Apple audience") }
        if let nonce, claims.nonce != nonce {
            throw Abort(.unauthorized, reason: "Invalid Sign in with Apple nonce")
        }
        guard !claims.sub.value.isEmpty else { throw Abort(.unauthorized) }
        return claims.sub.value
    }
}

private struct AppleVerifierKey: StorageKey { typealias Value = any AppleIdentityVerifying }
private struct AccessTokenServiceKey: StorageKey { typealias Value = AccessTokenService }

public extension Application {
    var appleIdentityVerifier: any AppleIdentityVerifying {
        get {
            guard let value = storage[AppleVerifierKey.self] else {
                preconditionFailure("Apple identity verifier was not installed")
            }
            return value
        }
        set { storage[AppleVerifierKey.self] = newValue }
    }

    var accessTokenService: AccessTokenService {
        get {
            guard let value = storage[AccessTokenServiceKey.self] else {
                preconditionFailure("Access token service was not installed")
            }
            return value
        }
        set { storage[AccessTokenServiceKey.self] = newValue }
    }
}

struct DeviceAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        let identity = try request.application.accessTokenService.verify(bearer.token)
        guard let model = try await DeviceModel.find(identity.deviceID, on: request.db),
              model.userID == identity.userID, model.revokedAt == nil, model.role == identity.role.rawValue
        else { throw Abort(.unauthorized) }
        request.auth.login(identity)
    }
}

actor SlidingWindowRateLimiter {
    private var entries: [String: [Date]] = [:]
    func check(key: String, limit: Int, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-60)
        var recent = entries[key, default: []].filter { $0 > cutoff }
        guard recent.count < limit else { entries[key] = recent; return false }
        recent.append(now); entries[key] = recent; return true
    }
}

struct RateLimiterKey: StorageKey { typealias Value = SlidingWindowRateLimiter }
extension Application {
    var rateLimiter: SlidingWindowRateLimiter {
        guard let value = storage[RateLimiterKey.self] else {
            preconditionFailure("Rate limiter was not installed")
        }
        return value
    }
}

struct RateLimitMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let key = request.auth.get(AuthenticatedDevice.self)?.deviceID.uuidString
            ?? request.headers.first(name: "X-Forwarded-For") ?? request.remoteAddress?.ipAddress ?? "unknown"
        guard await request.application.rateLimiter.check(key: key, limit: request.application.relayConfiguration.rateLimitPerMinute) else {
            throw Abort(.tooManyRequests)
        }
        return try await next.respond(to: request)
    }
}

enum SecretHash {
    static func make(_ value: String, pepper: String) -> String {
        Data(SHA256.hash(data: Data((value + pepper).utf8))).base64URLEncodedString()
    }
}

func randomToken(byteCount: Int = 32) -> String {
    var generator = SystemRandomNumberGenerator()
    return Data((0 ..< byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64URLEncodedString()
}
