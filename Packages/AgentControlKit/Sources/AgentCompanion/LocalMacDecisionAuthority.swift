import AgentDomain
import Foundation

public struct CompanionDecisionContext: Sendable {
    public let requestID: UUID
    public let requestVersion: Int
    public let risk: RiskLevel
    public let expiresAt: Date

    public init(requestID: UUID, requestVersion: Int, risk: RiskLevel, expiresAt: Date) {
        self.requestID = requestID
        self.requestVersion = requestVersion
        self.risk = risk
        self.expiresAt = expiresAt
    }
}

public protocol ProviderDecisionApplying: Sendable {
    func apply(_ decision: CompanionDecisionPayload, context: CompanionDecisionContext) async throws -> ProviderAcknowledgmentPayload
}

public actor LocalMacDecisionAuthority {
    private let macIdentity: CompanionIdentity
    private let replayProtector: ReplayProtector
    private let policy: CompanionDecisionPolicy

    public init(
        macIdentity: CompanionIdentity,
        replayProtector: ReplayProtector = ReplayProtector(),
        policy: CompanionDecisionPolicy = .init()
    ) throws {
        guard macIdentity.role == .localMac else { throw CompanionCryptoError.policyRejected }
        self.macIdentity = macIdentity
        self.replayProtector = replayProtector
        self.policy = policy
    }

    // Authority inputs remain explicit so no provider-affecting value is hidden in relay state.
    // swiftlint:disable:next function_parameter_count
    public func validateAndApply(
        _ envelope: SealedRelayEnvelope,
        senderRole: CompanionDeviceRole,
        senderSigningPublicKey: Data,
        senderAgreementPublicKey: Data,
        context: CompanionDecisionContext,
        provider: any ProviderDecisionApplying,
        now: Date
    ) async throws -> ProviderAcknowledgmentPayload {
        guard envelope.kind == .companionDecision, context.expiresAt > now else {
            throw CompanionCryptoError.expired
        }
        let decision: CompanionDecisionPayload = try macIdentity.open(
            envelope,
            senderSigningPublicKey: senderSigningPublicKey,
            senderAgreementPublicKey: senderAgreementPublicKey,
            now: now
        )
        guard decision.requestID == context.requestID, decision.requestVersion == context.requestVersion else {
            throw CompanionCryptoError.policyRejected
        }
        try await replayProtector.accept(
            sender: envelope.senderDeviceID, sequence: envelope.sequence, nonce: decision.nonce,
            expiresAt: envelope.expiresAt, now: now
        )
        try policy.validate(
            outcome: decision.requestedOutcome, risk: context.risk, senderRole: senderRole,
            strongAuthentication: decision.strongAuthentication
        )
        // Only this local-Mac boundary calls the provider. The returned acknowledgment is
        // authoritative; receipt by the relay or this method is never treated as "applied".
        return try await provider.apply(decision, context: context)
    }
}
