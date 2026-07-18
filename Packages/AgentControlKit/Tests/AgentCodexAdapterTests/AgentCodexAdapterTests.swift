@testable import AgentCodexAdapter
import AgentDomain
import AgentProtocol
import Foundation
import Testing

@Suite("Phase 5 Codex app-server", .serialized)
struct AgentCodexAdapterTests {
    @Test("Recorded JSONL fixture decodes and completion is authoritative")
    func recordedFixture() throws {
        let messages = try fixtureMessages()
        #expect(messages.count == 8)
        let mapper = CodexEventMapper()
        let itemCompleted = messages.compactMap(mapper.map).first { $0.itemID == "item-1" && $0.isAuthoritativeCompletion }
        #expect(itemCompleted?.event == .stateChanged(.running))
        let turnCompleted = messages.compactMap(mapper.map).last
        #expect(turnCompleted?.event == .stateChanged(.completed))
        #expect(turnCompleted?.isAuthoritativeCompletion == true)
    }

    @Test("JSON-RPC codec preserves IDs and rejects invalid framing")
    func codecContract() throws {
        let codec = CodexJSONLCodec()
        let message = CodexRPCMessage.request(
            id: .string("approval-1"), method: "item/fileChange/requestApproval",
            params: .object(["threadId": .string("t")])
        )
        let encoded = try codec.encode(message)
        #expect(encoded.last == 0x0A)
        #expect(String(bytes: encoded, encoding: .utf8)?.contains("jsonrpc") == false)
        #expect(try codec.decode(line: encoded) == message)
        #expect(try codec.decode(line: Data("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}".utf8)) == .notification(method: "initialized", params: nil))
        #expect(throws: CodexAdapterError.self) {
            try codec.decode(line: Data("{\"jsonrpc\":\"1.0\",\"method\":\"initialized\"}".utf8))
        }
        #expect(throws: CodexAdapterError.self) { try codec.decode(line: Data()) }
        #expect(throws: CodexAdapterError.self) { try codec.decode(line: Data([0])) }
    }

    @Test("Binary version and generated schema compatibility are detected")
    func versionAndSchema() throws {
        #expect(CodexVersion("codex-cli 0.145.0-alpha.18") == CodexVersion(major: 0, minor: 145, patch: 0, suffix: "alpha.18"))
        let schemaURL = try #require(Bundle.module.url(forResource: "schema-compatible", withExtension: "json"))
        #expect(try CodexSchemaCompatibility().evaluate(schemaData: Data(contentsOf: schemaURL)) == .full)
        let mismatch = try CodexSchemaCompatibility().evaluate(schemaData: Data("{\"methods\":[\"initialize\"]}".utf8))
        guard case let .monitorOnly(reason) = mismatch else {
            Issue.record("Expected monitor-only")
            return
        }
        #expect(reason.contains("turn/start"))
    }

    @Test("Command and file approvals correlate in parallel and await provider ack")
    func parallelApprovalCorrelation() async throws {
        let mapper = CodexApprovalMapper(uuidProvider: SequenceUUIDProvider())
        let coordinator = CodexApprovalCoordinator()
        let sessionID = SessionID(UUID())
        let root = URL(fileURLWithPath: "/workspace")
        let command = try mapper.map(
            id: .integer(10), method: "item/commandExecution/requestApproval",
            params: approvalParams(item: "command", command: "swift test"),
            sessionID: sessionID, workspaceRoot: root
        )
        let file = try mapper.map(
            id: .string("file-rpc"), method: "item/fileChange/requestApproval",
            params: approvalParams(item: "file", grantRoot: "/workspace/Sources"),
            sessionID: sessionID, workspaceRoot: root
        )
        let commandRequest = try await coordinator.register(command)
        let fileRequest = try await coordinator.register(file)
        #expect(await coordinator.pending().count == 2)

        let sent = try await coordinator.respond(
            requestID: commandRequest.id, revision: 1, decision: .approve,
            now: commandRequest.createdAt.addingTimeInterval(1)
        )
        #expect(sent.statuses.last == .sentToProvider)
        #expect(!sent.statuses.contains(.applied))
        let ack = try await coordinator.providerResolved(rpcID: .integer(10))
        #expect(ack.statuses == [.providerAcknowledged, .applied])

        _ = try await coordinator.respond(
            requestID: fileRequest.id, revision: 1, decision: .deny,
            now: fileRequest.createdAt.addingTimeInterval(1)
        )
        let deniedAck = try await coordinator.providerResolved(rpcID: .string("file-rpc"))
        #expect(deniedAck.statuses == [.providerAcknowledged, .deniedApplied])
    }

    @Test("Expiry, provider cancel, and crash close requests safely")
    func approvalFinalization() async throws {
        let mapper = CodexApprovalMapper(uuidProvider: SequenceUUIDProvider())
        let coordinator = CodexApprovalCoordinator()
        let pending = try mapper.map(
            id: .integer(1), method: "item/commandExecution/requestApproval",
            params: approvalParams(item: "one", command: "swift test"),
            sessionID: SessionID(UUID()), workspaceRoot: URL(fileURLWithPath: "/workspace"), defaultExpiry: 1
        )
        _ = try await coordinator.register(pending)
        let expired = await coordinator.expire(now: pending.request.createdAt.addingTimeInterval(2))
        #expect(expired.first?.statuses == [.expired])

        let second = try mapper.map(
            id: .integer(2), method: "item/fileChange/requestApproval",
            params: approvalParams(item: "two", grantRoot: "/workspace"),
            sessionID: SessionID(UUID()), workspaceRoot: URL(fileURLWithPath: "/workspace")
        )
        _ = try await coordinator.register(second)
        #expect(await coordinator.processCrashed().first?.statuses == [.deliveryFailed])
    }

    @Test("Managed handshake, session start, approval and ack flow")
    func controllerFlow() async throws {
        let ids = SequenceUUIDProvider()
        let controller = CodexManagedSessionController(
            approvalMapper: CodexApprovalMapper(uuidProvider: ids), uuidProvider: ids
        )
        let initialize = try await controller.initialize(clientVersion: "1.0")
        #expect(initialize.id == .integer(1))
        let initialized = try await controller.handle(.response(id: .integer(1), result: .object([
            "userAgent": .string("codex-cli/0.145.0")
        ])))
        #expect(initialized.outgoing == [.notification(method: "initialized", params: nil)])

        let (_, start) = try await controller.startManagedSession(workspaceRoot: URL(fileURLWithPath: "/workspace"))
        #expect(start.id == .integer(2))
        _ = try await controller.handle(.response(id: .integer(2), result: .object([
            "thread": .object(["id": .string("thread-1")])
        ])))
        _ = try await controller.handle(.notification(method: "turn/started", params: .object([
            "threadId": .string("thread-1"), "turn": .object(["id": .string("turn-1")])
        ])))
        _ = try await controller.handle(.notification(method: "item/started", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"),
            "item": .object([
                "type": .string("commandExecution"), "id": .string("item-1"),
                "command": .string("swift test"), "cwd": .string("/workspace")
            ])
        ])))
        let requested = try await controller.handle(.request(
            id: .integer(91), method: "item/commandExecution/requestApproval",
            params: approvalParams(item: "item-1", command: "swift test")
        ))
        let approval = try #require(requested.approvalRequests.first)
        #expect(requested.mappedEvents.first?.event == .stateChanged(.waitingApproval))
        let response = try await controller.respondToApproval(
            requestID: approval.id, revision: 1, decision: .approve,
            now: approval.createdAt.addingTimeInterval(1)
        )
        #expect(response.statuses.last == .sentToProvider)
        #expect(!response.statuses.contains(.applied))
        let resolved = try await controller.handle(.notification(method: "serverRequest/resolved", params: .object([
            "threadId": .string("thread-1"), "requestId": .number(91)
        ])))
        #expect(resolved.approvalUpdates.first?.statuses.last == .applied)
    }

    @Test("Unknown events are retained and diagnostics redact content")
    func unknownAndDiagnostics() async {
        let unknown = CodexEventMapper().map(.notification(
            method: "future/event", params: .object(["threadId": .string("thread-1")])
        ))
        #expect(unknown?.event == .unknown(type: "future/event"))
        let diagnostics = CodexDiagnosticCapture()
        await diagnostics.record(.request(
            id: .integer(1), method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread-1"), "command": .string("print-secret"),
                "cwd": .string("/secret/path")
            ])
        ))
        let data = try? await JSONEncoder().encode(diagnostics.snapshot())
        let text = data.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
        #expect(text.contains("thread-1"))
        #expect(!text.contains("print-secret"))
        #expect(!text.contains("/secret/path"))
    }

    @Test("Production endpoint surface excludes WebSocket and crash is reported")
    func processCrash() async throws {
        let config = CodexAppServerConfiguration(binaryURL: URL(fileURLWithPath: "/usr/bin/false"), endpoint: .stdio, maximumRestartAttempts: 0)
        #expect(config.endpoint.launchArguments == ["app-server", "--stdio"])
        let manager = CodexAppServerProcessManager(configuration: config)
        let events = await manager.events()
        try await manager.start()
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event == .processExited(status: 1))
        #expect(await manager.state == .crashed(status: 1, restartAttempt: 0))
    }
}

private func fixtureMessages() throws -> [CodexRPCMessage] {
    let url = try #require(Bundle.module.url(forResource: "managed-session", withExtension: "jsonl"))
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { try CodexJSONLCodec().decode(line: Data($0.utf8)) }
}

private func approvalParams(item: String, command: String? = nil, grantRoot: String? = nil) -> JSONValue {
    var values: [String: JSONValue] = [
        "threadId": .string("thread-1"), "turnId": .string("turn-1"), "itemId": .string(item),
        "startedAtMs": .number(1_700_000_000_000)
    ]
    if let command {
        values["command"] = .string(command); values["cwd"] = .string("/workspace")
    }
    if let grantRoot {
        values["grantRoot"] = .string(grantRoot)
    }
    return .object(values)
}

private final class SequenceUUIDProvider: UUIDProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1

    func makeUUID() -> UUID {
        lock.lock()
        defer { value += 1; lock.unlock() }
        let suffix = String(format: "%012llx", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }
}
