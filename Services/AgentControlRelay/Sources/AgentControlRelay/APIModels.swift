import Foundation
import Vapor

public enum ServerDeviceRole: String, Codable, Sendable, CaseIterable {
    case localMac
    case iPhone
    case watch
}

public struct AppleAuthenticationRequest: Content {
    public let identityToken: String
    public let nonce: String?
    public let deviceID: UUID
    public let role: ServerDeviceRole
    public let displayName: String
    public let agreementPublicKey: Data
    public let signingPublicKey: Data
}

public struct RefreshRequest: Content { public let refreshToken: String }

public struct TokenResponse: Content {
    public let accessToken: String
    public let accessTokenExpiresAt: Date
    public let refreshToken: String
}

public struct RegisterMacRequest: Content {
    public let deviceID: UUID
    public let displayName: String
    public let agreementPublicKey: Data
    public let signingPublicKey: Data
}

public struct DeviceResponse: Content, Equatable {
    public let id: UUID
    public let role: ServerDeviceRole
    public let displayName: String
    public let agreementPublicKey: Data
    public let signingPublicKey: Data
    public let revokedAt: Date?
}

public struct CreatePairingRequest: Content {
    public let macEphemeralPublicKey: Data
}

public struct PairingSessionResponse: Content {
    public let id: UUID
    public let macDeviceID: UUID
    public let macEphemeralPublicKey: Data
    public let phoneDeviceID: UUID?
    public let phoneEphemeralPublicKey: Data?
    public let expiresAt: Date
}

public struct CompletePairingRequest: Content {
    public let phoneEphemeralPublicKey: Data
}

public enum ServerEnvelopeKind: String, Codable, Sendable {
    case approvalRequest = "approval.request"
    case questionRequest = "question.request"
    case sessionStatus = "session.status"
    case companionDecision = "companion.decision"
    case providerAcknowledgment = "provider.acknowledgment"
    case pairingConfirmation = "pairing.confirmation"
    case keyRotation = "key.rotation"
}

public struct RelayEnvelopeDTO: Content, Equatable {
    public let envelopeVersion: Int
    public let envelopeID: UUID
    public let senderDeviceID: UUID
    public let recipientDeviceID: UUID
    public let kind: ServerEnvelopeKind
    public let createdAt: Date
    public let expiresAt: Date
    public let sequence: UInt64
    public let keyID: UUID
    public let ciphertext: Data
    public let signature: Data

    public var signingBytes: Data {
        let fields = [
            String(envelopeVersion), envelopeID.uuidString.lowercased(),
            senderDeviceID.uuidString.lowercased(), recipientDeviceID.uuidString.lowercased(),
            kind.rawValue, String(Int64(createdAt.timeIntervalSince1970.rounded(.down))),
            String(Int64(expiresAt.timeIntervalSince1970.rounded(.down))), String(sequence),
            keyID.uuidString.lowercased(), ciphertext.base64EncodedString()
        ]
        return Data(fields.joined(separator: "\u{1f}").utf8)
    }
}

public struct PendingEnvelopeResponse: Content {
    public let envelopes: [RelayEnvelopeDTO]
    public let cursor: UInt64
}

public struct EnvelopeAcceptedResponse: Content {
    public let envelopeID: UUID
    public let state: String
}

public struct PushTokenRequest: Content {
    public let id: UUID
    public let token: String
    public let environment: String
}

public struct HealthResponse: Content {
    public let status: String
    public let database: String
    public let redis: String
}
