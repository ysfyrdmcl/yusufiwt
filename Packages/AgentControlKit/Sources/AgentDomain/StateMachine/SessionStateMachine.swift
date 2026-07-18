public enum SessionState: String, Codable, Sendable, CaseIterable, Hashable {
    case discovered
    case starting
    case thinking
    case running
    case executing
    case waitingApproval
    case waitingInput
    case paused
    case completed
    case failed
    case cancelled
    case disconnected
    case stale

    public static let terminalStates: [SessionState] = [.completed, .failed, .cancelled]
    public var isTerminal: Bool {
        Self.terminalStates.contains(self)
    }

    public var attentionPriority: Int {
        switch self {
        case .waitingApproval: 12
        case .waitingInput: 11
        case .failed: 10
        case .completed: 9
        case .executing: 8
        case .running: 7
        case .thinking: 6
        case .starting: 5
        case .paused: 4
        case .discovered: 3
        case .disconnected: 2
        case .stale: 1
        case .cancelled: 0
        }
    }
}

public enum SessionStateMachine {
    public static let allowedTransitions: [SessionState: Set<SessionState>] = [
        .discovered: [.starting, .thinking, .running, .waitingApproval, .waitingInput, .failed, .cancelled, .disconnected, .stale],
        .starting: [.thinking, .running, .executing, .waitingApproval, .waitingInput, .paused, .completed, .failed, .cancelled, .disconnected, .stale],
        .thinking: [.running, .executing, .waitingApproval, .waitingInput, .paused, .completed, .failed, .cancelled, .disconnected, .stale],
        .running: [.thinking, .executing, .waitingApproval, .waitingInput, .paused, .completed, .failed, .cancelled, .disconnected, .stale],
        .executing: [.thinking, .running, .waitingApproval, .waitingInput, .paused, .completed, .failed, .cancelled, .disconnected, .stale],
        .waitingApproval: [.thinking, .running, .executing, .waitingInput, .paused, .completed, .failed, .cancelled, .disconnected, .stale],
        .waitingInput: [.thinking, .running, .executing, .waitingApproval, .paused, .completed, .failed, .cancelled, .disconnected, .stale],
        .paused: [.thinking, .running, .executing, .waitingApproval, .waitingInput, .completed, .failed, .cancelled, .disconnected, .stale],
        .completed: [],
        .failed: [],
        .cancelled: [],
        .disconnected: [.starting, .thinking, .running, .executing, .waitingApproval, .waitingInput, .failed, .cancelled, .stale],
        .stale: [.starting, .thinking, .running, .executing, .waitingApproval, .waitingInput, .failed, .cancelled, .disconnected]
    ]

    public static func canTransition(from: SessionState, to target: SessionState, explicitResume: Bool = false) -> Bool {
        if from == target {
            return true
        }
        if from.isTerminal {
            return explicitResume && target == .running
        }
        return allowedTransitions[from, default: []].contains(target)
    }
}
