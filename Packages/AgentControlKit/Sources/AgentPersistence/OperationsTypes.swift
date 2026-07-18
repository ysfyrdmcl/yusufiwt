import AgentDomain
import Foundation

public struct HistoryQuery: Codable, Sendable, Equatable {
    public var searchText: String
    public var adapterID: AdapterID?
    public var states: Set<SessionState>
    public var startedAfter: Date?
    public var startedBefore: Date?
    public var limit: Int
    public var offset: Int

    public init(
        searchText: String = "",
        adapterID: AdapterID? = nil,
        states: Set<SessionState> = [],
        startedAfter: Date? = nil,
        startedBefore: Date? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) {
        self.searchText = searchText
        self.adapterID = adapterID
        self.states = states
        self.startedAfter = startedAfter
        self.startedBefore = startedBefore
        self.limit = limit
        self.offset = offset
    }
}

public struct HistorySession: Codable, Sendable, Identifiable, Equatable {
    public let id: SessionID
    public let projectName: String
    public let adapterID: AdapterID
    public let state: SessionState
    public let startedAt: Date
    public let endedAt: Date?
    public let lastMeaningfulEventAt: Date
    public let eventCount: Int

    public init(
        id: SessionID,
        projectName: String,
        adapterID: AdapterID,
        state: SessionState,
        startedAt: Date,
        endedAt: Date?,
        lastMeaningfulEventAt: Date,
        eventCount: Int
    ) {
        self.id = id
        self.projectName = projectName
        self.adapterID = adapterID
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastMeaningfulEventAt = lastMeaningfulEventAt
        self.eventCount = eventCount
    }
}

public struct HistoryPage: Codable, Sendable, Equatable {
    public let items: [HistorySession]
    public let totalCount: Int

    public init(items: [HistorySession], totalCount: Int) {
        self.items = items
        self.totalCount = totalCount
    }
}

public enum AnalyticsInterval: String, Codable, Sendable, CaseIterable, Equatable {
    case day
    case week
}

public struct AnalyticsQuery: Codable, Sendable, Equatable {
    public var from: Date
    public var endDate: Date
    public var interval: AnalyticsInterval
    public var adapterID: AdapterID?

    public init(from: Date, endDate: Date, interval: AnalyticsInterval = .day, adapterID: AdapterID? = nil) {
        self.from = from
        self.endDate = endDate
        self.interval = interval
        self.adapterID = adapterID
    }
}

public struct AnalyticsBucket: Codable, Sendable, Identifiable, Equatable {
    public var id: Date {
        start
    }

    public let start: Date
    public let sessionCount: Int
    public let completedCount: Int
    public let failedCount: Int
    public let approvalRequestCount: Int

    public init(start: Date, sessionCount: Int, completedCount: Int, failedCount: Int, approvalRequestCount: Int) {
        self.start = start
        self.sessionCount = sessionCount
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.approvalRequestCount = approvalRequestCount
    }
}

public struct AnalyticsSummary: Codable, Sendable, Equatable {
    public let totalSessions: Int
    public let completedSessions: Int
    public let failedSessions: Int
    public let approvalRequests: Int
    public let averageDurationSeconds: TimeInterval
    public let buckets: [AnalyticsBucket]

    public init(
        totalSessions: Int,
        completedSessions: Int,
        failedSessions: Int,
        approvalRequests: Int,
        averageDurationSeconds: TimeInterval,
        buckets: [AnalyticsBucket]
    ) {
        self.totalSessions = totalSessions
        self.completedSessions = completedSessions
        self.failedSessions = failedSessions
        self.approvalRequests = approvalRequests
        self.averageDurationSeconds = averageDurationSeconds
        self.buckets = buckets
    }
}

public enum OperationsRule: Codable, Sendable, Identifiable, Equatable {
    case alert(AlertRule)
    case automation(LowRiskAutomationRule)

    public var id: UUID {
        switch self {
        case let .alert(rule): rule.id
        case let .automation(rule): rule.id
        }
    }
}

public struct PrivacySettings: Codable, Sendable, Equatable {
    public var analyticsEnabled: Bool
    public var retentionDays: Int
    public var includePrivateMetadataInDiagnostics: Bool
    public var storePromptContent: Bool
    public var storeTerminalOutput: Bool

    public init(
        analyticsEnabled: Bool = true,
        retentionDays: Int = 30,
        includePrivateMetadataInDiagnostics: Bool = false,
        storePromptContent: Bool = false,
        storeTerminalOutput: Bool = false
    ) {
        self.analyticsEnabled = analyticsEnabled
        self.retentionDays = min(3650, max(1, retentionDays))
        self.includePrivateMetadataInDiagnostics = includePrivateMetadataInDiagnostics
        self.storePromptContent = storePromptContent
        self.storeTerminalOutput = storeTerminalOutput
    }

    public static let privacyFirst = PrivacySettings()
}

public enum DiagnosticCheckStatus: String, Codable, Sendable, Equatable {
    case healthy
    case warning
    case failed
}

public struct DiagnosticCheck: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let status: DiagnosticCheckStatus
    public let safeSummary: String

    public init(id: String, status: DiagnosticCheckStatus, safeSummary: String) {
        self.id = id
        self.status = status
        self.safeSummary = safeSummary
    }
}

public struct DiagnosticsReport: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let checks: [DiagnosticCheck]
    public let activeSessionCount: Int
    public let persistedEventCount: Int
    public let schemaVersion: Int

    public init(
        generatedAt: Date,
        checks: [DiagnosticCheck],
        activeSessionCount: Int,
        persistedEventCount: Int,
        schemaVersion: Int
    ) {
        self.generatedAt = generatedAt
        self.checks = checks
        self.activeSessionCount = activeSessionCount
        self.persistedEventCount = persistedEventCount
        self.schemaVersion = schemaVersion
    }
}

public enum RepairAction: String, Codable, Sendable, CaseIterable, Equatable {
    case checkpointDatabase
    case applyRetention
    case clearResolvedDiagnostics
}

public struct RepairResult: Codable, Sendable, Equatable {
    public let action: RepairAction
    public let affectedRows: Int
    public let safeMessage: String

    public init(action: RepairAction, affectedRows: Int, safeMessage: String) {
        self.action = action
        self.affectedRows = affectedRows
        self.safeMessage = safeMessage
    }
}

public struct DataDeletionResult: Codable, Sendable, Equatable {
    public let deletedSessions: Int
    public let deletedEvents: Int

    public init(deletedSessions: Int, deletedEvents: Int) {
        self.deletedSessions = deletedSessions
        self.deletedEvents = deletedEvents
    }
}

public struct DiagnosticAttachment: Sendable, Equatable {
    public let name: String
    public let content: String
    public let privacyClass: PrivacyClass

    public init(name: String, content: String, privacyClass: PrivacyClass) {
        self.name = name
        self.content = content
        self.privacyClass = privacyClass
    }
}
