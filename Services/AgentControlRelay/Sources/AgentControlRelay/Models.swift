import Fluent
import Foundation
import Vapor

final class UserModel: Model, @unchecked Sendable {
    static let schema = "relay_users"
    @ID(key: .id) var id: UUID?
    @Field(key: "apple_subject_hash") var appleSubjectHash: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(id: UUID = UUID(), appleSubjectHash: String) {
        self.id = id; self.appleSubjectHash = appleSubjectHash
    }
}

final class DeviceModel: Model, @unchecked Sendable {
    static let schema = "relay_devices"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "role") var role: String
    @Field(key: "display_name") var displayName: String
    @Field(key: "agreement_public_key") var agreementPublicKey: Data
    @Field(key: "signing_public_key") var signingPublicKey: Data
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(id: UUID, userID: UUID, role: ServerDeviceRole, displayName: String, agreementPublicKey: Data, signingPublicKey: Data) {
        self.id = id; self.userID = userID; self.role = role.rawValue; self.displayName = displayName
        self.agreementPublicKey = agreementPublicKey; self.signingPublicKey = signingPublicKey
    }
}

final class RefreshTokenModel: Model, @unchecked Sendable {
    static let schema = "relay_refresh_tokens"
    @ID(key: .id) var id: UUID?
    @Field(key: "device_id") var deviceID: UUID
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    init() {}
    init(id: UUID = UUID(), deviceID: UUID, tokenHash: String, expiresAt: Date) {
        self.id = id; self.deviceID = deviceID; self.tokenHash = tokenHash; self.expiresAt = expiresAt
    }
}

final class PairingSessionModel: Model, @unchecked Sendable {
    static let schema = "relay_pairing_sessions"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "mac_device_id") var macDeviceID: UUID
    @Field(key: "mac_ephemeral_public_key") var macEphemeralPublicKey: Data
    @OptionalField(key: "phone_device_id") var phoneDeviceID: UUID?
    @OptionalField(key: "phone_ephemeral_public_key") var phoneEphemeralPublicKey: Data?
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "completed_at") var completedAt: Date?
    init() {}
    init(id: UUID = UUID(), userID: UUID, macDeviceID: UUID, macEphemeralPublicKey: Data, expiresAt: Date) {
        self.id = id; self.userID = userID; self.macDeviceID = macDeviceID
        self.macEphemeralPublicKey = macEphemeralPublicKey; self.expiresAt = expiresAt
    }
}

final class EnvelopeModel: Model, @unchecked Sendable {
    static let schema = "relay_envelopes"
    @ID(key: .id) var id: UUID?
    @Field(key: "sender_device_id") var senderDeviceID: UUID
    @Field(key: "recipient_device_id") var recipientDeviceID: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "expires_at") var expiresAt: Date
    @Field(key: "sequence") var sequence: Int64
    @Field(key: "key_id") var keyID: UUID
    @Field(key: "ciphertext") var ciphertext: Data
    @Field(key: "signature") var signature: Data
    @OptionalField(key: "acked_at") var ackedAt: Date?
    init() {}
    init(_ value: RelayEnvelopeDTO) {
        id = value.envelopeID; senderDeviceID = value.senderDeviceID; recipientDeviceID = value.recipientDeviceID
        kind = value.kind.rawValue; createdAt = value.createdAt; expiresAt = value.expiresAt
        sequence = Int64(bitPattern: value.sequence); keyID = value.keyID; ciphertext = value.ciphertext; signature = value.signature
    }

    func response() throws -> RelayEnvelopeDTO {
        guard let envelopeKind = ServerEnvelopeKind(rawValue: kind) else {
            throw Abort(.internalServerError, reason: "Invalid persisted envelope kind")
        }
        return try RelayEnvelopeDTO(
            envelopeVersion: 1, envelopeID: requireID(), senderDeviceID: senderDeviceID,
            recipientDeviceID: recipientDeviceID, kind: envelopeKind,
            createdAt: createdAt, expiresAt: expiresAt, sequence: UInt64(bitPattern: sequence),
            keyID: keyID, ciphertext: ciphertext, signature: signature
        )
    }
}

final class PushTokenModel: Model, @unchecked Sendable {
    static let schema = "relay_push_tokens"
    @ID(key: .id) var id: UUID?
    @Field(key: "device_id") var deviceID: UUID
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "token_ciphertext") var tokenCiphertext: Data
    @Field(key: "environment") var environment: String
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
    init(id: UUID, deviceID: UUID, tokenHash: String, tokenCiphertext: Data, environment: String) {
        self.id = id; self.deviceID = deviceID; self.tokenHash = tokenHash
        self.tokenCiphertext = tokenCiphertext; self.environment = environment
    }
}
