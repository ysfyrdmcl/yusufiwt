import AgentDomain
import AgentLocalIPC
import AgentMacUI
import AgentPersistence
import AgentProtocol
import Foundation
import Testing

// swiftlint:disable type_body_length
@Suite("Phase 7 macOS UI", .serialized)
struct AgentMacUITests {
    @Test("Panel placement follows the cursor display and visible fullscreen bounds")
    func multiDisplayPlacement() throws {
        let displays = [
            DisplayGeometry(
                identifier: "main",
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 850)
            ),
            DisplayGeometry(
                identifier: "external",
                frame: CGRect(x: 1440, y: -200, width: 2560, height: 1440),
                visibleFrame: CGRect(x: 1440, y: -160, width: 2560, height: 1360)
            )
        ]
        let frame = try #require(FloatingPanelPlacement.frame(
            panelSize: CGSize(width: 480, height: 430),
            displays: displays,
            cursorLocation: CGPoint(x: 2000, y: 500)
        ))
        #expect(frame.midX == displays[1].visibleFrame.midX)
        #expect(frame.maxY <= displays[1].visibleFrame.maxY)
        #expect(frame.minY >= displays[1].visibleFrame.minY)
    }

    @Test("Panel clamps oversized content to a fullscreen display")
    func fullscreenPlacement() throws {
        let display = DisplayGeometry(
            identifier: "fullscreen",
            frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
            visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 768)
        )
        let frame = try #require(FloatingPanelPlacement.frame(
            panelSize: CGSize(width: 1400, height: 900),
            displays: [display],
            cursorLocation: CGPoint(x: 20, y: 20)
        ))
        #expect(frame == display.visibleFrame)
    }

    @Test("Store loads one hundred active sessions without truncation")
    @MainActor
    func hundredSessionSnapshot() async {
        let transport = FixtureUITransport(sessions: Self.sessions(count: 100))
        let store = AgentControlStore(transport: transport, refreshInterval: .seconds(60))
        await store.refreshNow()
        #expect(store.connectionState == .online)
        #expect(store.activeSessions.count == 100)
    }

    @Test("Disconnect keeps the last snapshot and reconnect refreshes revisions")
    @MainActor
    func disconnectReconnectRetention() async {
        let transport = FixtureUITransport(sessions: Self.sessions(count: 3))
        let store = AgentControlStore(transport: transport, refreshInterval: .seconds(60))
        await store.refreshNow()
        #expect(store.sessions.count == 3)

        await transport.setOnline(false)
        await store.refreshNow()
        #expect(store.connectionState == .offline)
        #expect(store.retainsDataWhileOffline)
        #expect(store.sessions.count == 3)

        await transport.setOnline(true)
        await transport.setSessions(Self.sessions(count: 4))
        await store.refreshNow()
        #expect(store.connectionState == .online)
        #expect(store.sessions.count == 4)
    }

    @Test("Keyboard decision path resolves through the transport")
    @MainActor
    func decisionResolution() async {
        let pending = PendingHookDecision(request: Self.decisionRequest())
        let transport = FixtureUITransport(sessions: [], pending: [pending])
        let store = AgentControlStore(transport: transport, refreshInterval: .seconds(60))
        await store.refreshNow()
        let disposition = await store.resolve(pending, as: .approve)
        #expect(disposition == .accepted)
        #expect(await transport.lastDecision() == .approve)
        #expect(store.acknowledgmentStatuses[pending.requestID] == .sentToProvider)
        #expect(store.acknowledgmentStatuses[pending.requestID]?.isApplied == false)
    }

    @Test("Duplicate requests collapse to the newest revision")
    @MainActor
    func duplicateSuppression() async {
        let requestID = UUID()
        let old = PendingHookDecision(request: Self.decisionRequest(requestID: requestID, revision: 1))
        let newest = PendingHookDecision(request: Self.decisionRequest(requestID: requestID, revision: 2))
        let store = AgentControlStore(
            transport: FixtureUITransport(sessions: [], pending: [old, newest, newest]),
            refreshInterval: .seconds(60)
        )
        await store.refreshNow()
        #expect(store.pendingDecisions.count == 1)
        #expect(store.pendingDecisions.first?.revision == 2)
    }

    @Test("Expired requests cannot send an action")
    @MainActor
    func expiredDecision() async {
        let pending = PendingHookDecision(request: Self.decisionRequest(expiresAt: .distantPast))
        let transport = FixtureUITransport(sessions: [], pending: [pending])
        let store = AgentControlStore(transport: transport, refreshInterval: .seconds(60))
        await store.refreshNow()
        #expect(await store.resolve(pending, as: .approve) == .expired)
        #expect(await transport.lastDecision() == nil)
        #expect(store.acknowledgmentStatuses[pending.requestID] == .expired)
    }

    @Test("Secret questions always fall back to the terminal")
    func secretQuestionFallback() {
        let pending = PendingHookDecision(request: Self.decisionRequest(kind: .question, questionKind: .secret))
        #expect(DecisionAvailability.evaluate(pending) == .secretRequiresTerminal)
    }

    @Test("Quiet hours span midnight and suppress sound")
    func quietHoursPolicy() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let duringQuiet = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 23, minute: 30)))
        let daytime = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 10)))
        let preferences = MacNotificationPreferences(quietHours: QuietHours(startMinute: 22 * 60, endMinute: 7 * 60))
        #expect(MacNotificationPolicy.delivery(preferences: preferences, at: duringQuiet, calendar: calendar) == .deliverSilently)
        #expect(MacNotificationPolicy.delivery(preferences: preferences, at: daytime, calendar: calendar) == .deliverWithSound)
    }

    @Test("Notification duplicate key includes request revision")
    func notificationDeduplication() {
        let requestID = UUID()
        let first = PendingHookDecision(request: Self.decisionRequest(requestID: requestID, revision: 1))
        let second = PendingHookDecision(request: Self.decisionRequest(requestID: requestID, revision: 2))
        var deduplicator = NotificationDeduplicator()
        let firstDelivery = deduplicator.shouldDeliver(first)
        let duplicateDelivery = deduplicator.shouldDeliver(first)
        let revisedDelivery = deduplicator.shouldDeliver(second)
        #expect(firstDelivery)
        #expect(!duplicateDelivery)
        #expect(revisedDelivery)
    }

    @Test("Mac notification preferences persist every local policy switch")
    func notificationPreferencePersistence() throws {
        let suiteName = "AgentMacUITests.notifications.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MacNotificationPreferencesStore(defaults: defaults)
        let value = MacNotificationPreferences(
            enabled: false,
            soundEnabled: false,
            decisionNotificationsEnabled: false,
            completedNotificationsEnabled: true,
            failedNotificationsEnabled: false,
            longRunningIdleNotificationsEnabled: false,
            focusAware: false,
            quietHours: QuietHours(startMinute: 1320, endMinute: 420),
            privacyLevel: .projectAndEvent
        )
        store.save(value)
        #expect(store.load() == value)
    }

    @Test("Approval presentation exposes parsed command and risk reasons")
    func approvalPresentation() {
        let pending = PendingHookDecision(request: Self.decisionRequest())
        let presentation = DecisionPresentation(decision: pending)
        #expect(presentation.detailLines.contains { $0.contains("/usr/bin/swift") })
        #expect(presentation.risk?.level == .medium)
        #expect(presentation.riskReasons == ["workspace-write"])
    }

    @Test("Notification callbacks reject superseded, expired, secret, and duplicate actions")
    @MainActor
    func notificationResponseValidation() async {
        let requestID = UUID()
        let current = PendingHookDecision(request: Self.decisionRequest(requestID: requestID, revision: 2))
        let transport = FixtureUITransport(sessions: [], pending: [current])
        let store = AgentControlStore(transport: transport, refreshInterval: .seconds(60))
        await store.refreshNow()
        #expect(await store.handleNotificationResponse(.init(action: .approve, requestID: requestID, revision: 1)) == .superseded)
        #expect(await store.handleNotificationResponse(.init(action: .approve, requestID: requestID, revision: 2)) == .sent)
        #expect(await store.handleNotificationResponse(.init(action: .approve, requestID: requestID, revision: 2)) == .notFound)

        let expiredID = UUID()
        let expired = PendingHookDecision(request: Self.decisionRequest(requestID: expiredID, expiresAt: .distantPast))
        await transport.setPending([expired])
        await store.refreshNow()
        #expect(await store.handleNotificationResponse(.init(action: .approve, requestID: expiredID, revision: 1)) == .expired)

        let secretID = UUID()
        let secret = PendingHookDecision(request: Self.decisionRequest(requestID: secretID, kind: .question, questionKind: .secret))
        await transport.setPending([secret])
        await store.refreshNow()
        #expect(await store.handleNotificationResponse(.init(action: .approve, requestID: secretID, revision: 1)) == .rejected)
    }

    @Test("Global hotkey defaults to Control-Option-Space and persists customization")
    @MainActor
    func globalHotKeyPersistence() throws {
        let suiteName = "AgentMacUITests.hotkey.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GlobalHotKeyPreferences(defaults: defaults)
        #expect(preferences.load() == .controlOptionSpace)
        #expect(preferences.load().keyCode == 49)
        preferences.save(.commandShiftA)
        #expect(preferences.load() == .commandShiftA)
    }

    private static func sessions(count: Int) -> [SessionListItem] {
        (0 ..< count).map { index in
            SessionListItem(
                id: SessionID(UUID()),
                projectName: "Project \(index)",
                adapterID: AdapterID(index.isMultiple(of: 2) ? "codex" : "claude"),
                state: .running,
                startedAt: Date(timeIntervalSince1970: 1_699_999_000 + Double(index)),
                lastMeaningfulEventAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                snapshotRevision: Int64(index)
            )
        }
    }

    // A single fixture builder keeps every decision variant on the same wire contract.
    // swiftlint:disable:next function_body_length
    private static func decisionRequest(
        requestID: UUID = UUID(),
        revision: Int64 = 1,
        kind: HookDecisionKind = .approval,
        questionKind: QuestionKind = .freeText,
        expiresAt: Date? = Date.distantFuture
    ) -> HookDecisionRequest {
        let sessionID = SessionID(UUID())
        let nodeID = NodeID(UUID())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = AgentSession(
            id: sessionID,
            nodeID: nodeID,
            adapterID: AdapterID("codex"),
            externalSessionID: "provider",
            project: ProjectReference(id: ProjectID(UUID()), name: "Fixture", rootURL: URL(fileURLWithPath: "/private/tmp/fixture")),
            terminalContext: nil,
            parentSessionID: nil,
            state: .discovered,
            startedAt: now,
            endedAt: nil,
            lastMeaningfulEventAt: now,
            snapshotRevision: 0
        )
        let payload: JSONValue
        switch kind {
        case .approval:
            let approval = ApprovalRequest(
                id: ApprovalRequestID(requestID),
                sessionID: sessionID,
                providerRequestID: "fixture",
                action: .executeCommand(ParsedCommand(
                    executable: URL(fileURLWithPath: "/usr/bin/swift"),
                    arguments: ["test"],
                    workingDirectory: session.project.rootURL
                )),
                risk: RiskAssessment(level: .medium, reasons: ["workspace-write"]),
                createdAt: now,
                expiresAt: expiresAt,
                revision: revision,
                status: .received
            )
            payload = (try? JSONValue.encoding(approval)) ?? .object([:])
        case .question:
            let question = AgentQuestion(
                id: QuestionID(requestID),
                sessionID: sessionID,
                kind: questionKind,
                prompt: "Choose",
                choices: questionKind == .singleChoice
                    ? [QuestionChoice(id: "a", label: "A"), QuestionChoice(id: "b", label: "B")]
                    : []
            )
            payload = (try? JSONValue.encoding(question)) ?? .object([:])
        case .plan:
            payload = .object(["title": .string("Review fixture plan")])
        }
        let envelope = EventEnvelope(
            eventID: EventID(UUID()),
            eventType: "session.stateChanged",
            source: EventSource(adapterID: AdapterID("codex"), adapterVersion: "1", nodeID: nodeID),
            sessionID: sessionID,
            sequence: 1,
            occurredAt: now,
            receivedAt: now,
            payload: payload,
            privacyClass: questionKind == .secret ? .secret : .sensitive,
            correlationID: EnvelopeID(UUID()),
            schemaHash: "fixture"
        )
        return HookDecisionRequest(
            requestID: requestID,
            revision: revision,
            kind: kind,
            prompt: "Approve fixture?",
            choices: kind == .question && questionKind == .singleChoice
                ? [QuestionChoice(id: "a", label: "A"), QuestionChoice(id: "b", label: "B")]
                : [],
            expiresAt: expiresAt,
            submission: HelperEventSubmission(envelope: envelope, initialSession: session)
        )
    }
}

// swiftlint:enable type_body_length

private actor FixtureUITransport: AgentControlTransport {
    private var online = true
    private var sessionItems: [SessionListItem]
    private var pending: [PendingHookDecision]
    private var decision: HookDecision?

    init(sessions: [SessionListItem], pending: [PendingHookDecision] = []) {
        sessionItems = sessions
        self.pending = pending
    }

    func setOnline(_ value: Bool) {
        online = value
    }

    func setSessions(_ value: [SessionListItem]) {
        sessionItems = value
    }

    func setPending(_ value: [PendingHookDecision]) {
        pending = value
    }

    func lastDecision() -> HookDecision? {
        decision
    }

    func snapshot(sessionLimit: Int) async throws -> AgentControlSnapshot {
        guard online else { throw LocalIPCError.unavailable }
        return AgentControlSnapshot(
            health: HelperHealth(
                protocolVersion: 1,
                processID: 1,
                uptimeSeconds: 10,
                activeSessionCount: sessionItems.count,
                persistedEventCount: sessionItems.count,
                spoolPendingCount: 0,
                pendingDecisionCount: pending.count,
                socketAcceptingConnections: true,
                databaseHealthy: true
            ),
            sessions: Array(sessionItems.prefix(sessionLimit)),
            pendingDecisions: pending
        )
    }

    func session(id _: SessionID) async throws -> AgentSession? {
        nil
    }

    func events(sessionID _: SessionID, limit _: Int) async throws -> [PersistedSessionEvent] {
        []
    }

    func resolve(_ resolution: HookDecisionResolution) async throws -> DecisionResolutionDisposition {
        decision = resolution.decision
        pending.removeAll { $0.requestID == resolution.requestID }
        return .accepted
    }

    func notifications() async -> AsyncStream<RegistryNotification> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}
}
