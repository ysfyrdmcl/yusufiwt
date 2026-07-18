import AgentDomain
import Foundation

public actor ReplayProtector {
    private var highestSequence: [DeviceID: UInt64] = [:]
    private var nonces: [UUID: Date] = [:]

    public init() {}

    public func accept(sender: DeviceID, sequence: UInt64, nonce: UUID? = nil, expiresAt: Date, now: Date) throws {
        purgeExpired(now: now)
        if let current = highestSequence[sender], sequence <= current {
            throw CompanionCryptoError.replayedSequence
        }
        if let nonce, nonces[nonce] != nil {
            throw CompanionCryptoError.replayedNonce
        }
        highestSequence[sender] = sequence
        if let nonce {
            nonces[nonce] = expiresAt
        }
    }

    private func purgeExpired(now: Date) {
        nonces = nonces.filter { $0.value > now }
    }
}

public struct CompanionDecisionPolicy: Sendable {
    public init() {}

    public func validate(
        outcome: CompanionRequestedOutcome,
        risk: RiskLevel,
        senderRole: CompanionDeviceRole,
        strongAuthentication: Bool = false
    ) throws {
        guard senderRole != .localMac else { return }
        if outcome == .approve, risk == .critical {
            throw CompanionCryptoError.policyRejected
        }
        if outcome == .approve, senderRole == .watch, risk != .low {
            throw CompanionCryptoError.policyRejected
        }
        if outcome == .approve, senderRole == .iPhone, risk == .high, !strongAuthentication {
            throw CompanionCryptoError.policyRejected
        }
    }
}
