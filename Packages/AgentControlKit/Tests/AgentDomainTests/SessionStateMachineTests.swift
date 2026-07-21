import AgentDomain
import Foundation
import Testing

@Suite("Session state machine")
struct SessionStateMachineTests {
    @Test("Transition matrix is deterministic", arguments: SessionState.allCases, SessionState.allCases)
    func transitionMatrix(from: SessionState, target: SessionState) {
        let expected = SessionStateMachine.allowedTransitions[from, default: []].contains(target) || from == target
        #expect(SessionStateMachine.canTransition(from: from, to: target) == expected)
    }

    @Test("Terminal state requires explicit provider resume", arguments: SessionState.terminalStates)
    func terminalResume(terminal: SessionState) {
        #expect(!SessionStateMachine.canTransition(from: terminal, to: .running))
        #expect(SessionStateMachine.canTransition(from: terminal, to: .running, explicitResume: true))
    }

    @Test("Duplicate and out-of-order events are idempotent")
    func ordering() {
        var aggregate = SessionAggregate(session: makeSession())
        let eventID = EventID(UUID())
        #expect(aggregate.apply(.init(id: eventID, sourceKey: "codex:s1", sequence: 2, event: .stateChanged(.running))) == .applied)
        #expect(aggregate.apply(.init(id: eventID, sourceKey: "codex:s1", sequence: 2, event: .stateChanged(.failed))) == .duplicate)
        #expect(aggregate.apply(.init(id: EventID(UUID()), sourceKey: "codex:s1", sequence: 1, event: .stateChanged(.failed))) == .outOfOrder)
        #expect(aggregate.session.state == .running)
    }

    @Test("Usage semantics clamp percentages and never infer quota from token counts")
    func usageSemantics() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let overflow = SessionUsageMetric(
            provider: AdapterID("codex"), kind: .quotaRemaining,
            remainingPercent: 173, source: "fixture", updatedAt: now
        )
        let negative = SessionUsageMetric(
            provider: AdapterID("codex"), kind: .quotaRemaining,
            remainingPercent: -20, source: "fixture", updatedAt: now
        )
        let context = SessionUsageMetric(
            provider: AdapterID("claude"), kind: .contextRemaining,
            total: 1000, used: 250, source: "fixture", updatedAt: now
        )
        let exhausted = SessionUsageMetric(
            provider: AdapterID("claude"), kind: .contextRemaining,
            total: 1000, used: 2000, source: "fixture", updatedAt: now
        )
        let zeroTotal = SessionUsageMetric(
            provider: AdapterID("claude"), kind: .contextRemaining,
            total: 0, used: 0, source: "fixture", updatedAt: now
        )
        let counts = SessionUsageMetric(
            provider: AdapterID("gemini"), kind: .tokenCounts,
            total: 480, inputTokens: 400, outputTokens: 80, source: "fixture", updatedAt: now
        )

        #expect(overflow.remainingPercent == 100)
        #expect(negative.remainingPercent == 0)
        #expect(context.remaining == 750)
        #expect(context.remainingPercent == 75)
        #expect(exhausted.remaining == 0)
        #expect(exhausted.remainingPercent == 0)
        #expect(zeroTotal.remainingPercent == nil)
        #expect(counts.remainingPercent == nil)
        #expect(!context.isStale(at: now.addingTimeInterval(300)))
        #expect(context.isStale(at: now.addingTimeInterval(301)))
    }

    @Test("Decoded usage is normalized at the trust boundary")
    func decodedUsageIsNormalized() throws {
        let data = Data(#"""
        {
          "provider":"codex",
          "kind":"quotaRemaining",
          "total":-10,
          "remaining":-1,
          "remainingPercent":173,
          "source":"fixture",
          "updatedAt":0
        }
        """#.utf8)
        let metric = try JSONDecoder().decode(SessionUsageMetric.self, from: data)
        #expect(metric.total == nil)
        #expect(metric.remaining == nil)
        #expect(metric.remainingPercent == 100)
        #expect(metric.precision == .exact)
    }

    @Test("Duplicate and out-of-order usage cannot regress a session snapshot")
    func usageOrdering() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var aggregate = SessionAggregate(session: makeSession(state: .running))
        let current = SessionUsageMetric(
            provider: AdapterID("codex"), kind: .quotaRemaining,
            remainingPercent: 73, source: "fixture", updatedAt: now
        )
        let stale = SessionUsageMetric(
            provider: AdapterID("codex"), kind: .quotaRemaining,
            remainingPercent: 12, source: "fixture", updatedAt: now.addingTimeInterval(-10)
        )
        let eventID = EventID(UUID())
        let accepted = SequencedAgentEvent(
            id: eventID, sourceKey: "codex:s1", sequence: 2,
            event: .usageUpdated(.init(metrics: [current], concurrentState: .running))
        )
        #expect(aggregate.apply(accepted) == .applied)
        #expect(aggregate.apply(accepted) == .duplicate)
        #expect(aggregate.apply(.init(
            id: EventID(UUID()), sourceKey: "codex:s1", sequence: 1,
            event: .usageUpdated(.init(metrics: [stale], concurrentState: .running))
        )) == .outOfOrder)
        #expect(try #require(aggregate.session.usageMetrics.first).remainingPercent == 73)
    }

    @Test("Usage updates do not hide pending approval or question attention")
    func usagePreservesAttention() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let metric = SessionUsageMetric(
            provider: AdapterID("codex"), kind: .tokenCounts,
            inputTokens: 10, outputTokens: 5, source: "fixture", updatedAt: now
        )
        var approvalAggregate = SessionAggregate(session: makeSession(state: .running))
        #expect(approvalAggregate.apply(event(.approvalRequested(makeApproval(providerID: "usage")), sequence: 1)) == .applied)
        #expect(approvalAggregate.apply(event(.usageUpdated(.init(
            metrics: [metric], concurrentState: .running
        )), sequence: 2)) == .applied)
        #expect(approvalAggregate.session.state == .waitingApproval)

        var questionAggregate = SessionAggregate(session: makeSession(state: .running))
        let question = AgentQuestion(
            id: QuestionID(UUID()), sessionID: questionAggregate.session.id,
            kind: .freeText, prompt: "Input"
        )
        #expect(questionAggregate.apply(event(.questionRequested(question), sequence: 1)) == .applied)
        #expect(questionAggregate.apply(event(.usageUpdated(.init(
            metrics: [metric], concurrentState: .running
        )), sequence: 2)) == .applied)
        #expect(questionAggregate.session.state == .waitingInput)
    }

    @Test("Approval attention survives tool progress and supports multiple requests")
    func multipleApprovals() {
        var aggregate = SessionAggregate(session: makeSession())
        let first = makeApproval(providerID: "a")
        let second = makeApproval(providerID: "b")
        #expect(aggregate.apply(event(.approvalRequested(first), sequence: 1)) == .applied)
        #expect(aggregate.apply(event(.approvalRequested(second), sequence: 2)) == .applied)
        #expect(aggregate.apply(event(.stateChanged(.executing), sequence: 3)) == .applied)
        #expect(aggregate.session.state == .waitingApproval)
        #expect(aggregate.pendingApprovalIDs == [first.id, second.id])
    }

    @Test("Late and unknown events do not revive terminal sessions")
    func terminalAndUnknownEvents() {
        var aggregate = SessionAggregate(session: makeSession(state: .completed))
        #expect(aggregate.apply(event(.stateChanged(.running), sequence: 1)) == .recordedWithoutStateChange)
        #expect(aggregate.apply(event(.unknown(type: "future.event"), sequence: 2)) == .recordedWithoutStateChange)
        #expect(aggregate.session.state == .completed)
        #expect(aggregate.apply(event(.providerResumed, sequence: 3)) == .applied)
        #expect(aggregate.session.state == .running)
    }

    @Test("Parent completion does not mutate a child aggregate")
    func parentAndSubagent() {
        let parentID = SessionID(UUID())
        var parent = SessionAggregate(session: makeSession(id: parentID, state: .running))
        var child = SessionAggregate(session: makeSession(parentID: parentID))
        #expect(parent.apply(event(.stateChanged(.completed), sequence: 1)) == .applied)
        #expect(child.session.state == .discovered)
        #expect(child.apply(event(.stateChanged(.running), sequence: 1)) == .applied)
        #expect(child.session.state == .running)
    }

    @Test("Questions and final approval statuses restore attention")
    func attentionRestoration() {
        var aggregate = SessionAggregate(session: makeSession(state: .running))
        let approval = makeApproval(providerID: "a")
        let question = AgentQuestion(id: QuestionID(UUID()), sessionID: aggregate.session.id, kind: .freeText, prompt: "Input")
        #expect(aggregate.apply(event(.approvalRequested(approval), sequence: 1)) == .applied)
        #expect(aggregate.apply(event(.questionRequested(question), sequence: 2)) == .applied)
        #expect(aggregate.session.state == .waitingApproval)
        #expect(aggregate.apply(event(.approvalStatusChanged(id: approval.id, status: .applied), sequence: 3)) == .applied)
        #expect(aggregate.session.state == .waitingInput)
        #expect(aggregate.apply(event(.questionResolved(question.id), sequence: 4)) == .applied)
        #expect(aggregate.session.state == .running)
    }

    @Test("Invalid references and transitions are recorded safely")
    func invalidEvents() {
        var aggregate = SessionAggregate(session: makeSession())
        #expect(aggregate.apply(event(.providerResumed, sequence: 1)) == .recordedWithoutStateChange)
        #expect(aggregate.apply(event(.approvalStatusChanged(id: ApprovalRequestID(UUID()), status: .expired), sequence: 2)) == .recordedWithoutStateChange)
        #expect(aggregate.apply(event(.stateChanged(.paused), sequence: 3)) == .rejectedTransition)

        var terminal = SessionAggregate(session: makeSession(state: .failed))
        let approval = makeApproval(providerID: "late")
        #expect(terminal.apply(event(.approvalRequested(approval), sequence: 1)) == .recordedWithoutStateChange)
    }

    private func event(_ event: AgentEvent, sequence: Int64) -> SequencedAgentEvent {
        .init(id: EventID(UUID()), sourceKey: "codex:s1", sequence: sequence, event: event)
    }

    private func makeSession(
        id: SessionID = SessionID(UUID()),
        parentID: SessionID? = nil,
        state: SessionState = .discovered
    ) -> AgentSession {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return AgentSession(
            id: id,
            nodeID: NodeID(UUID()),
            adapterID: AdapterID("codex"),
            externalSessionID: "s1",
            project: ProjectReference(id: ProjectID(UUID()), name: "Project", rootURL: URL(fileURLWithPath: "/workspace")),
            terminalContext: nil,
            parentSessionID: parentID,
            state: state,
            startedAt: now,
            endedAt: state.isTerminal ? now : nil,
            lastMeaningfulEventAt: now,
            snapshotRevision: 0
        )
    }

    private func makeApproval(providerID: String) -> ApprovalRequest {
        ApprovalRequest(
            id: ApprovalRequestID(UUID()),
            sessionID: SessionID(UUID()),
            providerRequestID: providerID,
            action: .custom(.init(summary: "Review")),
            risk: .init(level: .low, reasons: []),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            revision: 1,
            status: .received
        )
    }
}
