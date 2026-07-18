import AgentDomain
import Foundation

public enum CompanionDeviceRole: String, Codable, Sendable, CaseIterable {
    case localMac
    case iPhone
    case watch

    public var canExecuteAgents: Bool {
        self == .localMac
    }
}

public enum RelayEnvelopeKind: String, Codable, Sendable, CaseIterable {
    case approvalRequest = "approval.request"
    case questionRequest = "question.request"
    case sessionStatus = "session.status"
    case companionDecision = "companion.decision"
    case providerAcknowledgment = "provider.acknowledgment"
    case pairingConfirmation = "pairing.confirmation"
    case keyRotation = "key.rotation"
}

public enum RelayDeliveryState: String, Codable, Sendable {
    case queued
    case sent
    case serverAccepted
    case recipientDelivered
    case recipientAcked
    case expired
}

public struct SealedRelayEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let envelopeVersion: Int
    public let envelopeID: UUID
    public let senderDeviceID: DeviceID
    public let recipientDeviceID: DeviceID
    public let kind: RelayEnvelopeKind
    public let createdAt: Date
    public let expiresAt: Date
    public let sequence: UInt64
    public let keyID: UUID
    public let ciphertext: Data
    public let signature: Data

    public init(
        envelopeVersion: Int = Self.currentVersion,
        envelopeID: UUID = UUID(),
        senderDeviceID: DeviceID,
        recipientDeviceID: DeviceID,
        kind: RelayEnvelopeKind,
        createdAt: Date,
        expiresAt: Date,
        sequence: UInt64,
        keyID: UUID,
        ciphertext: Data,
        signature: Data
    ) {
        self.envelopeVersion = envelopeVersion
        self.envelopeID = envelopeID
        self.senderDeviceID = senderDeviceID
        self.recipientDeviceID = recipientDeviceID
        self.kind = kind
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.sequence = sequence
        self.keyID = keyID
        self.ciphertext = ciphertext
        self.signature = signature
    }

    public var signingBytes: Data {
        let fields = [
            String(envelopeVersion),
            envelopeID.uuidString.lowercased(),
            senderDeviceID.rawValue.uuidString.lowercased(),
            recipientDeviceID.rawValue.uuidString.lowercased(),
            kind.rawValue,
            String(Int64(createdAt.timeIntervalSince1970.rounded(.down))),
            String(Int64(expiresAt.timeIntervalSince1970.rounded(.down))),
            String(sequence),
            keyID.uuidString.lowercased(),
            ciphertext.base64EncodedString()
        ]
        return Data(fields.joined(separator: "\u{1f}").utf8)
    }

    public func replacingSignature(_ signature: Data) -> Self {
        .init(
            envelopeVersion: envelopeVersion,
            envelopeID: envelopeID,
            senderDeviceID: senderDeviceID,
            recipientDeviceID: recipientDeviceID,
            kind: kind,
            createdAt: createdAt,
            expiresAt: expiresAt,
            sequence: sequence,
            keyID: keyID,
            ciphertext: ciphertext,
            signature: signature
        )
    }
}

public struct RelayCursor: Codable, Equatable, Sendable {
    public let afterSequence: UInt64
    public init(afterSequence: UInt64) {
        self.afterSequence = afterSequence
    }
}

public struct PairingQRCodePayload: Codable, Equatable, Sendable {
    public let version: Int
    public let relayOrigin: URL
    public let sessionID: UUID
    public let macDeviceID: DeviceID
    public let macEphemeralPublicKey: Data
    public let expiresAt: Date
    public let checksum: Data

    public init(
        version: Int = 1,
        relayOrigin: URL,
        sessionID: UUID,
        macDeviceID: DeviceID,
        macEphemeralPublicKey: Data,
        expiresAt: Date,
        checksum: Data
    ) {
        self.version = version
        self.relayOrigin = relayOrigin
        self.sessionID = sessionID
        self.macDeviceID = macDeviceID
        self.macEphemeralPublicKey = macEphemeralPublicKey
        self.expiresAt = expiresAt
        self.checksum = checksum
    }
}

public enum CompanionRequestedOutcome: String, Codable, Sendable {
    case approve
    case deny
    case answer
}

public struct CompanionDecisionPayload: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let requestVersion: Int
    public let requestedOutcome: CompanionRequestedOutcome
    public let answer: String?
    public let nonce: UUID
    public let decidedAt: Date
    public let strongAuthentication: Bool

    public init(
        requestID: UUID,
        requestVersion: Int,
        requestedOutcome: CompanionRequestedOutcome,
        answer: String? = nil,
        nonce: UUID = UUID(),
        decidedAt: Date,
        strongAuthentication: Bool = false
    ) {
        self.requestID = requestID
        self.requestVersion = requestVersion
        self.requestedOutcome = requestedOutcome
        self.answer = answer
        self.nonce = nonce
        self.decidedAt = decidedAt
        self.strongAuthentication = strongAuthentication
    }
}

public struct ProviderAcknowledgmentPayload: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let applied: Bool
    public let providerReference: String?
    public let acknowledgedAt: Date

    public init(requestID: UUID, applied: Bool, providerReference: String?, acknowledgedAt: Date) {
        self.requestID = requestID
        self.applied = applied
        self.providerReference = providerReference
        self.acknowledgedAt = acknowledgedAt
    }
}
