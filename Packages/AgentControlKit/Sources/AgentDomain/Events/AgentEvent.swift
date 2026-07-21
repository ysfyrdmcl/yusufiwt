public enum AgentEvent: Codable, Sendable, Equatable {
    case stateChanged(SessionState)
    case approvalRequested(ApprovalRequest)
    case approvalStatusChanged(id: ApprovalRequestID, status: ApprovalStatus)
    case questionRequested(AgentQuestion)
    case questionResolved(QuestionID)
    case usageUpdated(SessionUsageUpdate)
    case providerResumed
    case unknown(type: String)
}

public struct SequencedAgentEvent: Sendable {
    public let id: EventID
    public let sourceKey: String
    public let sequence: Int64
    public let event: AgentEvent

    public init(id: EventID, sourceKey: String, sequence: Int64, event: AgentEvent) {
        self.id = id
        self.sourceKey = sourceKey
        self.sequence = sequence
        self.event = event
    }
}
