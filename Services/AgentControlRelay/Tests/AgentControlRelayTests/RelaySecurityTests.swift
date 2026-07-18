// swiftlint:disable file_length
@testable import AgentControlRelay
import Crypto
import Foundation
import Testing
import Vapor
import VaporTesting

private struct FixedAppleVerifier: AppleIdentityVerifying {
    let subject: String?
    func verify(identityToken: String, nonce: String?, client: any Client) async throws -> String {
        guard let subject, identityToken == "valid" else { throw Abort(.unauthorized) }
        return subject
    }
}

private struct InvalidTokenPushProvider: PushNotificationProviding {
    func sendEnvelopeHint(envelopeID: UUID, category: String, to token: String) async -> APNSDeliveryResult {
        .invalidToken
    }
}

private struct RetryablePushProvider: PushNotificationProviding {
    func sendEnvelopeHint(envelopeID: UUID, category: String, to token: String) async -> APNSDeliveryResult {
        .retryable
    }
}

private actor RecordingLiveActivityPushProvider: LiveActivityPushProviding {
    private(set) var updates: [LiveActivityUpdateRequest] = []

    func sendLiveActivityUpdate(
        _ update: LiveActivityUpdateRequest,
        to token: String
    ) async -> APNSDeliveryResult {
        updates.append(update)
        return .accepted
    }

    func count() -> Int {
        updates.count
    }
}

private struct TestDevice {
    let id: UUID
    let agreementKey: Curve25519.KeyAgreement.PrivateKey
    let signingKey: Curve25519.Signing.PrivateKey
    let role: ServerDeviceRole
    var agreementPublicKey: Data {
        agreementKey.publicKey.rawRepresentation
    }

    var signingPublicKey: Data {
        signingKey.publicKey.rawRepresentation
    }

    init(id: UUID = UUID(), role: ServerDeviceRole) {
        self.id = id; agreementKey = .init(); signingKey = .init(); self.role = role
    }
}

private func configuredApp(_ app: Application) async throws {
    try await configure(app)
    app.appleIdentityVerifier = FixedAppleVerifier(subject: "apple-user-fixture")
}

private func authenticate(_ device: TestDevice, on app: Application) async throws -> TokenResponse {
    let response = try await app.testing().sendRequest(.POST, "/v1/auth/apple") { request in
        try request.content.encode(AppleAuthenticationRequest(
            identityToken: "valid", nonce: nil, deviceID: device.id, role: device.role,
            displayName: device.role.rawValue, agreementPublicKey: device.agreementPublicKey,
            signingPublicKey: device.signingPublicKey
        ))
    }
    #expect(response.status == .ok)
    return try response.content.decode(TokenResponse.self)
}

private func bearer(_ token: String) -> HTTPHeaders {
    var headers = HTTPHeaders()
    headers.bearerAuthorization = .init(token: token)
    return headers
}

private func signedEnvelope(
    sender: TestDevice,
    recipient: TestDevice,
    sequence: UInt64,
    kind: ServerEnvelopeKind,
    now: Date = Date()
) throws -> RelayEnvelopeDTO {
    let now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
    let envelopeID = UUID()
    let sharedSecret = try sender.agreementKey.sharedSecretFromKeyAgreement(with: recipient.agreementKey.publicKey)
    let encryptionKey = sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: Data(envelopeID.uuidString.utf8),
        sharedInfo: Data("AgentControl/relay/test-envelope/v1".utf8),
        outputByteCount: 32
    )
    let ciphertext = try ChaChaPoly.seal(
        Data("{\"request\":\"encrypted-fixture\"}".utf8),
        using: encryptionKey
    ).combined
    var value = RelayEnvelopeDTO(
        envelopeVersion: 1, envelopeID: envelopeID, senderDeviceID: sender.id, recipientDeviceID: recipient.id,
        kind: kind, createdAt: now, expiresAt: now.addingTimeInterval(120), sequence: sequence,
        keyID: UUID(), ciphertext: ciphertext, signature: Data()
    )
    let signature = try sender.signingKey.signature(for: value.signingBytes)
    value = .init(
        envelopeVersion: value.envelopeVersion, envelopeID: value.envelopeID,
        senderDeviceID: value.senderDeviceID, recipientDeviceID: value.recipientDeviceID,
        kind: value.kind, createdAt: value.createdAt, expiresAt: value.expiresAt,
        sequence: value.sequence, keyID: value.keyID, ciphertext: value.ciphertext, signature: signature
    )
    return value
}

@Test func invalidAppleTokenAndSingleMacRule() async throws {
    try await withApp(configure: configuredApp) { app in
        let mac = TestDevice(role: .localMac)
        try await app.testing().test(.POST, "/v1/auth/apple") { request in
            try request.content.encode(AppleAuthenticationRequest(
                identityToken: "invalid", nonce: nil, deviceID: mac.id, role: .localMac,
                displayName: "Mac", agreementPublicKey: mac.agreementPublicKey, signingPublicKey: mac.signingPublicKey
            ))
        } afterResponse: { response in
            #expect(response.status == .unauthorized)
        }

        _ = try await authenticate(mac, on: app)
        let secondMac = TestDevice(role: .localMac)
        try await app.testing().test(.POST, "/v1/auth/apple") { request in
            try request.content.encode(AppleAuthenticationRequest(
                identityToken: "valid", nonce: nil, deviceID: secondMac.id, role: .localMac,
                displayName: "Other Mac", agreementPublicKey: secondMac.agreementPublicKey,
                signingPublicKey: secondMac.signingPublicKey
            ))
        } afterResponse: { response in
            #expect(response.status == .conflict)
        }
    }
}

@Test func encryptedStoreForwardReplayTamperAndPendingReconciliation() async throws {
    try await withApp(configure: configuredApp) { app in
        let mac = TestDevice(role: .localMac), phone = TestDevice(role: .iPhone)
        let macToken = try await authenticate(mac, on: app)
        let phoneToken = try await authenticate(phone, on: app)
        let unknownPhone = TestDevice(role: .iPhone)
        let wrongRecipient = try signedEnvelope(
            sender: mac, recipient: unknownPhone, sequence: 1, kind: .approvalRequest
        )
        try await app.testing().test(.POST, "/v1/envelopes", headers: bearer(macToken.accessToken)) { request in
            try request.content.encode(wrongRecipient)
        } afterResponse: { response in #expect(response.status == .notFound) }
        let envelope = try signedEnvelope(sender: mac, recipient: phone, sequence: 1, kind: .approvalRequest)

        try await app.testing().test(.POST, "/v1/envelopes", headers: bearer(macToken.accessToken)) { request in
            try request.content.encode(envelope)
        } afterResponse: { response in #expect(response.status == .ok) }

        try await app.testing().test(.GET, "/v1/envelopes/pending?after=0", headers: bearer(phoneToken.accessToken)) { response in
            #expect(response.status == .ok)
            let pending = try response.content.decode(PendingEnvelopeResponse.self)
            #expect(pending.envelopes == [envelope])
            #expect(pending.cursor == 1)
            let sharedSecret = try phone.agreementKey.sharedSecretFromKeyAgreement(with: mac.agreementKey.publicKey)
            let encryptionKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data(envelope.envelopeID.uuidString.utf8),
                sharedInfo: Data("AgentControl/relay/test-envelope/v1".utf8),
                outputByteCount: 32
            )
            let sealedBox = try ChaChaPoly.SealedBox(combined: pending.envelopes[0].ciphertext)
            let plaintext = try ChaChaPoly.open(sealedBox, using: encryptionKey)
            #expect(plaintext == Data("{\"request\":\"encrypted-fixture\"}".utf8))
        }

        let persisted = try #require(try await EnvelopeModel.find(envelope.envelopeID, on: app.db))
        #expect(persisted.ciphertext.range(of: Data("encrypted-fixture".utf8)) == nil)

        let replay = try signedEnvelope(sender: mac, recipient: phone, sequence: 1, kind: .sessionStatus)
        try await app.testing().test(.POST, "/v1/envelopes", headers: bearer(macToken.accessToken)) { request in
            try request.content.encode(replay)
        } afterResponse: { response in #expect(response.status == .conflict) }

        let valid = try signedEnvelope(sender: mac, recipient: phone, sequence: 2, kind: .sessionStatus)
        let tampered = RelayEnvelopeDTO(
            envelopeVersion: valid.envelopeVersion, envelopeID: valid.envelopeID,
            senderDeviceID: valid.senderDeviceID, recipientDeviceID: valid.recipientDeviceID,
            kind: valid.kind, createdAt: valid.createdAt, expiresAt: valid.expiresAt,
            sequence: valid.sequence, keyID: valid.keyID, ciphertext: Data("tampered".utf8), signature: valid.signature
        )
        try await app.testing().test(.POST, "/v1/envelopes", headers: bearer(macToken.accessToken)) { request in
            try request.content.encode(tampered)
        } afterResponse: { response in #expect(response.status == .unprocessableEntity) }
    }
}

@Test func slidingWindowRateLimitRejectsOverflow() async {
    let limiter = SlidingWindowRateLimiter()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    #expect(await limiter.check(key: "device", limit: 2, now: now))
    #expect(await limiter.check(key: "device", limit: 2, now: now))
    #expect(await !limiter.check(key: "device", limit: 2, now: now))
    #expect(await limiter.check(key: "device", limit: 2, now: now.addingTimeInterval(61)))
}

@Test func pairingExpiryRefreshRotationAndRevokeAreImmediate() async throws {
    try await withApp(configure: configuredApp) { app in
        let mac = TestDevice(role: .localMac), phone = TestDevice(role: .iPhone)
        let macToken = try await authenticate(mac, on: app)
        let phoneToken = try await authenticate(phone, on: app)
        let pairingResponse = try await app.testing().sendRequest(
            .POST, "/v1/pairing/sessions", headers: bearer(macToken.accessToken)
        ) { request in try request.content.encode(CreatePairingRequest(macEphemeralPublicKey: Data(repeating: 1, count: 32))) }
        let pairing = try pairingResponse.content.decode(PairingSessionResponse.self)
        let model = try #require(try await PairingSessionModel.find(pairing.id, on: app.db))
        model.expiresAt = Date().addingTimeInterval(-1)
        try await model.update(on: app.db)
        try await app.testing().test(
            .POST, "/v1/pairing/sessions/\(pairing.id)/complete", headers: bearer(phoneToken.accessToken)
        ) { request in try request.content.encode(CompletePairingRequest(phoneEphemeralPublicKey: Data(repeating: 2, count: 32))) }
            afterResponse: { response in #expect(response.status == .gone) }

        var idempotentHeaders = HTTPHeaders()
        idempotentHeaders.replaceOrAdd(name: "Idempotency-Key", value: UUID().uuidString)
        let refreshed = try await app.testing().sendRequest(.POST, "/v1/auth/refresh", headers: idempotentHeaders) { request in
            try request.content.encode(RefreshRequest(refreshToken: phoneToken.refreshToken))
        }
        #expect(refreshed.status == .ok)
        let replayedRefresh = try await app.testing().sendRequest(
            .POST, "/v1/auth/refresh", headers: idempotentHeaders
        ) { request in try request.content.encode(RefreshRequest(refreshToken: phoneToken.refreshToken)) }
        #expect(replayedRefresh.status == .ok)
        #expect(replayedRefresh.body == refreshed.body)
        try await app.testing().test(.POST, "/v1/auth/refresh") { request in
            try request.content.encode(RefreshRequest(refreshToken: phoneToken.refreshToken))
        } afterResponse: { response in #expect(response.status == .unauthorized) }

        try await app.testing().test(.DELETE, "/v1/devices/\(phone.id)", headers: bearer(macToken.accessToken)) { response in
            #expect(response.status == .noContent)
        }
        try await app.testing().test(.GET, "/v1/devices", headers: bearer(phoneToken.accessToken)) { response in
            #expect(response.status == .unauthorized)
        }
    }
}

@Test func invalidAPNSTokenIsRemovedWithoutExposingIt() async throws {
    try await withApp(configure: configuredApp) { app in
        app.pushProvider = InvalidTokenPushProvider()
        let mac = TestDevice(role: .localMac), phone = TestDevice(role: .iPhone)
        let macToken = try await authenticate(mac, on: app)
        let phoneToken = try await authenticate(phone, on: app)
        try await app.testing().test(.POST, "/v1/push/tokens", headers: bearer(phoneToken.accessToken)) { request in
            try request.content.encode(PushTokenRequest(id: UUID(), token: "apns-token-secret", environment: "sandbox"))
        } afterResponse: { response in #expect(response.status == .accepted) }
        let envelope = try signedEnvelope(sender: mac, recipient: phone, sequence: 1, kind: .sessionStatus)
        try await app.testing().test(.POST, "/v1/envelopes", headers: bearer(macToken.accessToken)) { request in
            try request.content.encode(envelope)
        } afterResponse: { response in #expect(response.status == .ok) }
        #expect(try await PushTokenModel.query(on: app.db).count() == 0)
    }
}

@Test func keyRotationRetiresOldKeysAndRefreshTokens() async throws {
    try await withApp(configure: configuredApp) { app in
        let mac = TestDevice(role: .localMac)
        let phone = TestDevice(role: .iPhone)
        _ = try await authenticate(mac, on: app)
        let oldTokens = try await authenticate(phone, on: app)
        let rotatedPhone = TestDevice(id: phone.id, role: .iPhone)
        _ = try await authenticate(rotatedPhone, on: app)

        try await app.testing().test(.POST, "/v1/auth/refresh") { request in
            try request.content.encode(RefreshRequest(refreshToken: oldTokens.refreshToken))
        } afterResponse: { response in
            #expect(response.status == .unauthorized)
        }

        let retiredEnvelope = try signedEnvelope(
            sender: phone, recipient: mac, sequence: 1, kind: .companionDecision
        )
        try await app.testing().test(
            .POST, "/v1/envelopes", headers: bearer(oldTokens.accessToken)
        ) { request in
            try request.content.encode(retiredEnvelope)
        } afterResponse: { response in
            #expect(response.status == .unprocessableEntity)
        }

        let currentEnvelope = try signedEnvelope(
            sender: rotatedPhone, recipient: mac, sequence: 1, kind: .companionDecision
        )
        try await app.testing().test(
            .POST, "/v1/envelopes", headers: bearer(oldTokens.accessToken)
        ) { request in
            try request.content.encode(currentEnvelope)
        } afterResponse: { response in
            #expect(response.status == .ok)
        }
    }
}

@Test func APNSOutageKeepsStoreAndForwardAuthoritative() async throws {
    try await withApp(configure: configuredApp) { app in
        app.pushProvider = RetryablePushProvider()
        let mac = TestDevice(role: .localMac), phone = TestDevice(role: .iPhone)
        let macToken = try await authenticate(mac, on: app)
        let phoneToken = try await authenticate(phone, on: app)
        try await app.testing().test(.POST, "/v1/push/tokens", headers: bearer(phoneToken.accessToken)) { request in
            try request.content.encode(PushTokenRequest(
                id: UUID(), token: "temporarily-unreachable-token", environment: "sandbox"
            ))
        } afterResponse: { response in
            #expect(response.status == .accepted)
        }

        let envelope = try signedEnvelope(sender: mac, recipient: phone, sequence: 1, kind: .sessionStatus)
        try await app.testing().test(.POST, "/v1/envelopes", headers: bearer(macToken.accessToken)) { request in
            try request.content.encode(envelope)
        } afterResponse: { response in
            #expect(response.status == .ok)
        }
        let pending = try await app.testing().sendRequest(
            .GET, "/v1/envelopes/pending?after=0", headers: bearer(phoneToken.accessToken)
        )
        #expect(pending.status == .ok)
        #expect(try pending.content.decode(PendingEnvelopeResponse.self).envelopes == [envelope])
        #expect(try await PushTokenModel.query(on: app.db).count() == 1)
    }
}

@Test func liveActivityTokenAndUpdateAreScopedAndForwarded() async throws {
    try await withApp(configure: configuredApp) { app in
        let provider = RecordingLiveActivityPushProvider()
        app.liveActivityPushProvider = provider
        let mac = TestDevice(role: .localMac)
        let phone = TestDevice(role: .iPhone)
        let watch = TestDevice(role: .watch)
        let macToken = try await authenticate(mac, on: app)
        let phoneToken = try await authenticate(phone, on: app)
        let watchToken = try await authenticate(watch, on: app)
        let sessionID = UUID()
        let tokenID = UUID()
        let activityToken = "live-activity-token-secret"

        try await app.testing().test(
            .POST, "/v1/live-activities/tokens", headers: bearer(watchToken.accessToken)
        ) { request in
            try request.content.encode(LiveActivityTokenRequest(
                id: tokenID, sessionID: sessionID, token: activityToken,
                environment: "sandbox", expiresAt: Date().addingTimeInterval(600)
            ))
        } afterResponse: { response in
            #expect(response.status == .forbidden)
        }

        try await app.testing().test(
            .POST, "/v1/live-activities/tokens", headers: bearer(phoneToken.accessToken)
        ) { request in
            try request.content.encode(LiveActivityTokenRequest(
                id: tokenID, sessionID: sessionID, token: activityToken,
                environment: "sandbox", expiresAt: Date().addingTimeInterval(600)
            ))
        } afterResponse: { response in
            #expect(response.status == .accepted)
        }
        let stored = try #require(try await LiveActivityTokenModel.find(tokenID, on: app.db))
        #expect(stored.tokenCiphertext.range(of: Data(activityToken.utf8)) == nil)

        let now = Date()
        try await app.testing().test(
            .POST, "/v1/live-activities/update", headers: bearer(macToken.accessToken)
        ) { request in
            try request.content.encode(LiveActivityUpdateRequest(
                recipientDeviceID: phone.id, sessionID: sessionID,
                state: "waitingApproval", updatedAt: now,
                staleAt: now.addingTimeInterval(300)
            ))
        } afterResponse: { response in
            #expect(response.status == .accepted)
        }
        #expect(await provider.count() == 1)
    }
}

@Test func liveActivityAPNSPayloadIsSmallAndContainsNoAgentContent() throws {
    let now = Date(timeIntervalSince1970: 2_100_000_000)
    let update = LiveActivityUpdateRequest(
        recipientDeviceID: UUID(), sessionID: UUID(), state: "completed",
        updatedAt: now, staleAt: now.addingTimeInterval(300)
    )
    let data = try JSONEncoder().encode(LiveActivityAPNSPayload(update: update))
    #expect(data.count < 4096)
    #expect(data.range(of: Data("prompt".utf8)) == nil)
    #expect(data.range(of: Data("command".utf8)) == nil)
    #expect(data.range(of: Data("project".utf8)) == nil)
}

@Test func accountDeletionCascadesRelayDataAndInvalidatesTokens() async throws {
    try await withApp(configure: configuredApp) { app in
        let mac = TestDevice(role: .localMac)
        let phone = TestDevice(role: .iPhone)
        let macToken = try await authenticate(mac, on: app)
        let phoneToken = try await authenticate(phone, on: app)

        try await app.testing().test(
            .DELETE, "/v1/account", headers: bearer(phoneToken.accessToken)
        ) { response in
            #expect(response.status == .noContent)
        }
        #expect(try await UserModel.query(on: app.db).count() == 0)
        #expect(try await DeviceModel.query(on: app.db).count() == 0)
        #expect(try await RefreshTokenModel.query(on: app.db).count() == 0)

        try await app.testing().test(
            .GET, "/v1/devices", headers: bearer(macToken.accessToken)
        ) { response in
            #expect(response.status == .unauthorized)
        }
    }
}
