import AgentDomain
import AgentProtocol
import Foundation

public enum CodexApprovalDecision: String, Codable, Sendable, Equatable {
    case approve
    case deny
    case cancel

    var providerValue: String {
        switch self {
        case .approve: "accept"
        case .deny: "decline"
        case .cancel: "cancel"
        }
    }
}

public struct CodexApprovalUpdate: Sendable, Equatable {
    public let requestID: ApprovalRequestID
    public let statuses: [ApprovalStatus]
    public let response: CodexRPCMessage?

    public init(requestID: ApprovalRequestID, statuses: [ApprovalStatus], response: CodexRPCMessage? = nil) {
        self.requestID = requestID
        self.statuses = statuses
        self.response = response
    }
}

public struct CodexPendingApproval: Sendable, Equatable {
    public let rpcID: CodexRPCID
    public let threadID: String
    public let turnID: String
    public let itemID: String
    public var request: ApprovalRequest
    public var decision: CodexApprovalDecision?
}

public struct CodexApprovalMapper: Sendable {
    private let classifier: RiskClassifier
    private let uuidProvider: any UUIDProviding

    public init(classifier: RiskClassifier = RiskClassifier(), uuidProvider: any UUIDProviding = SystemUUIDProvider()) {
        self.classifier = classifier
        self.uuidProvider = uuidProvider
    }

    public func map(
        id: CodexRPCID,
        method: String,
        params: JSONValue?,
        sessionID: SessionID,
        workspaceRoot: URL,
        knownAction: AgentAction? = nil,
        defaultExpiry: TimeInterval = 300
    ) throws -> CodexPendingApproval {
        guard method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval",
              let threadID = params?["threadId"]?.stringValue,
              let turnID = params?["turnId"]?.stringValue,
              let itemID = params?["itemId"]?.stringValue
        else { throw CodexAdapterError.invalidPayload(method) }

        let startedAt = Date(timeIntervalSince1970: (params?["startedAtMs"]?.numberValue ?? Date().timeIntervalSince1970 * 1000) / 1000)
        let mapped = try actionAndSignals(method: method, params: params, knownAction: knownAction)
        let risk = classifier.classify(RiskInput(action: mapped.action, workspaceRoot: workspaceRoot, signals: mapped.signals))
        let providerRequestID = params?["approvalId"]?.stringValue ?? itemID + ":" + id.description
        let request = ApprovalRequest(
            id: ApprovalRequestID(uuidProvider.makeUUID()),
            sessionID: sessionID,
            providerRequestID: providerRequestID,
            action: mapped.action,
            risk: risk,
            createdAt: startedAt,
            expiresAt: startedAt.addingTimeInterval(defaultExpiry),
            revision: 1,
            status: .classified
        )
        return CodexPendingApproval(
            rpcID: id, threadID: threadID, turnID: turnID, itemID: itemID,
            request: request, decision: nil
        )
    }

    private func actionAndSignals(
        method: String, params: JSONValue?, knownAction: AgentAction?
    ) throws -> ParsedShellAction {
        if method == "item/commandExecution/requestApproval" {
            if let network = params?["networkApprovalContext"], let host = network["host"]?.stringValue {
                let proto = network["protocol"]?.stringValue?.lowercased()
                return ParsedShellAction(
                    action: .accessNetwork(NetworkAccessSummary(host: host, usesTLS: proto == "https")), signals: []
                )
            }
            if let command = params?["command"]?.stringValue {
                let cwd = params?["cwd"]?.stringValue.map(URL.init(fileURLWithPath:))
                return ShellCommandParser.parse(command, cwd: cwd)
            }
            if let knownAction {
                return ParsedShellAction(action: knownAction, signals: [])
            }
            throw CodexAdapterError.invalidPayload("command approval without command")
        }

        if let knownAction {
            return ParsedShellAction(action: knownAction, signals: [])
        }
        if let root = params?["grantRoot"]?.stringValue {
            return ParsedShellAction(
                action: .modifyFiles(FileChangeSummary(paths: [URL(fileURLWithPath: root)], operation: .write)), signals: []
            )
        }
        return ParsedShellAction(
            action: .custom(CustomActionSummary(summary: "Codex file change approval")), signals: []
        )
    }
}

public actor CodexApprovalCoordinator {
    private var byRPCID: [CodexRPCID: CodexPendingApproval] = [:]
    private var rpcIDByDomainID: [ApprovalRequestID: CodexRPCID] = [:]

    public init() {}

    @discardableResult
    public func register(_ pending: CodexPendingApproval) throws -> ApprovalRequest {
        guard byRPCID[pending.rpcID] == nil else { throw CodexAdapterError.invalidPayload("duplicate approval request id") }
        byRPCID[pending.rpcID] = pending
        rpcIDByDomainID[pending.request.id] = pending.rpcID
        return pending.request
    }

    public func pending() -> [ApprovalRequest] {
        byRPCID.values.map(\.request).sorted { $0.createdAt < $1.createdAt }
    }

    public func respond(
        requestID: ApprovalRequestID,
        revision: Int64,
        decision: CodexApprovalDecision,
        now: Date = Date()
    ) throws -> CodexApprovalUpdate {
        guard let rpcID = rpcIDByDomainID[requestID], var pending = byRPCID[rpcID] else {
            throw CodexAdapterError.unknownRequest(.string(requestID.description))
        }
        guard pending.request.revision == revision else { throw CodexAdapterError.invalidPayload("stale approval revision") }
        if let expiry = pending.request.expiresAt, now >= expiry {
            pending.request.status = .expired
            byRPCID[rpcID] = pending
            return CodexApprovalUpdate(requestID: requestID, statuses: [.expired])
        }
        guard pending.decision == nil else { throw CodexAdapterError.invalidPayload("approval already answered") }
        pending.decision = decision
        pending.request.status = .sentToProvider
        byRPCID[rpcID] = pending
        let result: JSONValue = .object(["decision": .string(decision.providerValue)])
        return CodexApprovalUpdate(
            requestID: requestID,
            statuses: [.signedDecisionReceived, .policyValidated, .sentToProvider],
            response: .response(id: rpcID, result: result)
        )
    }

    public func providerResolved(rpcID: CodexRPCID) throws -> CodexApprovalUpdate {
        guard let pending = byRPCID.removeValue(forKey: rpcID) else { throw CodexAdapterError.unknownRequest(rpcID) }
        rpcIDByDomainID.removeValue(forKey: pending.request.id)
        guard let decision = pending.decision else {
            return CodexApprovalUpdate(requestID: pending.request.id, statuses: [.cancelledByProvider])
        }
        let applied: ApprovalStatus = decision == .approve ? .applied : .deniedApplied
        return CodexApprovalUpdate(
            requestID: pending.request.id,
            statuses: [.providerAcknowledged, applied]
        )
    }

    public func cancel(turnID: String) -> [CodexApprovalUpdate] {
        finalize(where: { $0.turnID == turnID }, status: .cancelledByProvider)
    }

    public func expire(now: Date = Date()) -> [CodexApprovalUpdate] {
        finalize(where: { pending in
            guard let expiry = pending.request.expiresAt else { return false }
            return now >= expiry
        }, status: .expired)
    }

    public func processCrashed() -> [CodexApprovalUpdate] {
        finalize(where: { _ in true }, status: .deliveryFailed)
    }

    private func finalize(
        where predicate: (CodexPendingApproval) -> Bool,
        status: ApprovalStatus
    ) -> [CodexApprovalUpdate] {
        let matches = byRPCID.values.filter(predicate)
        for pending in matches {
            byRPCID.removeValue(forKey: pending.rpcID)
            rpcIDByDomainID.removeValue(forKey: pending.request.id)
        }
        return matches.map { CodexApprovalUpdate(requestID: $0.request.id, statuses: [status]) }
    }
}
