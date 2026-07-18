import AgentDomain
import Testing

@Suite("Approval lifecycle")
struct ApprovalStateMachineTests {
    @Test("Every lifecycle transition pair is guarded", arguments: ApprovalStatus.allCases, ApprovalStatus.allCases)
    func lifecycleMatrix(from: ApprovalStatus, target: ApprovalStatus) {
        let expected = ApprovalStateMachine.allowedTransitions[from, default: []].contains(target) || from == target
        #expect(ApprovalStateMachine.canTransition(from: from, to: target) == expected)
    }

    @Test("Applied outcomes require provider acknowledgment", arguments: [ApprovalStatus.applied, .deniedApplied])
    func acknowledgmentRequired(finalStatus: ApprovalStatus) {
        #expect(!ApprovalStateMachine.canTransition(from: .sentToProvider, to: finalStatus))
        #expect(ApprovalStateMachine.canTransition(from: .providerAcknowledged, to: finalStatus))
    }

    @Test("Only documented outcomes are final")
    func finalStatuses() {
        let expected: Set<ApprovalStatus> = [
            .applied, .deniedApplied, .expired, .superseded, .providerRejected,
            .policyRejected, .deliveryFailed, .cancelledByProvider
        ]
        #expect(Set(ApprovalStatus.allCases.filter(\.isFinal)) == expected)
    }
}
