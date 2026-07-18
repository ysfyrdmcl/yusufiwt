import Foundation

public struct ParsedCommand: Codable, Hashable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL?
    public let environmentVariableNames: Set<String>

    public init(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environmentVariableNames: Set<String> = []
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentVariableNames = environmentVariableNames
    }
}

public enum FileOperation: String, Codable, Hashable, Sendable { case read, write, delete, move }

public struct FileChangeSummary: Codable, Hashable, Sendable {
    public let paths: [URL]
    public let operation: FileOperation
    public init(paths: [URL], operation: FileOperation) {
        self.paths = paths; self.operation = operation
    }
}

public struct NetworkAccessSummary: Codable, Hashable, Sendable {
    public let host: String
    public let port: Int?
    public let usesTLS: Bool
    public init(host: String, port: Int? = nil, usesTLS: Bool) {
        self.host = host; self.port = port; self.usesTLS = usesTLS
    }
}

public struct ToolInvocationSummary: Codable, Hashable, Sendable {
    public let name: String
    public let isReadOnly: Bool
    public init(name: String, isReadOnly: Bool) {
        self.name = name; self.isReadOnly = isReadOnly
    }
}

public struct PlanSummary: Codable, Hashable, Sendable {
    public let title: String
    public init(title: String) {
        self.title = title
    }
}

public struct CustomActionSummary: Codable, Hashable, Sendable {
    public let summary: String
    public init(summary: String) {
        self.summary = summary
    }
}

public enum AgentAction: Codable, Hashable, Sendable {
    case executeCommand(ParsedCommand)
    case modifyFiles(FileChangeSummary)
    case accessNetwork(NetworkAccessSummary)
    case useTool(ToolInvocationSummary)
    case changePlan(PlanSummary)
    case custom(CustomActionSummary)
}

public enum RiskLevel: String, Codable, Comparable, Sendable, CaseIterable {
    case low
    case medium
    case high
    case critical

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .critical: 3
        }
    }
}

public enum RemoteApprovalPolicy: String, Codable, Sendable {
    case allowed
    case reviewRequired
    case strongAuthenticationRequired
    case forbidden
}

public struct RiskAssessment: Codable, Hashable, Sendable {
    public let level: RiskLevel
    public let reasons: [String]

    public init(level: RiskLevel, reasons: [String]) {
        self.level = level
        self.reasons = reasons
    }

    public var remoteApproval: RemoteApprovalPolicy {
        switch level {
        case .low: .allowed
        case .medium: .reviewRequired
        case .high: .strongAuthenticationRequired
        case .critical: .forbidden
        }
    }
}

public enum RiskSignal: String, Codable, Hashable, Sendable {
    case privilegeEscalation
    case recursiveDelete
    case destructiveWildcard
    case diskOperation
    case productionDeployment
    case secretAccess
    case pipeToShell
    case unknownShellComposition
    case networkWithSecret
    case forcePushProtectedBranch
    case destructiveDatabaseMigration
}

public struct RiskInput: Codable, Hashable, Sendable {
    public let action: AgentAction
    public let workspaceRoot: URL
    public let signals: Set<RiskSignal>

    public init(action: AgentAction, workspaceRoot: URL, signals: Set<RiskSignal> = []) {
        self.action = action
        self.workspaceRoot = workspaceRoot
        self.signals = signals
    }
}
