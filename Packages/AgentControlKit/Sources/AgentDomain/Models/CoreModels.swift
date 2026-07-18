import Foundation

public enum PrivacyClass: String, Codable, Sendable, CaseIterable {
    case publicMetadata
    case privateMetadata
    case sensitive
    case secret
}

public struct ProjectReference: Codable, Hashable, Sendable, Identifiable {
    public let id: ProjectID
    public let name: String
    public let rootURL: URL

    public init(id: ProjectID, name: String, rootURL: URL) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
    }
}

public struct Node: Codable, Hashable, Sendable, Identifiable {
    public let id: NodeID
    public var displayName: String
    public var isLocal: Bool

    public init(id: NodeID, displayName: String, isLocal: Bool) {
        self.id = id
        self.displayName = displayName
        self.isLocal = isLocal
    }
}

public struct TerminalContext: Codable, Hashable, Sendable {
    public let applicationBundleID: String
    public let processID: Int32?
    public let windowIdentifier: String?
    public let tabIdentifier: String?
    public let paneIdentifier: String?
    public let workspaceURI: URL?
    public let correlationToken: String
    public let capturedAt: Date

    public init(
        applicationBundleID: String,
        processID: Int32? = nil,
        windowIdentifier: String? = nil,
        tabIdentifier: String? = nil,
        paneIdentifier: String? = nil,
        workspaceURI: URL? = nil,
        correlationToken: String,
        capturedAt: Date
    ) {
        self.applicationBundleID = applicationBundleID
        self.processID = processID
        self.windowIdentifier = windowIdentifier
        self.tabIdentifier = tabIdentifier
        self.paneIdentifier = paneIdentifier
        self.workspaceURI = workspaceURI
        self.correlationToken = correlationToken
        self.capturedAt = capturedAt
    }
}

public struct AgentSession: Codable, Sendable, Identifiable, Equatable {
    public let id: SessionID
    public let nodeID: NodeID
    public let adapterID: AdapterID
    public let externalSessionID: String?
    public let project: ProjectReference
    public let terminalContext: TerminalContext?
    public let parentSessionID: SessionID?
    public var state: SessionState
    public var startedAt: Date
    public var endedAt: Date?
    public var lastMeaningfulEventAt: Date
    public var snapshotRevision: Int64

    public init(
        id: SessionID,
        nodeID: NodeID,
        adapterID: AdapterID,
        externalSessionID: String?,
        project: ProjectReference,
        terminalContext: TerminalContext?,
        parentSessionID: SessionID?,
        state: SessionState,
        startedAt: Date,
        endedAt: Date?,
        lastMeaningfulEventAt: Date,
        snapshotRevision: Int64
    ) {
        self.id = id
        self.nodeID = nodeID
        self.adapterID = adapterID
        self.externalSessionID = externalSessionID
        self.project = project
        self.terminalContext = terminalContext
        self.parentSessionID = parentSessionID
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastMeaningfulEventAt = lastMeaningfulEventAt
        self.snapshotRevision = snapshotRevision
    }
}

public enum TurnStatus: String, Codable, Sendable { case active, completed, failed, cancelled }

public struct AgentTurn: Codable, Sendable, Identifiable {
    public let id: TurnID
    public let sessionID: SessionID
    public var status: TurnStatus
    public let startedAt: Date
    public var endedAt: Date?

    public init(id: TurnID, sessionID: SessionID, status: TurnStatus, startedAt: Date, endedAt: Date? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public enum ToolRunStatus: String, Codable, Sendable { case requested, running, completed, failed, cancelled }

public struct ToolRun: Codable, Sendable, Identifiable {
    public let id: ToolRunID
    public let sessionID: SessionID
    public let toolName: String
    public var status: ToolRunStatus

    public init(id: ToolRunID, sessionID: SessionID, toolName: String, status: ToolRunStatus) {
        self.id = id
        self.sessionID = sessionID
        self.toolName = toolName
        self.status = status
    }
}

public enum QuestionKind: String, Codable, Sendable { case choice, multiChoice, text, secret, confirmation }
public enum QuestionStatus: String, Codable, Sendable { case pending, answered, expired, cancelled }

public struct AgentQuestion: Codable, Sendable, Identifiable, Equatable {
    public let id: QuestionID
    public let sessionID: SessionID
    public let kind: QuestionKind
    public let prompt: String
    public let choices: [String]
    public var status: QuestionStatus

    public init(id: QuestionID, sessionID: SessionID, kind: QuestionKind, prompt: String, choices: [String] = [], status: QuestionStatus = .pending) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.prompt = prompt
        self.choices = choices
        self.status = status
    }
}
