public enum ApprovalStatus: String, Codable, Sendable, CaseIterable {
    case received
    case classified
    case presented
    case userDecisionPending
    case signedDecisionReceived
    case policyValidated
    case sentToProvider
    case providerAcknowledged
    case applied
    case deniedApplied
    case expired
    case superseded
    case providerRejected
    case policyRejected
    case deliveryFailed
    case cancelledByProvider

    public var isFinal: Bool {
        switch self {
        case .applied, .deniedApplied, .expired, .superseded, .providerRejected, .policyRejected, .deliveryFailed, .cancelledByProvider:
            true
        default:
            false
        }
    }
}

public enum ApprovalStateMachine {
    private static let earlyFinals: Set<ApprovalStatus> = [.expired, .superseded, .cancelledByProvider]

    public static let allowedTransitions: [ApprovalStatus: Set<ApprovalStatus>] = [
        .received: Set([.classified]).union(earlyFinals),
        .classified: Set([.presented, .policyRejected]).union(earlyFinals),
        .presented: Set([.userDecisionPending]).union(earlyFinals),
        .userDecisionPending: Set([.signedDecisionReceived]).union(earlyFinals),
        .signedDecisionReceived: Set([.policyValidated, .policyRejected]).union(earlyFinals),
        .policyValidated: Set([.sentToProvider, .deliveryFailed]).union(earlyFinals),
        .sentToProvider: Set([.providerAcknowledged, .providerRejected, .deliveryFailed]).union(earlyFinals),
        .providerAcknowledged: [.applied, .deniedApplied],
        .applied: [],
        .deniedApplied: [],
        .expired: [],
        .superseded: [],
        .providerRejected: [],
        .policyRejected: [],
        .deliveryFailed: [],
        .cancelledByProvider: []
    ]

    public static func canTransition(from: ApprovalStatus, to target: ApprovalStatus) -> Bool {
        from == target || allowedTransitions[from, default: []].contains(target)
    }
}
