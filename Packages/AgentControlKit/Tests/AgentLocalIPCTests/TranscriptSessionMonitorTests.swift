import AgentDomain
@testable import AgentLocalIPC
import AgentProtocol
import Foundation
import Testing

@Suite("Transcript session fallback")
struct TranscriptSessionMonitorTests {
    @Test("Transcript silence is stale, never an invented completion")
    func silenceIsNotCompletion() async throws {
        let fixture = try TranscriptFixture()
        let file = fixture.codexRoot.appendingPathComponent("silent.jsonl")
        try fixture.write(#"{"type":"session_meta","payload":{"id":"silent","cwd":"/private/tmp/Silent"}}"#, to: file)
        let observation = try #require(fixture.scanner.scan(at: fixture.now).first)
        let stack = try await makeTestRuntime(paths: temporaryPaths())
        let monitor = TranscriptSessionMonitor(runtime: stack.runtime, scanner: fixture.scanner)
        await monitor.poll(at: fixture.now)
        #expect(await stack.registry.session(id: observation.sessionID)?.state == .stale)
        await monitor.poll(at: fixture.now.addingTimeInterval(21))
        #expect(await stack.registry.session(id: observation.sessionID)?.state == .stale)
        #expect(await stack.registry.session(id: observation.sessionID)?.endedAt == nil)
        await stack.runtime.gracefulShutdown()
    }

    @Test("Codex lifecycle markers and fresh writes drive live state")
    func codexLifecycle() async throws {
        let fixture = try TranscriptFixture()
        let file = fixture.codexRoot.appendingPathComponent("lifecycle.jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"live","cwd":"/private/tmp/Live"}}"#
        let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        try fixture.write(header + "\n" + started, to: file)
        let observation = try #require(fixture.scanner.scan(at: fixture.now).first)
        let stack = try await makeTestRuntime(paths: temporaryPaths())
        let monitor = TranscriptSessionMonitor(runtime: stack.runtime, scanner: fixture.scanner)
        await monitor.poll(at: fixture.now)
        await monitor.poll(at: fixture.now.addingTimeInterval(30))
        #expect(await stack.registry.session(id: observation.sessionID)?.state == .running)
        try FileManager.default.setAttributes([.modificationDate: fixture.now.addingTimeInterval(40)], ofItemAtPath: file.path)
        await monitor.poll(at: fixture.now.addingTimeInterval(40))
        #expect(await stack.registry.session(id: observation.sessionID)?.lastMeaningfulEventAt == fixture.now.addingTimeInterval(40))
        try fixture.write(header + "\n" + started + "\n" + #"{"type":"event_msg","payload":{"type":"task_complete"}}"#, to: file)
        try FileManager.default.setAttributes([.modificationDate: fixture.now.addingTimeInterval(50)], ofItemAtPath: file.path)
        await monitor.poll(at: fixture.now.addingTimeInterval(50))
        #expect(await stack.registry.session(id: observation.sessionID)?.state == .completed)
        try fixture.write(header + "\n" + started, to: file)
        try FileManager.default.setAttributes([.modificationDate: fixture.now.addingTimeInterval(60)], ofItemAtPath: file.path)
        await monitor.poll(at: fixture.now.addingTimeInterval(60))
        await monitor.poll(at: fixture.now.addingTimeInterval(361))
        #expect(await stack.registry.session(id: observation.sessionID)?.state == .stale)
        await stack.runtime.gracefulShutdown()
    }

    @Test("Abandoned persisted work becomes stale and leaves the active count")
    func expirePersistedWork() async throws {
        let fixture = try TranscriptFixture()
        let file = fixture.codexRoot.appendingPathComponent("abandoned.jsonl")
        try fixture.write("""
        {"type":"session_meta","payload":{"id":"abandoned","cwd":"/private/tmp/Abandoned"}}
        {"type":"event_msg","payload":{"type":"task_started"}}
        """, to: file)
        let observation = try #require(fixture.scanner.scan(at: fixture.now).first)
        let stack = try await makeTestRuntime(paths: temporaryPaths())
        let monitor = TranscriptSessionMonitor(runtime: stack.runtime, scanner: fixture.scanner)
        await monitor.poll(at: fixture.now)
        try await stack.registry.expireInactiveSessions(at: fixture.now.addingTimeInterval(1201))
        #expect(await stack.registry.activeSessionCount() == 0)
        #expect(try await stack.database.session(id: observation.sessionID)?.state == .stale)
        #expect(try await stack.database.sessionAdapterVersion(id: observation.sessionID) == "transcript-v1")
        await stack.runtime.gracefulShutdown()
    }

    @Test("Codex context uses the latest request, not cumulative account tokens")
    func contextUsage() async throws {
        let fixture = try TranscriptFixture()
        let file = fixture.codexRoot.appendingPathComponent("usage.jsonl")
        try fixture.write("""
        {"type":"session_meta","payload":{"id":"context","cwd":"/private/tmp/Context"}}
        {"type":"event_msg","payload":{"type":"task_started"}}
        {"type":"event_msg","timestamp":"2027-01-15T08:00:00.000Z",\
        "payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":900000},\
        "last_token_usage":{"total_tokens":25000},"model_context_window":100000}}}
        """, to: file)
        let observation = try #require(fixture.scanner.scan(at: fixture.now).first)
        #expect(observation.usageMetrics.first?.remainingPercent == 75)
        let stack = try await makeTestRuntime(paths: temporaryPaths())
        let monitor = TranscriptSessionMonitor(runtime: stack.runtime, scanner: fixture.scanner)
        await monitor.poll(at: fixture.now)
        #expect(await stack.registry.session(id: observation.sessionID)?.usageMetrics.first?.remainingPercent == 75)
        await stack.runtime.gracefulShutdown()
    }

    @Test("Long active turns remain live when the start marker leaves the bounded tail")
    func longTurn() throws {
        let fixture = try TranscriptFixture()
        let file = fixture.codexRoot.appendingPathComponent("long.jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"long","cwd":"/private/tmp/Long"}}"#
        let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        let padding = String(repeating: #"{"type":"response_item","payload":{}}"# + "\n", count: 9000)
        let activity = #"{"type":"event_msg","payload":{"type":"token_count"}}"#
        try fixture.write(header + "\n" + started + "\n" + padding + activity, to: file)
        #expect(fixture.scanner.scan(at: fixture.now).first?.observedState == .running)
    }

    @Test("Codex transcripts expose project and parent session metadata")
    func codexDiscovery() throws {
        let fixture = try TranscriptFixture()
        let rootFile = fixture.codexRoot.appendingPathComponent("2026/root.jsonl")
        let childFile = fixture.codexRoot.appendingPathComponent("2026/child.jsonl")
        try fixture.write(
            #"{"type":"session_meta","payload":{"id":"root-thread","cwd":"/private/tmp/Sample"}}"#,
            to: rootFile
        )
        try fixture.write(
            #"{"type":"session_meta","payload":{"id":"child-thread","cwd":"/private/tmp/Sample","parent_thread_id":"root-thread"}}"#,
            to: childFile
        )

        let observations = fixture.scanner.scan(at: fixture.now)
        let root = try #require(observations.first { $0.externalSessionID == "root-thread" })
        let child = try #require(observations.first { $0.externalSessionID == "child-thread" })
        #expect(root.projectURL.path == "/private/tmp/Sample")
        #expect(child.parentExternalSessionID == "root-thread")
        #expect(child.parentSessionID == root.sessionID)
    }

    @Test("Claude subagents are grouped under their transcript session")
    func claudeSubagentDiscovery() throws {
        let fixture = try TranscriptFixture()
        let parent = fixture.claudeRoot.appendingPathComponent("sample/session-1.jsonl")
        let child = fixture.claudeRoot.appendingPathComponent("sample/session-1/subagents/agent-a.jsonl")
        try fixture.write(#"{"sessionId":"session-1","cwd":"/private/tmp/ClaudeProject"}"#, to: parent)
        try fixture.write(#"{"sessionId":"agent-a","cwd":"/private/tmp/ClaudeProject"}"#, to: child)

        let observations = fixture.scanner.scan(at: fixture.now)
        let subagent = try #require(observations.first { $0.externalSessionID == "agent-a" })
        #expect(subagent.parentExternalSessionID == "session-1")
        #expect(subagent.projectURL.path == "/private/tmp/ClaudeProject")
    }

    @Test("Old transcripts are ignored and state submissions remain deterministic")
    func retentionAndSubmission() throws {
        let fixture = try TranscriptFixture()
        let recent = fixture.codexRoot.appendingPathComponent("recent.jsonl")
        let old = fixture.codexRoot.appendingPathComponent("old.jsonl")
        try fixture.write(#"{"payload":{"id":"recent","cwd":"/private/tmp/Recent"}}"#, to: recent)
        try fixture.write(#"{"payload":{"id":"old","cwd":"/private/tmp/Old"}}"#, to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now.addingTimeInterval(-7 * 60 * 60)],
            ofItemAtPath: old.path
        )

        let observations = fixture.scanner.scan(at: fixture.now)
        let observation = try #require(observations.first { $0.externalSessionID == "recent" })
        #expect(observations.contains { $0.externalSessionID == "old" } == false)

        let first = TranscriptSessionMonitor.submission(
            for: observation,
            state: .running,
            resumesTerminalSession: false,
            runningInterval: 20,
            receivedAt: fixture.now
        )
        let second = TranscriptSessionMonitor.submission(
            for: observation,
            state: .running,
            resumesTerminalSession: false,
            runningInterval: 20,
            receivedAt: fixture.now.addingTimeInterval(1)
        )
        #expect(first.envelope.eventID == second.envelope.eventID)
        #expect(first.envelope.eventType == "session.stateChanged")
        #expect(first.initialSession.state == .starting)
        #expect(first.envelope.payload["state"]?.stringValue == SessionState.running.rawValue)
    }

    @Test("Structured provider events take authority over transcript timing")
    // swiftlint:disable:next function_body_length
    func structuredAuthority() async throws {
        let fixture = try TranscriptFixture()
        let file = fixture.codexRoot.appendingPathComponent("authority.jsonl")
        try fixture.write(#"{"payload":{"id":"authority","cwd":"/private/tmp/Authority"}}"#, to: file)
        let observation = try #require(fixture.scanner.scan(at: fixture.now).first)
        let fallback = TranscriptSessionMonitor.submission(
            for: observation,
            state: .running,
            resumesTerminalSession: false,
            runningInterval: 20,
            receivedAt: fixture.now
        )
        let paths = try temporaryPaths()
        let stack = try await makeTestRuntime(paths: paths)
        #expect(await eventDisposition(stack.runtime.handle(.submitEvent(fallback))) == .appended)

        let structuredEnvelope = EventEnvelope(
            eventID: EventID(UUID()),
            eventType: "session.stateChanged",
            source: EventSource(
                adapterID: AdapterID("codex"), adapterVersion: "1.0", nodeID: fallback.envelope.source.nodeID
            ),
            sessionID: fallback.envelope.sessionID,
            providerSessionID: fallback.envelope.providerSessionID,
            sequence: 1,
            occurredAt: fixture.now,
            receivedAt: fixture.now,
            payload: .object(["state": .string(SessionState.waitingInput.rawValue)]),
            privacyClass: .privateMetadata,
            correlationID: EnvelopeID(UUID()),
            schemaHash: "structured-test"
        )
        let structured = HelperEventSubmission(envelope: structuredEnvelope, initialSession: fallback.initialSession)
        #expect(await eventDisposition(stack.runtime.handle(.submitEvent(structured))) == .appended)

        let lateFallback = TranscriptSessionMonitor.submission(
            for: observation,
            state: .completed,
            resumesTerminalSession: false,
            runningInterval: 20,
            receivedAt: fixture.now.addingTimeInterval(20)
        )
        #expect(await eventDisposition(stack.runtime.handle(.submitEvent(lateFallback))) == .duplicate)
        #expect(await stack.registry.session(id: observation.sessionID)?.state == .waitingInput)

        let completionEnvelope = EventEnvelope(
            eventID: EventID(UUID()),
            eventType: "session.stateChanged",
            source: structuredEnvelope.source,
            sessionID: structuredEnvelope.sessionID,
            providerSessionID: structuredEnvelope.providerSessionID,
            sequence: 2,
            occurredAt: fixture.now.addingTimeInterval(1),
            receivedAt: fixture.now.addingTimeInterval(1),
            payload: .object(["state": .string(SessionState.completed.rawValue)]),
            privacyClass: .privateMetadata,
            correlationID: EnvelopeID(UUID()),
            schemaHash: "structured-test"
        )
        #expect(await eventDisposition(stack.runtime.handle(.submitEvent(HelperEventSubmission(
            envelope: completionEnvelope,
            initialSession: fallback.initialSession
        )))) == .appended)
        await stack.runtime.gracefulShutdown()

        let restarted = try await makeTestRuntime(paths: paths)
        #expect(await eventDisposition(restarted.runtime.handle(.submitEvent(lateFallback))) == .duplicate)
        #expect(try await restarted.database.session(id: observation.sessionID)?.state == .completed)
        await restarted.runtime.gracefulShutdown()
    }
}

private func eventDisposition(_ response: HelperResponse) -> EventAppendDisposition? {
    if case let .eventAccepted(value) = response {
        return value
    }
    return nil
}

private struct TranscriptFixture {
    let directory: URL
    let codexRoot: URL
    let claudeRoot: URL
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/transcript-fallback-\(UUID().uuidString)", isDirectory: true)
        codexRoot = directory.appendingPathComponent("codex", isDirectory: true)
        claudeRoot = directory.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
    }

    var scanner: TranscriptSessionScanner {
        TranscriptSessionScanner(codexRoot: codexRoot, claudeRoot: claudeRoot)
    }

    func write(_ line: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((line + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }
}
