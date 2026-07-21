// swiftlint:disable file_length
import AgentDomain
import AgentHookKit
import AgentLocalIPC
import AgentPersistence
import AgentProtocol
import Foundation
import Testing

@Suite("Phase 4 hook and simulator", .serialized)
struct AgentHookKitTests {
    @Test("Decision request travels through helper and returns to hook")
    func decisionRoundTrip() async throws {
        let paths = try phase4TemporaryPaths()
        let stack = try await phase4Runtime(paths: paths)
        let server = UnixSocketServer(socketURL: paths.socketURL) { request in
            await stack.runtime.handle(request)
        }
        try server.start()
        await stack.runtime.setSocketAcceptingConnections(true)
        defer { server.stop() }

        let request = phase4DecisionRequest(timeout: 2000)
        let hook = AgentControlHookClient(configuration: HookConfiguration(
            socketURL: paths.socketURL,
            spoolDirectory: paths.spoolDirectory,
            decisionTimeoutMilliseconds: 2500
        ))
        async let response = hook.requestDecision(request)

        try await waitUntilPending(request.requestID, runtime: stack.runtime)
        let resolution = await hook.send(
            .resolveDecision(HookDecisionResolution(
                requestID: request.requestID,
                revision: request.revision,
                decision: .approve
            )),
            timeoutMilliseconds: 1000
        )
        #expect(resolution.resolutionDisposition == .accepted)
        #expect(await response.decisionValue?.decision == .approve)
        // The request and helper-owned `sentToProvider` transition are both
        // append-only audit events; provider application is still a later event.
        #expect(try await stack.database.eventCount() == 2)
        await stack.runtime.gracefulShutdown()
    }

    @Test("Missing helper returns native fallback without replaying synchronous decisions")
    func nativeFallbackAndSpool() async throws {
        let paths = try phase4TemporaryPaths()
        try paths.prepare()
        let hook = AgentControlHookClient(configuration: HookConfiguration(
            socketURL: paths.socketURL,
            spoolDirectory: paths.spoolDirectory,
            decisionTimeoutMilliseconds: 100,
            statusTimeoutMilliseconds: 50
        ))
        let request = phase4DecisionRequest(timeout: 50)
        let response = await hook.requestDecision(request)
        #expect(response.neutralValue == .helperUnavailable)

        let spool = HookSpool(directory: paths.spoolDirectory)
        #expect(try await spool.pendingCount() == 0)
        let emitResponse = await hook.emit(request.submission)
        #expect(emitResponse.eventDisposition == .spooled)
        #expect(try await spool.pendingCount() == 1)
    }

    @Test("A decision reconnects after helper restart without duplicate pending work")
    func decisionReconnect() async throws {
        let paths = try phase4TemporaryPaths()
        try paths.prepare()
        let request = phase4DecisionRequest(timeout: 2000)
        let hook = AgentControlHookClient(configuration: HookConfiguration(
            socketURL: paths.socketURL,
            spoolDirectory: paths.spoolDirectory,
            decisionTimeoutMilliseconds: 2250
        ))
        async let providerResponse = hook.requestDecision(request)

        // The hook starts while the helper is unavailable, as it would during a restart.
        try await Task.sleep(for: .milliseconds(180))
        let stack = try await phase4Runtime(paths: paths)
        let server = UnixSocketServer(socketURL: paths.socketURL) { value in
            await stack.runtime.handle(value)
        }
        try server.start()
        defer { server.stop() }
        await stack.runtime.setSocketAcceptingConnections(true)
        try await waitUntilPending(request.requestID, runtime: stack.runtime)
        guard case let .pendingDecisions(pending) = await stack.runtime.handle(.pendingDecisions) else {
            Issue.record("Pending decision endpoint returned the wrong response")
            return
        }
        #expect(pending.count == 1)
        #expect(await stack.runtime.handle(.resolveDecision(.init(
            requestID: request.requestID,
            revision: request.revision,
            decision: .approve
        ))).resolutionDisposition == .accepted)
        #expect(await providerResponse.decisionValue?.decision == .approve)
        #expect(try await HookSpool(directory: paths.spoolDirectory).pendingCount() == 0)
        await stack.runtime.gracefulShutdown()
    }

    @Test("Decision broker validates revision, answer choices, and timeout")
    func decisionValidation() async throws {
        let broker = HookDecisionBroker()
        let request = phase4DecisionRequest(kind: .question, choices: ["Debug", "Release"], timeout: 150)
        let debugID = try #require(request.choices.first?.id)
        async let result = broker.wait(for: request)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await broker.resolve(HookDecisionResolution(
            requestID: request.requestID,
            revision: 2,
            decision: .answerChoice(id: debugID)
        )) == .revisionMismatch)
        #expect(await broker.resolve(HookDecisionResolution(
            requestID: request.requestID,
            revision: 1,
            decision: .answerChoice(id: "missing")
        )) == .invalidDecision)
        #expect(await broker.resolve(HookDecisionResolution(
            requestID: request.requestID,
            revision: 1,
            decision: .answerChoice(id: debugID)
        )) == .accepted)
        #expect(await result.decisionValue?.decision == .answerChoice(id: debugID))

        let timedOut = phase4DecisionRequest(timeout: 10)
        #expect(await broker.wait(for: timedOut).neutralValue == .timeout)
    }

    @Test("Broker validates all question and plan decision payloads")
    func phase8DecisionPayloads() async throws {
        let broker = HookDecisionBroker()
        let multi = phase8QuestionRequest(
            kind: .multiChoice,
            choices: [QuestionChoice(id: "debug", label: "Debug"), QuestionChoice(id: "release", label: "Release")]
        )
        async let multiResult = broker.wait(for: multi)
        try await Task.sleep(for: .milliseconds(10))
        #expect(await broker.resolve(.init(
            requestID: multi.requestID,
            revision: multi.revision,
            decision: .answerChoices(ids: ["debug", "release"])
        )) == .accepted)
        #expect(await multiResult.decisionValue?.decision == .answerChoices(ids: ["debug", "release"]))

        let boundedText = phase8QuestionRequest(kind: .freeText, maximumAnswerLength: 4)
        async let textResult = broker.wait(for: boundedText)
        try await Task.sleep(for: .milliseconds(10))
        #expect(await broker.resolve(.init(
            requestID: boundedText.requestID,
            revision: boundedText.revision,
            decision: .answerText("12345")
        )) == .invalidDecision)
        #expect(await broker.resolve(.init(
            requestID: boundedText.requestID,
            revision: boundedText.revision,
            decision: .answerText("1234")
        )) == .accepted)
        _ = await textResult

        let secret = phase8QuestionRequest(kind: .secret)
        async let secretResult = broker.wait(for: secret)
        try await Task.sleep(for: .milliseconds(10))
        #expect(await broker.resolve(.init(
            requestID: secret.requestID,
            revision: secret.revision,
            decision: .answerText("do-not-relay")
        )) == .invalidDecision)
        #expect(await broker.resolve(.init(
            requestID: secret.requestID,
            revision: secret.revision,
            decision: .deny
        )) == .accepted)
        _ = await secretResult

        let plan = phase4DecisionRequest(kind: .plan, timeout: 150)
        async let planResult = broker.wait(for: plan)
        try await Task.sleep(for: .milliseconds(10))
        #expect(await broker.resolve(.init(
            requestID: plan.requestID,
            revision: plan.revision,
            decision: .requestPlanChanges("Keep the public API stable")
        )) == .accepted)
        #expect(await planResult.decisionValue?.decision == .requestPlanChanges("Keep the public API stable"))
    }

    @Test("Bounded JSON rejects oversized, malformed, and deeply nested input")
    func boundedInput() throws {
        #expect(throws: HookInputError.self) {
            try BoundedJSON.decode(HelperRequest.self, from: Data(), maximumBytes: 100)
        }
        #expect(throws: HookInputError.self) {
            try BoundedJSON.decode(HelperRequest.self, from: Data(repeating: 1, count: 101), maximumBytes: 100)
        }
        #expect(throws: HookInputError.self) {
            try BoundedJSON.decode(HelperRequest.self, from: Data("not-json".utf8), maximumBytes: 100)
        }
        let nested = Data((String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66)).utf8)
        #expect(throws: HookInputError.self) {
            try BoundedJSON.decode(JSONValue.self, from: nested, maximumBytes: 1000)
        }
    }

    @Test("Simulator covers every required scenario")
    func simulatorScenarios() {
        let builder = FakeAgentScenarioBuilder()
        for scenario in FakeAgentScenario.allCases {
            #expect(!builder.steps(for: scenario, decisionTimeoutMilliseconds: 10).isEmpty)
        }
        if case let .requestDecision(approval) = builder.steps(for: .approval)[0] {
            if case .approvalRequested = approval.submission.envelope.domainEvent {
                // The normalized fixture drives the real approval attention state.
            } else {
                Issue.record("Approval fixture was not normalized")
            }
        }
        if case let .requestDecision(question) = builder.steps(for: .question)[0] {
            if case .questionRequested = question.submission.envelope.domainEvent {
                // The normalized fixture drives the real question attention state.
            } else {
                Issue.record("Question fixture was not normalized")
            }
        }
    }

    @Test("Local event round-trip p95 stays below 500 milliseconds")
    func localEventPerformance() async throws {
        let paths = try phase4TemporaryPaths()
        let stack = try await phase4Runtime(paths: paths)
        let server = UnixSocketServer(socketURL: paths.socketURL) { request in await stack.runtime.handle(request) }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketClient(socketURL: paths.socketURL)
        var durations: [Duration] = []
        let clock = ContinuousClock()
        for sequence in 1 ... 40 {
            let submission = phase4Submission(sequence: Int64(sequence))
            let start = clock.now
            let response = try client.send(.submitEvent(submission), timeoutMilliseconds: 1000)
            durations.append(start.duration(to: clock.now))
            #expect(response.eventDisposition == .appended)
        }
        durations.sort()
        let p95 = durations[Int(Double(durations.count - 1) * 0.95)]
        let p95Milliseconds = Double(p95.components.seconds) * 1000
            + Double(p95.components.attoseconds) / 1_000_000_000_000_000
        print(String(format: "local event -> helper p95: %.2f ms (n=%d)", p95Milliseconds, durations.count))
        #expect(p95 < .milliseconds(500))
        await stack.runtime.gracefulShutdown()
    }
}

private func waitUntilPending(_ requestID: UUID, runtime: HelperRuntime) async throws {
    for _ in 0 ..< 100 {
        if await runtime.handle(.pendingDecisions).pendingValues?.contains(where: { $0.requestID == requestID }) == true {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw LocalIPCError.timeout
}

private func phase4TemporaryPaths() throws -> AgentControlPaths {
    AgentControlPaths(baseDirectory: URL(fileURLWithPath: "/private/tmp/ac-phase4-\(UUID().uuidString)", isDirectory: true))
}

private func phase4Runtime(paths: AgentControlPaths) async throws -> (
    database: DatabaseActor,
    runtime: HelperRuntime
) {
    try paths.prepare()
    let database = try DatabaseActor(
        configuration: DatabaseConfiguration(url: paths.databaseURL),
        cipher: AESGCMFieldCipher(keyData: Data(repeating: 9, count: 32))
    )
    let registry = SessionRegistryActor(database: database)
    let spool = HookSpool(directory: paths.spoolDirectory)
    try await spool.prepare()
    return (database, HelperRuntime(database: database, registry: registry, spool: spool, paths: paths))
}

private func phase4DecisionRequest(
    kind: HookDecisionKind = .approval,
    choices: [String] = [],
    timeout: Int
) -> HookDecisionRequest {
    HookDecisionRequest(
        requestID: UUID(),
        revision: 1,
        kind: kind,
        prompt: "Phase 4 decision",
        choices: choices,
        expiresAt: Date().addingTimeInterval(60),
        waitTimeoutMilliseconds: timeout,
        submission: phase4Submission(sequence: 1, eventType: "approval.requested")
    )
}

private func phase4Submission(
    sequence: Int64,
    eventType: String = "session.stateChanged",
    payload explicitPayload: JSONValue? = nil,
    privacyClass: PrivacyClass = .privateMetadata
) -> HelperEventSubmission {
    let nodeID = NodeID(fixedUUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    let sessionID = SessionID(fixedUUID("cccccccc-cccc-cccc-cccc-cccccccccccc"))
    let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence))
    return HelperEventSubmission(
        envelope: EventEnvelope(
            eventID: EventID(UUID()),
            eventType: eventType,
            source: EventSource(adapterID: AdapterID("phase4-test"), adapterVersion: "1", nodeID: nodeID),
            sessionID: sessionID,
            sequence: sequence,
            occurredAt: date,
            receivedAt: date,
            payload: explicitPayload ?? (eventType == "session.stateChanged" ? .object(["state": .string("running")]) : .object(["prompt": .string("test")])),
            privacyClass: privacyClass,
            correlationID: EnvelopeID(UUID()),
            schemaHash: "phase4-test"
        ),
        initialSession: AgentSession(
            id: sessionID,
            nodeID: nodeID,
            adapterID: AdapterID("phase4-test"),
            externalSessionID: nil,
            project: ProjectReference(
                id: ProjectID(fixedUUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")),
                name: "Phase4",
                rootURL: URL(fileURLWithPath: "/private/tmp/Phase4")
            ),
            terminalContext: nil,
            parentSessionID: nil,
            state: .discovered,
            startedAt: date,
            endedAt: nil,
            lastMeaningfulEventAt: date,
            snapshotRevision: 0
        )
    )
}

private func phase8QuestionRequest(
    kind: QuestionKind,
    choices: [QuestionChoice] = [],
    maximumAnswerLength: Int? = nil
) -> HookDecisionRequest {
    let requestID = UUID()
    let sessionID = SessionID(fixedUUID("cccccccc-cccc-cccc-cccc-cccccccccccc"))
    let question = AgentQuestion(
        id: QuestionID(requestID),
        sessionID: sessionID,
        kind: kind,
        prompt: "Phase 8 question",
        choices: choices,
        maximumAnswerLength: maximumAnswerLength
    )
    return HookDecisionRequest(
        requestID: requestID,
        revision: 1,
        kind: .question,
        prompt: question.prompt,
        choices: choices,
        maximumAnswerLength: maximumAnswerLength,
        expiresAt: Date().addingTimeInterval(60),
        waitTimeoutMilliseconds: 150,
        submission: phase4Submission(
            sequence: 1,
            eventType: "question.requested",
            payload: (try? JSONValue.encoding(question)) ?? .object([:]),
            privacyClass: kind == .secret ? .secret : .sensitive
        )
    )
}

private func fixedUUID(_ value: String) -> UUID {
    UUID(uuidString: value) ?? UUID()
}

private extension HelperResponse {
    var eventDisposition: EventAppendDisposition? {
        guard case let .eventAccepted(value) = self else { return nil }
        return value
    }

    var decisionValue: HookDecisionResult? {
        guard case let .decision(value) = self else { return nil }
        return value
    }

    var resolutionDisposition: DecisionResolutionDisposition? {
        guard case let .decisionResolution(value) = self else { return nil }
        return value
    }

    var neutralValue: NeutralFallbackReason? {
        guard case let .neutral(value) = self else { return nil }
        return value
    }

    var pendingValues: [PendingHookDecision]? {
        guard case let .pendingDecisions(value) = self else { return nil }
        return value
    }
}

// swiftlint:enable file_length
