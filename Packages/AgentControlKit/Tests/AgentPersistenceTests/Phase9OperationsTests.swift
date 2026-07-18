import AgentDomain
import AgentPersistence
import AgentProtocol
import Foundation
import Testing

@Suite("Phase 9 persistence operations", .serialized)
struct Phase9OperationsTests {
    @Test("History search, analytics, and completed-data deletion are end to end")
    func historyAnalyticsDeletion() async throws {
        let database = try DatabaseActor(configuration: .inMemory)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let alpha = fixture(name: "Alpha % Project", adapter: "codex", state: .completed, start: start, eventType: "approval.requested")
        let beta = fixture(name: "Beta", adapter: "claude", state: .failed, start: start.addingTimeInterval(86400), eventType: "session.stateChanged")
        _ = try await database.append(alpha)
        _ = try await database.append(beta)

        let literalSearch = try await database.history(HistoryQuery(searchText: "%", states: [.completed]))
        #expect(literalSearch.items.map(\.projectName) == ["Alpha % Project"])
        let analytics = try await database.analytics(AnalyticsQuery(
            from: start.addingTimeInterval(-1), endDate: start.addingTimeInterval(172_800)
        ))
        #expect(analytics.totalSessions == 2)
        #expect(analytics.completedSessions == 1)
        #expect(analytics.failedSessions == 1)
        #expect(analytics.approvalRequests == 1)
        #expect(analytics.buckets.count == 2)

        let deletion = try await database.deleteCompletedHistory(endedBefore: start.addingTimeInterval(200_000))
        #expect(deletion == DataDeletionResult(deletedSessions: 2, deletedEvents: 2))
        #expect(try await database.eventCount() == 0)
        #expect(try await database.history(HistoryQuery()).totalCount == 0)
    }

    @Test("Rules and privacy settings round trip with safe defaults")
    func rulesAndPrivacy() async throws {
        let database = try DatabaseActor(configuration: .inMemory)
        #expect(try await database.privacySettings() == .privacyFirst)
        let alert = AlertRule(name: "Idle", kind: .idle, thresholdSeconds: 60)
        let automation = LowRiskAutomationRule(name: "Reads", actionKinds: [.readFile])
        try await database.upsertRule(.alert(alert))
        try await database.upsertRule(.automation(automation))
        #expect(try await Set(database.rules().map(\.id)) == [alert.id, automation.id])
        #expect(try await database.deleteRule(id: alert.id))
        #expect(try await database.rules().map(\.id) == [automation.id])

        let settings = PrivacySettings(
            analyticsEnabled: false, retentionDays: 90,
            includePrivateMetadataInDiagnostics: true,
            storePromptContent: false, storeTerminalOutput: false
        )
        try await database.savePrivacySettings(settings, at: Date(timeIntervalSince1970: 1))
        #expect(try await database.privacySettings() == settings)
    }

    @Test("Privacy settings redact prompt and terminal output before persistence")
    func payloadPrivacyFiltering() async throws {
        let database = try DatabaseActor(configuration: .inMemory)
        let write = fixture(
            name: "Privacy", adapter: "codex", state: .completed,
            start: Date(timeIntervalSince1970: 1_700_000_000), eventType: "fixture.private"
        )
        let privateEnvelope = EventEnvelope(
            eventID: write.envelope.eventID, eventType: write.envelope.eventType,
            source: write.envelope.source, sessionID: write.envelope.sessionID,
            sequence: write.envelope.sequence, occurredAt: write.envelope.occurredAt,
            receivedAt: write.envelope.receivedAt,
            payload: .object([
                "prompt": .string("do not store prompt"),
                "nested": .object(["stdout": .string("do not store output")]),
                "safeSummary": .string("kept")
            ]),
            privacyClass: .publicMetadata, correlationID: write.envelope.correlationID,
            schemaHash: write.envelope.schemaHash
        )
        _ = try await database.append(EventWrite(envelope: privateEnvelope, snapshot: write.snapshot))
        let payload = try #require(try await database.events(sessionID: write.snapshot.id).first?.envelope.payload)
        #expect(payload["prompt"]?.stringValue == "[redacted by privacy setting]")
        #expect(payload["nested"]?["stdout"]?.stringValue == "[redacted by privacy setting]")
        #expect(payload["safeSummary"]?.stringValue == "kept")
    }

    @Test("Diagnostic export omits secret fixtures and redacts credentials")
    func diagnosticRedaction() async throws {
        let database = try DatabaseActor(configuration: .inMemory)
        let report = try await database.diagnostics(at: Date(timeIntervalSince1970: 1))
        let data = try RedactedDiagnosticExporter.export(
            report: report,
            attachments: [
                DiagnosticAttachment(name: "secret", content: "TOPSECRET_12345", privacyClass: .secret),
                DiagnosticAttachment(name: "log", content: "authorization=abc123 /Users/alice/work", privacyClass: .publicMetadata)
            ],
            includePrivateMetadata: true
        )
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("TOPSECRET_12345"))
        #expect(!text.contains("abc123"))
        #expect(!text.contains("/Users/alice"))
        #expect(text.contains("[redacted"))
    }

    private func fixture(
        name: String,
        adapter: String,
        state: SessionState,
        start: Date,
        eventType: String
    ) -> EventWrite {
        let nodeID = NodeID(UUID()), projectID = ProjectID(UUID()), sessionID = SessionID(UUID())
        let end = start.addingTimeInterval(120)
        let session = AgentSession(
            id: sessionID, nodeID: nodeID, adapterID: AdapterID(adapter), externalSessionID: nil,
            project: ProjectReference(id: projectID, name: name, rootURL: URL(fileURLWithPath: "/tmp/\(projectID.description)")),
            terminalContext: nil, parentSessionID: nil, state: state, startedAt: start,
            endedAt: end, lastMeaningfulEventAt: end, snapshotRevision: 1
        )
        return EventWrite(
            envelope: EventEnvelope(
                eventID: EventID(UUID()), eventType: eventType,
                source: EventSource(adapterID: AdapterID(adapter), adapterVersion: "1", nodeID: nodeID),
                sessionID: sessionID, sequence: 1, occurredAt: start, receivedAt: start,
                payload: .object([:]), privacyClass: .publicMetadata,
                correlationID: EnvelopeID(UUID()), schemaHash: "phase9"
            ),
            snapshot: session
        )
    }
}
