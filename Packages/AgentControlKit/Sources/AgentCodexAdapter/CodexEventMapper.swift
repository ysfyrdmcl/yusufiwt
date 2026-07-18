import AgentDomain
import AgentProtocol
import Foundation

public struct CodexMappedEvent: Sendable, Equatable {
    public let threadID: String?
    public let turnID: String?
    public let itemID: String?
    public let event: AgentEvent
    public let currentAction: AgentAction?
    public let isAuthoritativeCompletion: Bool

    public init(
        threadID: String?, turnID: String?, itemID: String?, event: AgentEvent,
        currentAction: AgentAction? = nil, isAuthoritativeCompletion: Bool = false
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.event = event
        self.currentAction = currentAction
        self.isAuthoritativeCompletion = isAuthoritativeCompletion
    }
}

public struct CodexEventMapper: Sendable {
    public init() {}

    // The switch intentionally mirrors the stable app-server lifecycle methods.
    // swiftlint:disable:next cyclomatic_complexity
    public func map(_ message: CodexRPCMessage) -> CodexMappedEvent? {
        guard case let .notification(method, params) = message else { return nil }
        let threadID = params?["threadId"]?.stringValue ?? params?["thread"]?["id"]?.stringValue
        let turnID = params?["turnId"]?.stringValue ?? params?["turn"]?["id"]?.stringValue
        let item = params?["item"]
        let itemID = params?["itemId"]?.stringValue ?? item?["id"]?.stringValue

        switch method {
        case "thread/started":
            return CodexMappedEvent(threadID: threadID, turnID: nil, itemID: nil, event: .stateChanged(.running))
        case "thread/status/changed":
            let state: SessionState = switch params?["status"]?["type"]?.stringValue {
            case "active": .running
            case "idle": .paused
            case "systemError": .failed
            default: .disconnected
            }
            return CodexMappedEvent(threadID: threadID, turnID: nil, itemID: nil, event: .stateChanged(state))
        case "turn/started":
            return CodexMappedEvent(threadID: threadID, turnID: turnID, itemID: nil, event: .stateChanged(.thinking))
        case "item/started":
            let action = action(from: item)
            let state: SessionState = action == nil ? .running : .executing
            return CodexMappedEvent(
                threadID: threadID, turnID: turnID, itemID: itemID,
                event: .stateChanged(state), currentAction: action
            )
        case "item/completed":
            return CodexMappedEvent(
                threadID: threadID, turnID: turnID, itemID: itemID,
                event: .stateChanged(.running), currentAction: action(from: item),
                isAuthoritativeCompletion: true
            )
        case "turn/completed":
            let status = params?["turn"]?["status"]?.stringValue
            let state: SessionState = switch status {
            case "completed": .completed
            case "interrupted": .cancelled
            case "failed": .failed
            default: .failed
            }
            return CodexMappedEvent(
                threadID: threadID, turnID: turnID, itemID: nil,
                event: .stateChanged(state), isAuthoritativeCompletion: true
            )
        case "error":
            return CodexMappedEvent(threadID: threadID, turnID: turnID, itemID: itemID, event: .stateChanged(.failed))
        case "serverRequest/resolved":
            return nil
        default:
            return CodexMappedEvent(threadID: threadID, turnID: turnID, itemID: itemID, event: .unknown(type: method))
        }
    }

    public func action(from item: JSONValue?) -> AgentAction? {
        guard let type = item?["type"]?.stringValue else { return nil }
        switch type {
        case "commandExecution":
            let command = item?["command"]?.stringValue ?? ""
            let cwd = item?["cwd"]?.stringValue.map(URL.init(fileURLWithPath:))
            return ShellCommandParser.parse(command, cwd: cwd).action
        case "fileChange":
            let changes = item?["changes"]?.arrayValue ?? []
            let paths = changes.compactMap { $0["path"]?.stringValue }.map(URL.init(fileURLWithPath:))
            let hasDelete = changes.contains { $0["kind"]?.stringValue == "delete" }
            return .modifyFiles(FileChangeSummary(paths: paths, operation: hasDelete ? .delete : .write))
        case "mcpToolCall":
            let server = item?["server"]?.stringValue ?? "mcp"
            let tool = item?["tool"]?.stringValue ?? "unknown"
            return .useTool(ToolInvocationSummary(name: "\(server)/\(tool)", isReadOnly: false))
        case "dynamicToolCall":
            return .useTool(ToolInvocationSummary(name: item?["tool"]?.stringValue ?? "unknown", isReadOnly: false))
        case "plan":
            return .changePlan(PlanSummary(title: "Codex plan update"))
        default:
            return nil
        }
    }
}

public struct ParsedShellAction: Sendable, Equatable {
    public let action: AgentAction
    public let signals: Set<RiskSignal>
}

public enum ShellCommandParser {
    public static func parse(_ command: String, cwd: URL?) -> ParsedShellAction {
        let shellMetacharacters = ["&&", "||", ";", "|", ">", "<", "$(", "`", "\n"]
        guard !shellMetacharacters.contains(where: command.contains) else {
            return ParsedShellAction(
                action: .executeCommand(ParsedCommand(
                    executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-lc", command], workingDirectory: cwd
                )),
                signals: [.unknownShellComposition]
            )
        }
        let components = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = components.first else {
            return ParsedShellAction(
                action: .custom(CustomActionSummary(summary: "Empty Codex command")), signals: [.unknownShellComposition]
            )
        }
        return ParsedShellAction(
            action: .executeCommand(ParsedCommand(
                executable: URL(fileURLWithPath: executable),
                arguments: Array(components.dropFirst()), workingDirectory: cwd
            )),
            signals: []
        )
    }
}

extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }
}
