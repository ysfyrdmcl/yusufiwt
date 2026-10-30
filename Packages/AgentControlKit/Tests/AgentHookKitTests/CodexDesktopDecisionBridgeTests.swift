import AgentDomain
import AgentHookKit
import AgentLocalIPC
import AgentProtocol
import Foundation
import Testing

struct CodexDesktopDecisionBridgeTests {
    @Test("Notch broker decisions reach the native RPC and receive provider acknowledgment", arguments: ["accept", "decline", "answer"])
    func roundTrip(outcome: String) async throws {
        try await exercise(outcome: outcome)
    }

    @Test("Unavailable helper leaves the native desktop request intact")
    func fallback() async throws {
        try await exercise(outcome: nil)
    }

    private func exercise(outcome: String?) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = HookDecisionBroker()
        let configuration = HookConfiguration(socketURL: directory.appendingPathComponent("helper.sock"), spoolDirectory: directory)
        let helper = UnixSocketServer(socketURL: configuration.socketURL) { request in
            switch request {
            case .health:
                return .health(HelperHealth(protocolVersion: 1, processID: getpid(), uptimeSeconds: 0,
                                            activeSessionCount: 1, persistedEventCount: 0, spoolPendingCount: 0,
                                            socketAcceptingConnections: true, databaseHealthy: true))
            case let .requestDecision(value): return await broker.wait(for: value)
            case let .submitEvent(value):
                if let id = value.envelope.payload["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                   let status = value.envelope.payload["status"]?.stringValue.flatMap(ApprovalStatus.init(rawValue:)) {
                    await broker.observeProviderStatus(requestID: id, revision: 1, status: status)
                }
                return .eventAccepted(.appended)
            default: return .neutral(reason: .helperUnavailable)
            }
        }
        if outcome != nil {
            try helper.start()
        }
        defer { helper.stop() }
        let script = directory.appendingPathComponent("server.py")
        let log = directory.appendingPathComponent("response.json")
        let question = outcome == "answer"
        try """
        import json, sys
        request = {'id': 42, 'method': '\(question ? "item/tool/requestUserInput" : "item/commandExecution/requestApproval")',
                   'params': {'threadId': 'thread', 'turnId': 'turn', 'itemId': 'item', 'cwd': '/tmp/project',
                              'command': 'echo hello', 'questions': [{'id': 'q', 'header': 'Choice', 'question': 'Continue?',
                              'options': [{'label': 'Yes', 'description': 'Continue'}]}]}}
        for line in sys.stdin:
            value = json.loads(line)
            if value.get('method') == 'initialize':
                print(json.dumps(request), flush=True)
            elif value.get('id') == 42 and 'result' in value:
                with open('\(log.path)', 'w') as f: json.dump(value, f)
                print(json.dumps({'method': 'serverRequest/resolved', 'params': {'threadId': 'thread', 'requestId': 42}}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let input = Pipe()
        let outputURL = directory.appendingPathComponent("desktop-output")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let bridge = CodexDesktopDecisionBridge(client: AgentControlHookClient(configuration: configuration))
        let relay = CodexDesktopRelay(decisionHandler: { data, respond in await bridge.handle(data, respond: respond) })
        let socket = directory.appendingPathComponent("desktop.sock")
        let run = Task.detached {
            try relay.run(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path],
                          socketURL: socket, input: input.fileHandleForReading, output: output)
        }
        defer { relay.stop(); try? input.fileHandleForWriting.close() }
        try input.fileHandleForWriting.write(contentsOf: Data("{\"id\":\"init\",\"method\":\"initialize\"}\n".utf8))
        if let outcome {
            var decision: PendingHookDecision?
            for _ in 0 ..< 150 {
                decision = await broker.pending().first
                if decision != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let pending = try #require(decision)
            let answer: HookDecision = try question ? .answerChoice(id: #require(pending.choices.first).id)
                : (outcome == "accept" ? .approve : .deny)
            _ = await broker.resolve(HookDecisionResolution(requestID: pending.requestID, revision: pending.revision, decision: answer))
            for _ in 0 ..< 150 {
                if await broker.lifecycles().first?.state.isFinal == true {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(await broker.lifecycles().first?.state == (outcome == "decline" ? .deniedApplied : .applied))
            let response = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: log))
            #expect(response["id"] == .number(42))
            if question {
                #expect(response["result"]?["answers"]?["q"]?["answers"] == .array([.string("Yes")]))
            } else {
                #expect(response["result"]?["decision"] == .string(outcome))
            }
        } else {
            for _ in 0 ..< 150 {
                if try (String(contentsOf: outputURL, encoding: .utf8)).contains("requestApproval") {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!FileManager.default.fileExists(atPath: log.path))
        }
        try input.fileHandleForWriting.close()
        _ = try await run.value
        let nativeOutput = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(nativeOutput.contains("requestApproval") == (outcome == nil))
    }
}
