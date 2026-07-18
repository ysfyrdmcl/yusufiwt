import Foundation

public enum SessionAlertKind: String, Codable, Sendable, CaseIterable, Hashable {
    case longRunning
    case idle
    case stale
    case waitingApproval
    case waitingInput
}

public struct AlertRule: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public var kind: SessionAlertKind
    public var thresholdSeconds: TimeInterval
    public var adapterID: AdapterID?
    public var projectID: ProjectID?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        kind: SessionAlertKind,
        thresholdSeconds: TimeInterval,
        adapterID: AdapterID? = nil,
        projectID: ProjectID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.kind = kind
        self.thresholdSeconds = max(1, thresholdSeconds)
        self.adapterID = adapterID
        self.projectID = projectID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SessionAlert: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let ruleID: UUID
    public let sessionID: SessionID
    public let kind: SessionAlertKind
    public let observedDurationSeconds: TimeInterval
    public let detectedAt: Date

    public init(
        ruleID: UUID,
        sessionID: SessionID,
        kind: SessionAlertKind,
        observedDurationSeconds: TimeInterval,
        detectedAt: Date
    ) {
        id = "\(ruleID.uuidString.lowercased()):\(sessionID.description):\(kind.rawValue)"
        self.ruleID = ruleID
        self.sessionID = sessionID
        self.kind = kind
        self.observedDurationSeconds = observedDurationSeconds
        self.detectedAt = detectedAt
    }
}

public enum AutomationActionKind: String, Codable, Sendable, CaseIterable, Hashable {
    case readFile
    case readOnlyTool
}

public struct LowRiskAutomationRule: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public var actionKinds: Set<AutomationActionKind>
    public var adapterID: AdapterID?
    public var projectID: ProjectID?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        actionKinds: Set<AutomationActionKind>,
        adapterID: AdapterID? = nil,
        projectID: ProjectID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.actionKinds = actionKinds
        self.adapterID = adapterID
        self.projectID = projectID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum AutomationEvaluation: Sendable, Equatable {
    case allow(ruleID: UUID)
    case requireHuman(reason: String)
}

public enum OperationsRuleEngine {
    public static func alerts(
        for sessions: [AgentSession],
        rules: [AlertRule],
        clock: any AgentClock
    ) -> [SessionAlert] {
        rules.filter(\.isEnabled).flatMap { rule in
            sessions.compactMap { session in
                guard !session.state.isTerminal,
                      rule.adapterID.map({ $0 == session.adapterID }) ?? true,
                      rule.projectID.map({ $0 == session.project.id }) ?? true,
                      let duration = observedDuration(for: session, kind: rule.kind, now: clock.now),
                      duration >= rule.thresholdSeconds
                else { return nil }
                return SessionAlert(
                    ruleID: rule.id,
                    sessionID: session.id,
                    kind: rule.kind,
                    observedDurationSeconds: duration,
                    detectedAt: clock.now
                )
            }
        }.sorted {
            ($0.kind.rawValue, $0.sessionID.description, $0.ruleID.uuidString)
                < ($1.kind.rawValue, $1.sessionID.description, $1.ruleID.uuidString)
        }
    }

    public static func automation(
        for request: ApprovalRequest,
        session: AgentSession,
        rules: [LowRiskAutomationRule]
    ) -> AutomationEvaluation {
        // This guard is intentionally independent from rule content: stored or future
        // rules can never lower a provider request's normalized risk.
        guard request.risk.level == .low else {
            return .requireHuman(reason: "Only low-risk requests can be automated")
        }
        guard let actionKind = narrowActionKind(request.action) else {
            return .requireHuman(reason: "The action is outside the narrow automation allowlist")
        }
        guard let rule = rules.first(where: {
            $0.isEnabled
                && $0.actionKinds.contains(actionKind)
                && ($0.adapterID.map { $0 == session.adapterID } ?? true)
                && ($0.projectID.map { $0 == session.project.id } ?? true)
        }) else {
            return .requireHuman(reason: "No explicit automation rule matches")
        }
        return .allow(ruleID: rule.id)
    }

    private static func observedDuration(
        for session: AgentSession,
        kind: SessionAlertKind,
        now: Date
    ) -> TimeInterval? {
        switch kind {
        case .longRunning:
            return max(0, now.timeIntervalSince(session.startedAt))
        case .idle:
            guard [.thinking, .running, .executing, .paused].contains(session.state) else { return nil }
            return max(0, now.timeIntervalSince(session.lastMeaningfulEventAt))
        case .stale:
            guard session.state == .stale || session.state == .disconnected else { return nil }
            return max(0, now.timeIntervalSince(session.lastMeaningfulEventAt))
        case .waitingApproval:
            guard session.state == .waitingApproval else { return nil }
            return max(0, now.timeIntervalSince(session.lastMeaningfulEventAt))
        case .waitingInput:
            guard session.state == .waitingInput else { return nil }
            return max(0, now.timeIntervalSince(session.lastMeaningfulEventAt))
        }
    }

    private static func narrowActionKind(_ action: AgentAction) -> AutomationActionKind? {
        switch action {
        case let .modifyFiles(summary) where summary.operation == .read && !summary.paths.isEmpty:
            .readFile
        case let .useTool(summary) where summary.isReadOnly:
            .readOnlyTool
        default:
            nil
        }
    }
}
