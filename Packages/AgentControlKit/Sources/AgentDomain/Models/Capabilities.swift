public enum AgentCapability: String, Codable, Hashable, Sendable, CaseIterable {
    case monitorSessions
    case approveRequests
    case denyRequests
    case answerQuestions
    case reviewPlans
    case stopSession
    case resumeSession
    case navigateToSession
}

public struct CapabilityMatrix: Codable, Hashable, Sendable {
    public let supported: Set<AgentCapability>

    public init(supported: Set<AgentCapability>) {
        self.supported = supported
    }

    public func supports(_ capability: AgentCapability) -> Bool {
        supported.contains(capability)
    }
}
