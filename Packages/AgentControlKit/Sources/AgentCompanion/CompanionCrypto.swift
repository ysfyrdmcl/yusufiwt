import AgentDomain
import CryptoKit
import Foundation

public enum CompanionCryptoError: Error, Equatable, Sendable {
    case invalidEnvelopeVersion
    case expired
    case wrongRecipient
    case invalidSignature
    case invalidCiphertext
    case replayedSequence
    case replayedNonce
    case policyRejected
    case invalidPairingPayload
}

public struct CompanionIdentity: Sendable {
    public let deviceID: DeviceID
    public let role: CompanionDeviceRole
    public let keyID: UUID
    private let agreementKey: Curve25519.KeyAgreement.PrivateKey
    private let signingKey: Curve25519.Signing.PrivateKey

    public init(
        deviceID: DeviceID = DeviceID(UUID()),
        role: CompanionDeviceRole,
        keyID: UUID = UUID()
    ) {
        self.deviceID = deviceID
        self.role = role
        self.keyID = keyID
        agreementKey = .init()
        signingKey = .init()
    }

    public init(
        deviceID: DeviceID,
        role: CompanionDeviceRole,
        keyID: UUID,
        agreementPrivateKey: Data,
        signingPrivateKey: Data
    ) throws {
        self.deviceID = deviceID
        self.role = role
        self.keyID = keyID
        agreementKey = try .init(rawRepresentation: agreementPrivateKey)
        signingKey = try .init(rawRepresentation: signingPrivateKey)
    }

    public var agreementPublicKey: Data {
        agreementKey.publicKey.rawRepresentation
    }

    public var signingPublicKey: Data {
        signingKey.publicKey.rawRepresentation
    }

    public var agreementPrivateKey: Data {
        agreementKey.rawRepresentation
    }

    public var signingPrivateKey: Data {
        signingKey.rawRepresentation
    }

    public func deriveEnvelopeKey(peerPublicKey: Data, salt: Data) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let secret = try agreementKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("agentcontrol/envelope-encryption/v1".utf8),
            outputByteCount: 32
        )
    }

    // Envelope construction intentionally keeps the signed routing fields explicit.
    // swiftlint:disable:next function_parameter_count
    public func seal(
        _ payload: some Encodable,
        kind: RelayEnvelopeKind,
        recipient: DeviceID,
        recipientAgreementPublicKey: Data,
        sequence: UInt64,
        createdAt: Date,
        expiresAt: Date,
        encoder: JSONEncoder = CompanionCoding.makeEncoder()
    ) throws -> SealedRelayEnvelope {
        let envelopeID = UUID()
        let salt = withUnsafeBytes(of: envelopeID.uuid) { Data($0) }
        let key = try deriveEnvelopeKey(peerPublicKey: recipientAgreementPublicKey, salt: salt)
        let plaintext = try encoder.encode(payload)
        let sealed = try ChaChaPoly.seal(plaintext, using: key)
        let canonicalCreatedAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        let canonicalExpiresAt = Date(timeIntervalSince1970: expiresAt.timeIntervalSince1970.rounded(.down))
        var envelope = SealedRelayEnvelope(
            envelopeID: envelopeID,
            senderDeviceID: deviceID,
            recipientDeviceID: recipient,
            kind: kind,
            createdAt: canonicalCreatedAt,
            expiresAt: canonicalExpiresAt,
            sequence: sequence,
            keyID: keyID,
            ciphertext: sealed.combined,
            signature: Data()
        )
        envelope = try envelope.replacingSignature(signingKey.signature(for: envelope.signingBytes))
        return envelope
    }

    public func open<Payload: Decodable>(
        _ envelope: SealedRelayEnvelope,
        senderSigningPublicKey: Data,
        senderAgreementPublicKey: Data,
        now: Date,
        decoder: JSONDecoder = CompanionCoding.makeDecoder()
    ) throws -> Payload {
        guard envelope.envelopeVersion == SealedRelayEnvelope.currentVersion else {
            throw CompanionCryptoError.invalidEnvelopeVersion
        }
        guard envelope.recipientDeviceID == deviceID else { throw CompanionCryptoError.wrongRecipient }
        guard envelope.expiresAt > now else { throw CompanionCryptoError.expired }
        let signingPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: senderSigningPublicKey)
        guard signingPublicKey.isValidSignature(envelope.signature, for: envelope.signingBytes) else {
            throw CompanionCryptoError.invalidSignature
        }
        let salt = withUnsafeBytes(of: envelope.envelopeID.uuid) { Data($0) }
        let key = try deriveEnvelopeKey(peerPublicKey: senderAgreementPublicKey, salt: salt)
        do {
            let box = try ChaChaPoly.SealedBox(combined: envelope.ciphertext)
            return try decoder.decode(Payload.self, from: ChaChaPoly.open(box, using: key))
        } catch {
            throw CompanionCryptoError.invalidCiphertext
        }
    }
}

public enum CompanionCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct PairingKeyMaterial: Sendable {
    private let ephemeralKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        ephemeralKey = .init()
    }

    public init(privateKey: Data) throws {
        ephemeralKey = try .init(rawRepresentation: privateKey)
    }

    public var publicKey: Data {
        ephemeralKey.publicKey.rawRepresentation
    }

    public var privateKey: Data {
        ephemeralKey.rawRepresentation
    }

    public func derive(peerPublicKey: Data, sessionID: UUID) throws -> PairingDerivedKeys {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let secret = try ephemeralKey.sharedSecretFromKeyAgreement(with: peer)
        let salt = withUnsafeBytes(of: sessionID.uuid) { Data($0) }
        func derive(_ label: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data("agentcontrol/\(label)/v1".utf8),
                outputByteCount: 32
            )
        }
        return PairingDerivedKeys(
            confirmation: derive("pairing-confirmation"),
            envelopeEncryption: derive("envelope-encryption"),
            deviceBinding: derive("device-binding")
        )
    }
}

public struct PairingDerivedKeys: Sendable {
    public let confirmation: SymmetricKey
    public let envelopeEncryption: SymmetricKey
    public let deviceBinding: SymmetricKey

    public var fingerprint: String {
        let bytes = confirmation.withUnsafeBytes { Data($0) }
        let digest = SHA256.hash(data: bytes)
        return digest.prefix(4).map { String(format: "%02X", $0) }.joined(separator: "-")
    }
}

public enum PairingQRCode {
    public static func make(
        relayOrigin: URL,
        sessionID: UUID,
        macDeviceID: DeviceID,
        macEphemeralPublicKey: Data,
        expiresAt: Date
    ) -> PairingQRCodePayload {
        let checksum = checksum(
            relayOrigin: relayOrigin,
            sessionID: sessionID,
            macDeviceID: macDeviceID,
            publicKey: macEphemeralPublicKey,
            expiresAt: expiresAt
        )
        return .init(
            relayOrigin: relayOrigin,
            sessionID: sessionID,
            macDeviceID: macDeviceID,
            macEphemeralPublicKey: macEphemeralPublicKey,
            expiresAt: expiresAt,
            checksum: checksum
        )
    }

    public static func validate(_ payload: PairingQRCodePayload, now: Date) throws {
        guard payload.version == 1, payload.expiresAt > now else {
            throw CompanionCryptoError.invalidPairingPayload
        }
        let expected = checksum(
            relayOrigin: payload.relayOrigin,
            sessionID: payload.sessionID,
            macDeviceID: payload.macDeviceID,
            publicKey: payload.macEphemeralPublicKey,
            expiresAt: payload.expiresAt
        )
        guard expected == payload.checksum else { throw CompanionCryptoError.invalidPairingPayload }
    }

    private static func checksum(
        relayOrigin: URL,
        sessionID: UUID,
        macDeviceID: DeviceID,
        publicKey: Data,
        expiresAt: Date
    ) -> Data {
        let value = [
            relayOrigin.absoluteString,
            sessionID.uuidString.lowercased(),
            macDeviceID.rawValue.uuidString.lowercased(),
            publicKey.base64EncodedString(),
            String(Int64(expiresAt.timeIntervalSince1970.rounded(.down)))
        ].joined(separator: "\u{1f}")
        return Data(SHA256.hash(data: Data(value.utf8)))
    }
}

public enum PairingQRCodeCodec {
    public static func encode(_ payload: PairingQRCodePayload) throws -> URL {
        let data = try CompanionCoding.makeEncoder().encode(payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard var components = URLComponents(string: "agentcontrol://pair") else {
            throw CompanionCryptoError.invalidPairingPayload
        }
        components.queryItems = [.init(name: "payload", value: encoded)]
        guard let url = components.url else { throw CompanionCryptoError.invalidPairingPayload }
        return url
    }

    public static func decode(_ value: String, now: Date) throws -> PairingQRCodePayload {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "agentcontrol",
              components.host?.lowercased() == "pair",
              var encoded = components.queryItems?.first(where: { $0.name == "payload" })?.value
        else { throw CompanionCryptoError.invalidPairingPayload }
        encoded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
        guard let data = Data(base64Encoded: encoded) else { throw CompanionCryptoError.invalidPairingPayload }
        let payload = try CompanionCoding.makeDecoder().decode(PairingQRCodePayload.self, from: data)
        try PairingQRCode.validate(payload, now: now)
        return payload
    }
}
