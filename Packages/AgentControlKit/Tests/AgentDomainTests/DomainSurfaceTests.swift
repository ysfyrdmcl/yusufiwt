import AgentDomain
import Foundation
import Testing

@Suite("Domain public surface")
struct DomainSurfaceTests {
    @Test("Strong ID constructors remain distinct")
    func allIdentifiers() {
        let uuid = UUID()
        #expect(NodeID(uuid).description == uuid.uuidString.lowercased())
        _ = ProjectID(uuid)
        _ = SessionID(uuid)
        _ = TurnID(uuid)
        _ = ToolRunID(uuid)
        _ = ApprovalRequestID(uuid)
        _ = QuestionID(uuid)
        _ = DeviceID(uuid)
        _ = EnvelopeID(uuid)
        _ = EventID(uuid)
        #expect(AdapterID("codex").description == "codex")
    }

    @Test("Core models retain normalized values")
    func coreModels() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = SessionID(UUID())
        let node = Node(id: NodeID(UUID()), displayName: "Local Mac", isLocal: true)
        let terminal = TerminalContext(
            applicationBundleID: "com.apple.Terminal",
            processID: 10,
            windowIdentifier: "w",
            tabIdentifier: "t",
            paneIdentifier: "p",
            workspaceURI: URL(fileURLWithPath: "/workspace"),
            correlationToken: "token",
            capturedAt: now
        )
        let turn = AgentTurn(id: TurnID(UUID()), sessionID: sessionID, status: .active, startedAt: now)
        let tool = ToolRun(id: ToolRunID(UUID()), sessionID: sessionID, toolName: "read", status: .running)
        let question = AgentQuestion(
            id: QuestionID(UUID()),
            sessionID: sessionID,
            kind: .singleChoice,
            prompt: "Choose",
            choices: [QuestionChoice(id: "a", label: "A")]
        )
        #expect(node.isLocal)
        #expect(terminal.processID == 10)
        #expect(turn.status == .active)
        #expect(tool.toolName == "read")
        #expect(question.status == .pending)
        #expect(question.choices.first?.id == "a")
    }

    @Test("Question choices encode stable IDs and decode legacy labels")
    func questionChoiceWireCompatibility() throws {
        let choice = QuestionChoice(id: "debug", label: "Debug build")
        let encoded = try JSONEncoder().encode(choice)
        #expect(String(bytes: encoded, encoding: .utf8)?.contains("debug") == true)
        let legacy = try JSONDecoder().decode(QuestionChoice.self, from: Data("\"Debug build\"".utf8))
        #expect(legacy.id.hasPrefix("legacy-"))
        #expect(legacy.label == "Debug build")
    }

    @Test("Action summaries and risk values are Codable")
    func actionModels() throws {
        let command = ParsedCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["status"],
            workingDirectory: URL(fileURLWithPath: "/workspace"),
            environmentVariableNames: ["PATH"]
        )
        let network = NetworkAccessSummary(host: "example.com", port: 443, usesTLS: true)
        #expect(command.environmentVariableNames == ["PATH"])
        #expect(network.port == 443)
        #expect(try JSONEncoder().encode(AgentAction.accessNetwork(network)).isEmpty == false)
    }

    @Test("Typed errors expose stable safe descriptors")
    func typedErrors() {
        let descriptor = ErrorDescriptor(
            code: "domain.test",
            userMessage: "Operation failed",
            redactedContext: "request=<redacted>",
            retryability: .retryable,
            recoverySuggestion: "Retry"
        )
        let errors: [any TypedAgentError] = [
            ConfigurationError(descriptor), IntegrationError(descriptor), ProtocolError(descriptor),
            PersistenceError(descriptor), SecurityError(descriptor), RelayError(descriptor),
            NotificationError(descriptor), NavigationError(descriptor), PolicyError(descriptor)
        ]
        #expect(errors.allSatisfy { $0.descriptor.code == "domain.test" })
    }

    @Test("System providers return usable values")
    func systemProviders() {
        let clock = SystemAgentClock()
        #expect(clock.now.timeIntervalSince1970 > 0)
        #expect(clock.monotonicNanoseconds > 0)
        #expect(SystemUUIDProvider().makeUUID() != SystemUUIDProvider().makeUUID())
    }

    @Test("Attention priority is total over session states")
    func attentionPriority() {
        let priorities = SessionState.allCases.map(\.attentionPriority)
        let allTerminal = SessionState.terminalStates.allSatisfy(\.isTerminal)
        #expect(priorities.count == SessionState.allCases.count)
        #expect(allTerminal)
        #expect(!SessionState.running.isTerminal)
    }
}
