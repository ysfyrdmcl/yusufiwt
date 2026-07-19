import AgentDomain
import AgentProtocol
import Foundation

public enum CodexControllerState: Equatable, Sendable {
    case idle
    case initializing(requestID: CodexRPCID)
    case ready
    case monitorOnly(reason: String)
    case disconnected
}

public struct CodexManagedSession: Sendable, Equatable {
    public let sessionID: SessionID
    public let threadID: String
    public let workspaceRoot: URL
    public var activeTurnID: String?
}

public struct CodexAdapterOutput: Sendable, Equatable {
    public var outgoing: [CodexRPCMessage] = []
    public var mappedEvents: [CodexMappedEvent] = []
    public var approvalRequests: [ApprovalRequest] = []
    public var approvalUpdates: [CodexApprovalUpdate] = []

    public init() {}
}

private enum PendingClientRequest: Sendable {
    case initialize
    case startThread(sessionID: SessionID, workspaceRoot: URL)
    case startTurn(threadID: String)
    case interruptTurn(threadID: String, turnID: String)
}

public actor CodexManagedSessionController {
    private let mapper: CodexEventMapper
    private let approvalMapper: CodexApprovalMapper
    private let approvals: CodexApprovalCoordinator
    private let uuidProvider: any UUIDProviding
    private var nextRequestID: Int64 = 1
    private var pendingClientRequests: [CodexRPCID: PendingClientRequest] = [:]
    private var sessions: [String: CodexManagedSession] = [:]
    private var itemActions: [String: AgentAction] = [:]
    private var compatibility: CodexCompatibilityMode = .full

    public private(set) var state: CodexControllerState = .idle

    public init(
        mapper: CodexEventMapper = CodexEventMapper(),
        approvalMapper: CodexApprovalMapper = CodexApprovalMapper(),
        approvals: CodexApprovalCoordinator = CodexApprovalCoordinator(),
        uuidProvider: any UUIDProviding = SystemUUIDProvider()
    ) {
        self.mapper = mapper
        self.approvalMapper = approvalMapper
        self.approvals = approvals
        self.uuidProvider = uuidProvider
    }

    public func initialize(clientVersion: String) throws -> CodexRPCMessage {
        guard state == .idle || state == .disconnected else {
            throw CodexAdapterError.invalidPayload("controller already initialized")
        }
        let id = requestID()
        pendingClientRequests[id] = .initialize
        state = .initializing(requestID: id)
        return .request(id: id, method: "initialize", params: .object([
            "clientInfo": .object([
                "name": .string("agentcontrol"),
                "title": .string("yusufiwt"),
                "version": .string(clientVersion)
            ]),
            "capabilities": .object([
                "experimentalApi": .bool(false),
                "requestAttestation": .bool(false)
            ])
        ]))
    }

    public func applyCompatibility(_ compatibility: CodexCompatibilityMode) {
        self.compatibility = compatibility
        if case .ready = state, case let .monitorOnly(reason) = compatibility {
            state = .monitorOnly(reason: reason)
        }
    }

    public func startManagedSession(workspaceRoot: URL, model: String? = nil) throws -> (SessionID, CodexRPCMessage) {
        guard state == .ready else { throw currentModeError() }
        let id = requestID()
        let sessionID = SessionID(uuidProvider.makeUUID())
        pendingClientRequests[id] = .startThread(sessionID: sessionID, workspaceRoot: workspaceRoot)
        var params: [String: JSONValue] = [
            "cwd": .string(workspaceRoot.path),
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("user"),
            "sandbox": .string("workspace-write"),
            "ephemeral": .bool(false),
            "threadSource": .string("agentcontrol")
        ]
        if let model {
            params["model"] = .string(model)
        }
        return (sessionID, .request(id: id, method: "thread/start", params: .object(params)))
    }

    public func startTurn(threadID: String, prompt: String) throws -> CodexRPCMessage {
        guard state == .ready else { throw currentModeError() }
        guard sessions[threadID] != nil else { throw CodexAdapterError.invalidPayload("unknown managed thread") }
        let id = requestID()
        pendingClientRequests[id] = .startTurn(threadID: threadID)
        return .request(id: id, method: "turn/start", params: .object([
            "threadId": .string(threadID),
            "input": .array([.object([
                "type": .string("text"), "text": .string(prompt), "text_elements": .array([])
            ])])
        ]))
    }

    public func cancel(threadID: String) throws -> CodexRPCMessage {
        guard state == .ready else { throw currentModeError() }
        guard let turnID = sessions[threadID]?.activeTurnID else {
            throw CodexAdapterError.invalidPayload("managed thread has no active turn")
        }
        let id = requestID()
        pendingClientRequests[id] = .interruptTurn(threadID: threadID, turnID: turnID)
        return .request(id: id, method: "turn/interrupt", params: .object([
            "threadId": .string(threadID), "turnId": .string(turnID)
        ]))
    }

    public func respondToApproval(
        requestID: ApprovalRequestID,
        revision: Int64,
        decision: CodexApprovalDecision,
        now: Date = Date()
    ) async throws -> CodexApprovalUpdate {
        try await approvals.respond(requestID: requestID, revision: revision, decision: decision, now: now)
    }

    // Dispatch stays centralized so every provider message has one correlation path.
    // swiftlint:disable:next cyclomatic_complexity
    public func handle(_ message: CodexRPCMessage) async throws -> CodexAdapterOutput {
        var output = CodexAdapterOutput()
        switch message {
        case let .response(id, result):
            try handleClientResponse(id: id, result: result, output: &output)
        case let .error(id, error):
            if let id {
                pendingClientRequests.removeValue(forKey: id)
            }
            if case .initializing = state {
                state = .monitorOnly(reason: "Codex initialize failed (\(error.code))")
            }
        case let .request(id, method, params):
            try await handleServerRequest(id: id, method: method, params: params, output: &output)
        case let .notification(method, params):
            if method == "serverRequest/resolved", let id = Self.rpcID(params?["requestId"]) {
                try await output.approvalUpdates.append(approvals.providerResolved(rpcID: id))
            } else {
                if let mapped = mapper.map(message) {
                    output.mappedEvents.append(mapped)
                    if let itemID = mapped.itemID, let action = mapped.currentAction {
                        itemActions[itemID] = action
                    }
                    if mapped.isAuthoritativeCompletion, let itemID = mapped.itemID {
                        itemActions.removeValue(forKey: itemID)
                    }
                    if method == "turn/started", let threadID = mapped.threadID, let turnID = mapped.turnID {
                        sessions[threadID]?.activeTurnID = turnID
                    }
                    if method == "turn/completed", let threadID = mapped.threadID {
                        if let turnID = sessions[threadID]?.activeTurnID {
                            await output.approvalUpdates.append(contentsOf: approvals.cancel(turnID: turnID))
                        }
                        sessions[threadID]?.activeTurnID = nil
                    }
                }
            }
        }
        return output
    }

    public func processCrashed() async -> CodexAdapterOutput {
        state = .disconnected
        pendingClientRequests.removeAll()
        itemActions.removeAll()
        var output = CodexAdapterOutput()
        output.approvalUpdates = await approvals.processCrashed()
        for session in sessions.values {
            output.mappedEvents.append(CodexMappedEvent(
                threadID: session.threadID, turnID: session.activeTurnID, itemID: nil,
                event: .stateChanged(.disconnected)
            ))
        }
        return output
    }

    public func managedSession(threadID: String) -> CodexManagedSession? {
        sessions[threadID]
    }

    private func handleClientResponse(id: CodexRPCID, result: JSONValue, output: inout CodexAdapterOutput) throws {
        guard let request = pendingClientRequests.removeValue(forKey: id) else { return }
        switch request {
        case .initialize:
            guard result["userAgent"]?.stringValue != nil else {
                state = .monitorOnly(reason: "Codex initialize response schema mismatch")
                return
            }
            switch compatibility {
            case .full: state = .ready
            case let .monitorOnly(reason): state = .monitorOnly(reason: reason)
            }
            output.outgoing.append(.notification(method: "initialized", params: nil))
        case let .startThread(sessionID, workspaceRoot):
            guard let threadID = result["thread"]?["id"]?.stringValue else {
                throw CodexAdapterError.invalidPayload("thread/start response")
            }
            sessions[threadID] = CodexManagedSession(
                sessionID: sessionID, threadID: threadID, workspaceRoot: workspaceRoot, activeTurnID: nil
            )
        case let .startTurn(threadID):
            guard let turnID = result["turn"]?["id"]?.stringValue else {
                throw CodexAdapterError.invalidPayload("turn/start response")
            }
            sessions[threadID]?.activeTurnID = turnID
        case .interruptTurn:
            break
        }
    }

    private func handleServerRequest(
        id: CodexRPCID, method: String, params: JSONValue?, output: inout CodexAdapterOutput
    ) async throws {
        guard method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" else {
            output.outgoing.append(.error(
                id: id, error: CodexRPCError(code: -32601, message: "Unsupported server request")
            ))
            return
        }
        guard state == .ready else {
            output.outgoing.append(.response(id: id, result: .object(["decision": .string("decline")])))
            return
        }
        guard let threadID = params?["threadId"]?.stringValue, let session = sessions[threadID] else {
            output.outgoing.append(.response(id: id, result: .object(["decision": .string("decline")])))
            return
        }
        let itemID = params?["itemId"]?.stringValue
        let pending = try approvalMapper.map(
            id: id, method: method, params: params, sessionID: session.sessionID,
            workspaceRoot: session.workspaceRoot, knownAction: itemID.flatMap { itemActions[$0] }
        )
        try await output.approvalRequests.append(approvals.register(pending))
        output.mappedEvents.append(CodexMappedEvent(
            threadID: threadID, turnID: pending.turnID, itemID: pending.itemID,
            event: .stateChanged(.waitingApproval), currentAction: pending.request.action
        ))
    }

    private func requestID() -> CodexRPCID {
        defer { nextRequestID += 1 }
        return .integer(nextRequestID)
    }

    private func currentModeError() -> CodexAdapterError {
        if case let .monitorOnly(reason) = state {
            return .monitorOnly(reason)
        }
        return .processNotRunning
    }

    private static func rpcID(_ value: JSONValue?) -> CodexRPCID? {
        switch value {
        case let .string(value): .string(value)
        case let .number(value) where value.rounded() == value: .integer(Int64(value))
        default: nil
        }
    }
}
