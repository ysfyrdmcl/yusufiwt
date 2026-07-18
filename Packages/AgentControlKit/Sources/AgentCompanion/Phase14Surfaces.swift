import AgentDomain
import Foundation

#if canImport(ActivityKit) && os(iOS)
    import ActivityKit
#endif

public enum CompanionSurfaceLimits {
    public static let maximumPayloadBytes = 4096
    public static let maximumVisibleSessions = 5
    public static let maximumVisibleRequests = 5
    public static let staleInterval: TimeInterval = 15 * 60
}

public struct CompanionWidgetSnapshot: Codable, Equatable, Sendable {
    public let activeAgentCount: Int
    public let pendingApprovalCount: Int
    public let lastCompletedTask: String?
    public let generatedAt: Date

    public init(
        activeAgentCount: Int,
        pendingApprovalCount: Int,
        lastCompletedTask: String?,
        generatedAt: Date
    ) {
        self.activeAgentCount = max(0, activeAgentCount)
        self.pendingApprovalCount = max(0, pendingApprovalCount)
        self.lastCompletedTask = lastCompletedTask.map { Self.short($0, limit: 80) }
        self.generatedAt = generatedAt
    }

    private static func short(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

public struct WatchSessionCard: Codable, Equatable, Identifiable, Sendable {
    public let id: SessionID
    public let agentName: String
    public let projectName: String
    public let state: SessionState
    public let updatedAt: Date

    public init(session: CompanionSessionSummary) {
        id = session.id
        agentName = Self.short(session.agentName, limit: 24)
        projectName = Self.short(session.projectName, limit: 40)
        state = session.state
        updatedAt = session.updatedAt
    }

    private static func short(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

public struct WatchRequestCard: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let requestVersion: Int
    public let agentName: String
    public let projectName: String
    public let title: String
    public let risk: RiskLevel
    public let expiresAt: Date

    public init(item: CompanionInboxItem) {
        id = item.id
        requestVersion = item.requestVersion
        agentName = Self.short(item.agentName, limit: 24)
        projectName = Self.short(item.projectName, limit: 40)
        title = Self.short(item.title, limit: 64)
        risk = item.risk
        expiresAt = item.expiresAt
    }

    private static func short(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

public struct WatchCompanionSnapshot: Codable, Equatable, Sendable {
    public let sessions: [WatchSessionCard]
    public let requests: [WatchRequestCard]
    public let generatedAt: Date

    public init(
        sessions: [CompanionSessionSummary],
        requests: [CompanionInboxItem],
        generatedAt: Date
    ) {
        self.sessions = Array(
            sessions.sorted { $0.updatedAt > $1.updatedAt }
                .prefix(CompanionSurfaceLimits.maximumVisibleSessions)
                .map(WatchSessionCard.init)
        )
        self.requests = Array(
            requests.filter { $0.expiresAt > generatedAt }
                .sorted(by: Self.requestPrecedes)
                .prefix(CompanionSurfaceLimits.maximumVisibleRequests)
                .map(WatchRequestCard.init)
        )
        self.generatedAt = generatedAt
    }

    public var highestPriorityRequest: WatchRequestCard? {
        requests.first
    }

    private static func requestPrecedes(_ lhs: CompanionInboxItem, _ rhs: CompanionInboxItem) -> Bool {
        if lhs.risk != rhs.risk {
            return lhs.risk.priority > rhs.risk.priority
        }
        return lhs.createdAt < rhs.createdAt
    }
}

private extension RiskLevel {
    var priority: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .critical: 3
        }
    }
}

public struct CompanionSurfaceSnapshot: Codable, Equatable, Sendable {
    public static let storageKey = "companion-surface-snapshot-v1"

    public let widget: CompanionWidgetSnapshot
    public let watch: WatchCompanionSnapshot

    public init(
        sessions: [CompanionSessionSummary],
        inbox: [CompanionInboxItem],
        generatedAt: Date
    ) {
        let active = sessions.filter { !$0.state.isTerminal }
        let pending = inbox.filter { $0.expiresAt > generatedAt }
        let completed = sessions
            .filter { $0.state == .completed }
            .max { $0.updatedAt < $1.updatedAt }
        widget = CompanionWidgetSnapshot(
            activeAgentCount: active.count,
            pendingApprovalCount: pending.filter { $0.kind == .approval }.count,
            lastCompletedTask: completed.map { $0.summary.isEmpty ? $0.projectName : $0.summary },
            generatedAt: generatedAt
        )
        watch = WatchCompanionSnapshot(sessions: sessions, requests: pending, generatedAt: generatedAt)
    }

    public func encoded() throws -> Data {
        let data = try CompanionCoding.makeEncoder().encode(self)
        guard data.count <= CompanionSurfaceLimits.maximumPayloadBytes else {
            throw CompanionSurfaceError.payloadTooLarge(data.count)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= CompanionSurfaceLimits.maximumPayloadBytes else {
            throw CompanionSurfaceError.payloadTooLarge(data.count)
        }
        return try CompanionCoding.makeDecoder().decode(Self.self, from: data)
    }
}

public enum CompanionSurfaceError: Error, Equatable, Sendable {
    case payloadTooLarge(Int)
    case invalidWatchMessage
}

public enum WatchDecisionDisposition: Equatable, Sendable {
    case allowed
    case openIPhone
    case expired
}

public enum WatchDecisionPolicy {
    public static func disposition(
        outcome: CompanionRequestedOutcome,
        card: WatchRequestCard,
        now: Date
    ) -> WatchDecisionDisposition {
        guard card.expiresAt > now else { return .expired }
        if outcome == .deny {
            return .allowed
        }
        guard outcome == .approve, card.risk == .low else {
            return .openIPhone
        }
        return .allowed
    }
}

public struct WatchDecisionMessage: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let requestVersion: Int
    public let outcome: CompanionRequestedOutcome
    public let createdAt: Date

    public init(
        requestID: UUID,
        requestVersion: Int,
        outcome: CompanionRequestedOutcome,
        createdAt: Date
    ) {
        self.requestID = requestID
        self.requestVersion = requestVersion
        self.outcome = outcome
        self.createdAt = createdAt
    }
}

public enum WatchMessageCodec {
    public static let snapshotKey = "snapshot"
    public static let decisionKey = "decision"

    public static func encodeDecision(_ value: WatchDecisionMessage) throws -> [String: Any] {
        let data = try CompanionCoding.makeEncoder().encode(value)
        guard data.count <= CompanionSurfaceLimits.maximumPayloadBytes else {
            throw CompanionSurfaceError.payloadTooLarge(data.count)
        }
        return [decisionKey: data]
    }

    public static func decodeDecision(_ message: [String: Any]) throws -> WatchDecisionMessage {
        guard let data = message[decisionKey] as? Data,
              data.count <= CompanionSurfaceLimits.maximumPayloadBytes
        else { throw CompanionSurfaceError.invalidWatchMessage }
        return try CompanionCoding.makeDecoder().decode(WatchDecisionMessage.self, from: data)
    }
}

public struct AgentActivityContentState: Codable, Equatable, Hashable, Sendable {
    public let state: SessionState
    public let updatedAtEpochSeconds: Int
    public let staleAtEpochSeconds: Int

    public init(state: SessionState, updatedAt: Date, staleAt: Date? = nil) {
        self.state = state
        updatedAtEpochSeconds = Int(updatedAt.timeIntervalSince1970)
        staleAtEpochSeconds = Int(
            (staleAt ?? updatedAt.addingTimeInterval(CompanionSurfaceLimits.staleInterval)).timeIntervalSince1970
        )
    }

    public var updatedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(updatedAtEpochSeconds))
    }

    public var staleAt: Date {
        Date(timeIntervalSince1970: TimeInterval(staleAtEpochSeconds))
    }

    public var isFinal: Bool {
        state == .completed || state == .failed || state == .cancelled
    }
}

#if canImport(ActivityKit) && os(iOS)
    public struct AgentActivityAttributes: ActivityAttributes, Sendable {
        public typealias ContentState = AgentActivityContentState

        public let sessionID: UUID
        public let agentName: String
        public let projectName: String
        public let startedAt: Date

        public init(session: CompanionSessionSummary) {
            sessionID = session.id.rawValue
            agentName = String(session.agentName.prefix(24))
            projectName = String(session.projectName.prefix(40))
            startedAt = session.startedAt
        }
    }
#endif
