import AgentCompanion
import AgentDomain
import Foundation
import Testing

@Test func encryptedRoundTripAndTamperRejection() throws {
    let mac = CompanionIdentity(role: .localMac)
    let phone = CompanionIdentity(role: .iPhone)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let decision = CompanionDecisionPayload(
        requestID: UUID(),
        requestVersion: 3,
        requestedOutcome: .approve,
        decidedAt: now
    )
    let envelope = try phone.seal(
        decision,
        kind: .companionDecision,
        recipient: mac.deviceID,
        recipientAgreementPublicKey: mac.agreementPublicKey,
        sequence: 1,
        createdAt: now,
        expiresAt: now.addingTimeInterval(60)
    )

    let opened: CompanionDecisionPayload = try mac.open(
        envelope,
        senderSigningPublicKey: phone.signingPublicKey,
        senderAgreementPublicKey: phone.agreementPublicKey,
        now: now
    )
    #expect(opened == decision)

    var ciphertext = envelope.ciphertext
    ciphertext[0] ^= 1
    let tampered = SealedRelayEnvelope(
        envelopeVersion: envelope.envelopeVersion,
        envelopeID: envelope.envelopeID,
        senderDeviceID: envelope.senderDeviceID,
        recipientDeviceID: envelope.recipientDeviceID,
        kind: envelope.kind,
        createdAt: envelope.createdAt,
        expiresAt: envelope.expiresAt,
        sequence: envelope.sequence,
        keyID: envelope.keyID,
        ciphertext: ciphertext,
        signature: envelope.signature
    )
    #expect(throws: CompanionCryptoError.invalidSignature) {
        let _: CompanionDecisionPayload = try mac.open(
            tampered,
            senderSigningPublicKey: phone.signingPublicKey,
            senderAgreementPublicKey: phone.agreementPublicKey,
            now: now
        )
    }
}

@Test func pairingProducesMatchingFingerprintAndRejectsExpiredQR() throws {
    let mac = PairingKeyMaterial()
    let phone = PairingKeyMaterial()
    let sessionID = UUID()
    let macKeys = try mac.derive(peerPublicKey: phone.publicKey, sessionID: sessionID)
    let phoneKeys = try phone.derive(peerPublicKey: mac.publicKey, sessionID: sessionID)
    #expect(macKeys.fingerprint == phoneKeys.fingerprint)

    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let pairingCode = try PairingQRCode.make(
        relayOrigin: #require(URL(string: "https://relay.example.com")),
        sessionID: sessionID,
        macDeviceID: DeviceID(UUID()),
        macEphemeralPublicKey: mac.publicKey,
        expiresAt: now.addingTimeInterval(60)
    )
    try PairingQRCode.validate(pairingCode, now: now)
    #expect(throws: CompanionCryptoError.invalidPairingPayload) {
        try PairingQRCode.validate(pairingCode, now: now.addingTimeInterval(61))
    }
}

@Test func replayAndCompanionPolicyAreFailClosed() async throws {
    let protector = ReplayProtector()
    let sender = DeviceID(UUID())
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    try await protector.accept(sender: sender, sequence: 1, expiresAt: now.addingTimeInterval(60), now: now)
    await #expect(throws: CompanionCryptoError.replayedSequence) {
        try await protector.accept(sender: sender, sequence: 1, expiresAt: now.addingTimeInterval(60), now: now)
    }

    let policy = CompanionDecisionPolicy()
    #expect(throws: CompanionCryptoError.policyRejected) {
        try policy.validate(outcome: .approve, risk: .critical, senderRole: .iPhone)
    }
    #expect(throws: CompanionCryptoError.policyRejected) {
        try policy.validate(outcome: .approve, risk: .medium, senderRole: .watch)
    }
    #expect(throws: CompanionCryptoError.policyRejected) {
        try policy.validate(outcome: .approve, risk: .high, senderRole: .iPhone)
    }
    try policy.validate(outcome: .approve, risk: .high, senderRole: .iPhone, strongAuthentication: true)
    try policy.validate(outcome: .deny, risk: .critical, senderRole: .watch)
}

private actor AcknowledgingProvider: ProviderDecisionApplying {
    private(set) var calls = 0
    func apply(_ decision: CompanionDecisionPayload, context: CompanionDecisionContext) async throws -> ProviderAcknowledgmentPayload {
        calls += 1
        return .init(requestID: decision.requestID, applied: true, providerReference: "fixture-ack", acknowledgedAt: decision.decidedAt)
    }
}

@Test func onlyLocalMacAuthorityReturnsProviderAcknowledgment() async throws {
    let mac = CompanionIdentity(role: .localMac)
    let phone = CompanionIdentity(role: .iPhone)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let requestID = UUID()
    let decision = CompanionDecisionPayload(
        requestID: requestID, requestVersion: 2, requestedOutcome: .approve,
        decidedAt: now, strongAuthentication: true
    )
    let envelope = try phone.seal(
        decision, kind: .companionDecision, recipient: mac.deviceID,
        recipientAgreementPublicKey: mac.agreementPublicKey, sequence: 9,
        createdAt: now, expiresAt: now.addingTimeInterval(60)
    )
    let provider = AcknowledgingProvider()
    let authority = try LocalMacDecisionAuthority(macIdentity: mac)
    let acknowledgment = try await authority.validateAndApply(
        envelope, senderRole: .iPhone, senderSigningPublicKey: phone.signingPublicKey,
        senderAgreementPublicKey: phone.agreementPublicKey,
        context: .init(requestID: requestID, requestVersion: 2, risk: .high, expiresAt: now.addingTimeInterval(60)),
        provider: provider, now: now
    )
    #expect(acknowledgment.applied)
    #expect(await provider.calls == 1)
}
