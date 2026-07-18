import AgentCompanion
import AgentDomain
import Foundation
import Testing

@Suite("Phase 15 companion crypto drills")
struct Phase15CryptoHardeningTests {
    @Test("Rotation accepts the current key and rejects the retired key")
    func keyRotationDrill() throws {
        let deviceID = DeviceID(UUID())
        let retiredPhone = CompanionIdentity(deviceID: deviceID, role: .iPhone)
        let currentPhone = CompanionIdentity(deviceID: deviceID, role: .iPhone)
        let mac = CompanionIdentity(role: .localMac)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let payload = CompanionDecisionPayload(
            requestID: UUID(), requestVersion: 1, requestedOutcome: .deny, decidedAt: now
        )

        let retiredEnvelope = try retiredPhone.seal(
            payload, kind: .companionDecision, recipient: mac.deviceID,
            recipientAgreementPublicKey: mac.agreementPublicKey, sequence: 1,
            createdAt: now, expiresAt: now.addingTimeInterval(60)
        )
        #expect(throws: CompanionCryptoError.invalidSignature) {
            let _: CompanionDecisionPayload = try mac.open(
                retiredEnvelope,
                senderSigningPublicKey: currentPhone.signingPublicKey,
                senderAgreementPublicKey: currentPhone.agreementPublicKey,
                now: now
            )
        }

        let currentEnvelope = try currentPhone.seal(
            payload, kind: .companionDecision, recipient: mac.deviceID,
            recipientAgreementPublicKey: mac.agreementPublicKey, sequence: 2,
            createdAt: now, expiresAt: now.addingTimeInterval(60)
        )
        let opened: CompanionDecisionPayload = try mac.open(
            currentEnvelope,
            senderSigningPublicKey: currentPhone.signingPublicKey,
            senderAgreementPublicKey: currentPhone.agreementPublicKey,
            now: now
        )
        #expect(opened == payload)
    }

    @Test("Oversized QR and ciphertext inputs fail before decoding")
    func oversizedInputs() throws {
        let oversizedURL = "agentcontrol://pair?payload=" + String(
            repeating: "A", count: PairingQRCodeCodec.maximumURLBytes + 1
        )
        #expect(throws: CompanionCryptoError.invalidPairingPayload) {
            try PairingQRCodeCodec.decode(oversizedURL, now: .distantPast)
        }

        let phone = CompanionIdentity(role: .iPhone)
        let mac = CompanionIdentity(role: .localMac)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let valid = try phone.seal(
            ["value": "bounded"], kind: .sessionStatus, recipient: mac.deviceID,
            recipientAgreementPublicKey: mac.agreementPublicKey, sequence: 1,
            createdAt: now, expiresAt: now.addingTimeInterval(60)
        )
        let oversized = SealedRelayEnvelope(
            envelopeVersion: valid.envelopeVersion, envelopeID: valid.envelopeID,
            senderDeviceID: valid.senderDeviceID, recipientDeviceID: valid.recipientDeviceID,
            kind: valid.kind, createdAt: valid.createdAt, expiresAt: valid.expiresAt,
            sequence: valid.sequence, keyID: valid.keyID,
            ciphertext: Data(repeating: 0, count: CompanionIdentity.maximumCiphertextBytes + 1),
            signature: valid.signature
        )
        #expect(throws: CompanionCryptoError.invalidCiphertext) {
            let _: [String: String] = try mac.open(
                oversized, senderSigningPublicKey: phone.signingPublicKey,
                senderAgreementPublicKey: phone.agreementPublicKey, now: now
            )
        }
    }
}
