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

public enum QuestionKind: String, Codable, Sendable {
    case singleChoice
    case multiChoice
    case freeText
    case confirmation
    case secret

    @available(*, deprecated, renamed: "singleChoice")
    public static var choice: QuestionKind {
        .singleChoice
    }

    @available(*, deprecated, renamed: "freeText")
    public static var text: QuestionKind {
        .freeText
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "choice", "singleChoice": self = .singleChoice
        case "multiChoice": self = .multiChoice
        case "text", "freeText": self = .freeText
        case "confirmation": self = .confirmation
        case "secret": self = .secret
        default:
            throw try DecodingError.dataCorruptedError(
                in: decoder.singleValueContainer(),
                debugDescription: "Unknown question kind: \(value)"
            )
        }
    }
}

public enum QuestionStatus: String, Codable, Sendable { case pending, answered, expired, cancelled }

public struct QuestionChoice: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        precondition(!id.isEmpty, "Question choice IDs must not be empty")
        self.id = id
        self.label = label
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let label = try? container.decode(String.self) {
            id = "legacy-" + label.utf8.map { String(format: "%02x", $0) }.joined()
            self.label = label
            return
        }
        let value = try container.decode(StructuredChoice.self)
        guard !value.id.isEmpty else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Question choice ID is empty")
        }
        id = value.id
        label = value.label
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(StructuredChoice(id: id, label: label))
    }

    public static func legacy(label: String) -> QuestionChoice {
        QuestionChoice(
            id: "legacy-" + label.utf8.map { String(format: "%02x", $0) }.joined(),
            label: label
        )
    }

    private struct StructuredChoice: Codable {
        let id: String
        let label: String
    }
}

public struct AgentQuestion: Codable, Sendable, Identifiable, Equatable {
    public let id: QuestionID
    public let sessionID: SessionID
    public let kind: QuestionKind
    public let prompt: String
    public let choices: [QuestionChoice]
    public let maximumAnswerLength: Int?
    public var status: QuestionStatus

    public init(
        id: QuestionID,
        sessionID: SessionID,
        kind: QuestionKind,
        prompt: String,
        choices: [QuestionChoice] = [],
        maximumAnswerLength: Int? = nil,
        status: QuestionStatus = .pending
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.prompt = prompt
        self.choices = choices
        self.maximumAnswerLength = maximumAnswerLength
        self.status = status
    }

    public init(
        id: QuestionID,
        sessionID: SessionID,
        kind: QuestionKind,
        prompt: String,
        legacyChoiceLabels: [String],
        maximumAnswerLength: Int? = nil,
        status: QuestionStatus = .pending
    ) {
        self.init(
            id: id,
            sessionID: sessionID,
            kind: kind,
            prompt: prompt,
            choices: legacyChoiceLabels.map(QuestionChoice.legacy(label:)),
            maximumAnswerLength: maximumAnswerLength,
            status: status
        )
    }

    public init(
        id: QuestionID,
        sessionID: SessionID,
        kind: QuestionKind,
        prompt: String,
        choices: [String],
        maximumAnswerLength: Int? = nil,
        status: QuestionStatus = .pending
    ) {
        self.init(
            id: id,
            sessionID: sessionID,
            kind: kind,
            prompt: prompt,
            legacyChoiceLabels: choices,
            maximumAnswerLength: maximumAnswerLength,
            status: status
        )
    }
}
