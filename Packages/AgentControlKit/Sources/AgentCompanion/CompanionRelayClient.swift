#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import AgentDomain
import Foundation

public struct CompanionAuthRequest: Codable, Sendable {
    public let identityToken: String
    public let nonce: String?
    public let deviceID: UUID
    public let role: CompanionDeviceRole
    public let displayName: String
    public let agreementPublicKey: Data
    public let signingPublicKey: Data

    public init(
        identityToken: String,
        nonce: String?,
        deviceID: UUID,
        role: CompanionDeviceRole,
        displayName: String,
        agreementPublicKey: Data,
        signingPublicKey: Data
    ) {
        self.identityToken = identityToken
        self.nonce = nonce
        self.deviceID = deviceID
        self.role = role
        self.displayName = displayName
        self.agreementPublicKey = agreementPublicKey
        self.signingPublicKey = signingPublicKey
    }
}

public struct CompanionTokenResponse: Codable, Equatable, Sendable {
    public let accessToken: String
    public let accessTokenExpiresAt: Date
    public let refreshToken: String

    public init(accessToken: String, accessTokenExpiresAt: Date, refreshToken: String) {
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
    }
}

public struct CompanionDeviceRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let role: CompanionDeviceRole
    public let displayName: String
    public let agreementPublicKey: Data
    public let signingPublicKey: Data
    public let revokedAt: Date?
}

public struct CompanionPairingSession: Codable, Equatable, Sendable {
    public let id: UUID
    public let macDeviceID: UUID
    public let macEphemeralPublicKey: Data
    public let phoneDeviceID: UUID?
    public let phoneEphemeralPublicKey: Data?
    public let expiresAt: Date
}

public actor CompanionRelayClient {
    private let baseURL: URL
    private let session: URLSession
    private var accessToken: String?

    public init(baseURL: URL, accessToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.session = session
    }

    public func updateAccessToken(_ token: String?) {
        accessToken = token
    }

    public func authenticate(_ input: CompanionAuthRequest) async throws -> CompanionTokenResponse {
        var request = try makeRequest(path: "v1/auth/apple", method: "POST", authenticated: false)
        request.httpBody = try CompanionCoding.makeEncoder().encode(input)
        let response: CompanionTokenResponse = try await perform(request)
        accessToken = response.accessToken
        return response
    }

    public func refresh(_ refreshToken: String) async throws -> CompanionTokenResponse {
        var request = try makeRequest(path: "v1/auth/refresh", method: "POST", authenticated: false)
        request.httpBody = try CompanionCoding.makeEncoder().encode(RefreshBody(refreshToken: refreshToken))
        let response: CompanionTokenResponse = try await perform(request)
        accessToken = response.accessToken
        return response
    }

    public func completePairing(sessionID: UUID, phoneEphemeralPublicKey: Data) async throws -> CompanionPairingSession {
        var request = try makeRequest(path: "v1/pairing/sessions/\(sessionID.uuidString.lowercased())/complete", method: "POST")
        request.httpBody = try CompanionCoding.makeEncoder().encode(
            PairingBody(phoneEphemeralPublicKey: phoneEphemeralPublicKey)
        )
        return try await perform(request)
    }

    public func devices() async throws -> [CompanionDeviceRecord] {
        try await perform(makeRequest(path: "v1/devices", method: "GET"))
    }

    public func revokeDevice(_ id: UUID) async throws {
        let request = try makeRequest(path: "v1/devices/\(id.uuidString.lowercased())", method: "DELETE")
        try await performWithoutBody(request)
    }

    public func deleteAccount() async throws {
        let request = try makeRequest(path: "v1/account", method: "DELETE")
        try await performWithoutBody(request)
        accessToken = nil
    }

    public func registerPushToken(id: UUID, token: String, environment: String) async throws {
        var request = try makeRequest(path: "v1/push/tokens", method: "POST")
        request.httpBody = try CompanionCoding.makeEncoder().encode(
            PushTokenBody(id: id, token: token, environment: environment)
        )
        try await performWithoutBody(request)
    }

    public func registerLiveActivityToken(
        id: UUID,
        sessionID: UUID,
        token: String,
        environment: String,
        expiresAt: Date
    ) async throws {
        var request = try makeRequest(path: "v1/live-activities/tokens", method: "POST")
        request.httpBody = try CompanionCoding.makeEncoder().encode(
            LiveActivityTokenBody(
                id: id, sessionID: sessionID, token: token,
                environment: environment, expiresAt: expiresAt
            )
        )
        try await performWithoutBody(request)
    }

    public func updateLiveActivity(
        recipientDeviceID: UUID,
        sessionID: UUID,
        state: String,
        updatedAt: Date,
        staleAt: Date
    ) async throws {
        var request = try makeRequest(path: "v1/live-activities/update", method: "POST")
        request.httpBody = try CompanionCoding.makeEncoder().encode(
            LiveActivityUpdateBody(
                recipientDeviceID: recipientDeviceID, sessionID: sessionID,
                state: state, updatedAt: updatedAt, staleAt: staleAt
            )
        )
        try await performWithoutBody(request)
    }

    public func pending(after cursor: UInt64) async throws -> (envelopes: [SealedRelayEnvelope], cursor: UInt64) {
        let response: PendingBody = try await perform(
            makeRequest(path: "v1/envelopes/pending?after=\(cursor)", method: "GET")
        )
        return (response.envelopes, response.cursor)
    }

    public func submit(_ envelope: SealedRelayEnvelope, idempotencyKey: UUID = UUID()) async throws {
        var request = try makeRequest(path: "v1/envelopes", method: "POST")
        request.setValue(idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try CompanionCoding.makeEncoder().encode(envelope)
        try await performWithoutBody(request)
    }

    public func acknowledge(_ envelopeID: UUID, idempotencyKey: UUID = UUID()) async throws {
        var request = try makeRequest(
            path: "v1/envelopes/\(envelopeID.uuidString.lowercased())/ack", method: "POST"
        )
        request.setValue(idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        try await performWithoutBody(request)
    }

    private func makeRequest(path: String, method: String, authenticated: Bool = true) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw RelayClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let accessToken else { throw RelayClientError.rejected(401) }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data = try await performData(request)
        return try CompanionCoding.makeDecoder().decode(Response.self, from: data)
    }

    private func performWithoutBody(_ request: URLRequest) async throws {
        _ = try await performData(request)
    }

    private func performData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayClientError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayClientError.rejected(http.statusCode) }
        return data
    }

    private struct RefreshBody: Codable { let refreshToken: String }
    private struct PairingBody: Codable { let phoneEphemeralPublicKey: Data }
    private struct PushTokenBody: Codable { let id: UUID; let token: String; let environment: String }
    private struct LiveActivityTokenBody: Codable {
        let id: UUID
        let sessionID: UUID
        let token: String
        let environment: String
        let expiresAt: Date
    }

    private struct LiveActivityUpdateBody: Codable {
        let recipientDeviceID: UUID
        let sessionID: UUID
        let state: String
        let updatedAt: Date
        let staleAt: Date
    }

    private struct PendingBody: Codable { let envelopes: [SealedRelayEnvelope]; let cursor: UInt64 }
}

public struct CompanionSecureState: Codable, Sendable {
    public let identityDeviceID: DeviceID
    public let identityKeyID: UUID
    public let agreementPrivateKey: Data
    public let signingPrivateKey: Data
    public let relayBaseURL: URL
    public var accessToken: String
    public var accessTokenExpiresAt: Date
    public var refreshToken: String
    public var macDeviceID: DeviceID?
    public var macAgreementPublicKey: Data?
    public var macSigningPublicKey: Data?
    public var fingerprint: String?

    public init(
        identity: CompanionIdentity,
        relayBaseURL: URL,
        tokens: CompanionTokenResponse,
        macDeviceID: DeviceID? = nil,
        macAgreementPublicKey: Data? = nil,
        macSigningPublicKey: Data? = nil,
        fingerprint: String? = nil
    ) {
        identityDeviceID = identity.deviceID
        identityKeyID = identity.keyID
        agreementPrivateKey = identity.agreementPrivateKey
        signingPrivateKey = identity.signingPrivateKey
        self.relayBaseURL = relayBaseURL
        accessToken = tokens.accessToken
        accessTokenExpiresAt = tokens.accessTokenExpiresAt
        refreshToken = tokens.refreshToken
        self.macDeviceID = macDeviceID
        self.macAgreementPublicKey = macAgreementPublicKey
        self.macSigningPublicKey = macSigningPublicKey
        self.fingerprint = fingerprint
    }

    public func identity() throws -> CompanionIdentity {
        try .init(
            deviceID: identityDeviceID,
            role: .iPhone,
            keyID: identityKeyID,
            agreementPrivateKey: agreementPrivateKey,
            signingPrivateKey: signingPrivateKey
        )
    }
}
