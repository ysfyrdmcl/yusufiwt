import Foundation

public enum EventApplicationResult: Sendable, Equatable {
    case applied
    case duplicate
    case outOfOrder
    case recordedWithoutStateChange
    case rejectedTransition
}

public struct SessionAggregate: Sendable {
    public private(set) var session: AgentSession
    public private(set) var pendingApprovalIDs: Set<ApprovalRequestID>
    public private(set) var pendingQuestionIDs: Set<QuestionID>
    private var processedEventIDs: Set<EventID>
    private var lastSequenceBySource: [String: Int64]

    public init(session: AgentSession, lastSequenceBySource: [String: Int64] = [:]) {
        self.session = session
        pendingApprovalIDs = []
        pendingQuestionIDs = []
        processedEventIDs = []
        self.lastSequenceBySource = lastSequenceBySource
    }

    public mutating func apply(_ sequenced: SequencedAgentEvent) -> EventApplicationResult {
        if let orderingResult = validateOrdering(sequenced) {
            return orderingResult
        }

        processedEventIDs.insert(sequenced.id)
        lastSequenceBySource[sequenced.sourceKey] = sequenced.sequence
        return applyAccepted(sequenced.event)
    }

    /// Updates persistence metadata without bypassing state transition rules.
    public mutating func updateSnapshotMetadata(lastMeaningfulEventAt: Date, endedAt: Date?) {
        session.lastMeaningfulEventAt = lastMeaningfulEventAt
        session.endedAt = endedAt
    }

    private func validateOrdering(_ event: SequencedAgentEvent) -> EventApplicationResult? {
        if processedEventIDs.contains(event.id) {
            return .duplicate
        }
        if let lastSequence = lastSequenceBySource[event.sourceKey], event.sequence <= lastSequence {
            return .outOfOrder
        }
        return nil
    }

    // All AgentEvent variants are deliberately handled exhaustively here.
    // swiftlint:disable:next cyclomatic_complexity
    private mutating func applyAccepted(_ event: AgentEvent) -> EventApplicationResult {
        switch event {
        case let .stateChanged(nextState):
            return applyState(nextState)
        case let .approvalRequested(request):
            pendingApprovalIDs.insert(request.id)
            return applyAttentionState(.waitingApproval)
        case let .approvalStatusChanged(id, status):
            guard pendingApprovalIDs.contains(id) else { return .recordedWithoutStateChange }
            if status.isFinal {
                pendingApprovalIDs.remove(id)
            }
            return restoreAttentionState()
        case let .questionRequested(question):
            pendingQuestionIDs.insert(question.id)
            return pendingApprovalIDs.isEmpty ? applyAttentionState(.waitingInput) : .applied
        case let .questionResolved(id):
            pendingQuestionIDs.remove(id)
            return restoreAttentionState()
        case let .usageUpdated(update):
            return applyUsageUpdate(update)
        case .providerResumed:
            guard session.state.isTerminal else { return .recordedWithoutStateChange }
            session.state = .running
            session.endedAt = nil
            session.snapshotRevision += 1
            return .applied
        case .unknown:
            return .recordedWithoutStateChange
        }
    }

    private mutating func applyUsageUpdate(_ update: SessionUsageUpdate) -> EventApplicationResult {
        var changed = false
        if let nextState = update.concurrentState {
            let hidesPendingAttention = [.thinking, .running, .executing].contains(nextState)
                && (!pendingApprovalIDs.isEmpty || !pendingQuestionIDs.isEmpty)
            if !hidesPendingAttention {
                if SessionStateMachine.canTransition(from: session.state, to: nextState), session.state != nextState {
                    session.state = nextState
                    changed = true
                }
            }
        }

        var merged = session.usageMetrics
        for metric in update.metrics {
            if let index = merged.firstIndex(where: { $0.provider == metric.provider && $0.kind == metric.kind }) {
                guard metric.updatedAt >= merged[index].updatedAt else { continue }
                if merged[index] != metric {
                    merged[index] = metric
                    changed = true
                }
            } else {
                merged.append(metric)
                changed = true
            }
        }
        guard changed else { return .recordedWithoutStateChange }
        session.usageMetrics = merged.sorted {
            ($0.provider.rawValue, $0.kind.rawValue) < ($1.provider.rawValue, $1.kind.rawValue)
        }
        session.snapshotRevision += 1
        return .applied
    }

    private mutating func applyState(_ nextState: SessionState) -> EventApplicationResult {
        if !pendingApprovalIDs.isEmpty, [.thinking, .running, .executing].contains(nextState) {
            return .applied
        }
        guard SessionStateMachine.canTransition(from: session.state, to: nextState) else {
            return session.state.isTerminal ? .recordedWithoutStateChange : .rejectedTransition
        }
        session.state = nextState
        session.snapshotRevision += 1
        return .applied
    }

    private mutating func applyAttentionState(_ state: SessionState) -> EventApplicationResult {
        guard SessionStateMachine.canTransition(from: session.state, to: state) else {
            return session.state.isTerminal ? .recordedWithoutStateChange : .rejectedTransition
        }
        session.state = state
        session.snapshotRevision += 1
        return .applied
    }

    private mutating func restoreAttentionState() -> EventApplicationResult {
        if !pendingApprovalIDs.isEmpty {
            return applyAttentionState(.waitingApproval)
        }
        if !pendingQuestionIDs.isEmpty {
            return applyAttentionState(.waitingInput)
        }
        if session.state == .waitingApproval || session.state == .waitingInput {
            return applyState(.running)
        }
        return .applied
    }
}
