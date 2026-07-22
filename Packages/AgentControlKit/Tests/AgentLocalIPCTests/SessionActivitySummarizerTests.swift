#if os(macOS)
    import AgentDomain
    import AgentLocalIPC
    import AgentPersistence
    import AgentProtocol
    import Foundation
    import Testing

    @Suite("Session activity summaries")
    struct SessionActivitySummarizerTests {
        @Test("Structured event kinds produce deterministic summaries")
        func eventKinds() {
            let summary = SessionActivitySummarizer().summary(for: envelope(
                type: "plan.updated", payload: .object([:]), privacy: .privateMetadata
            ))
            #expect(summary.kind == .planning)
            #expect(summary.detail == nil)
        }

        @Test("Sensitive and secret payload details never reach the summary")
        func privateDetailsAreRedacted() {
            for privacy in [PrivacyClass.sensitive, .secret] {
                let summary = SessionActivitySummarizer().summary(for: envelope(
                    type: "tool.started",
                    payload: .object(["safe_summary": .string("do not expose this")]),
                    privacy: privacy
                ))
                #expect(summary.kind == .usingTool)
                #expect(summary.detail == nil)
            }
        }

        @Test("Unknown structured activity is persisted in the session list snapshot")
        func persistedSummary() async throws {
            let now = Date(timeIntervalSince1970: 1_784_544_400)
            let sessionID = SessionID(UUID())
            let nodeID = NodeID(UUID())
            let database = try DatabaseActor(configuration: .inMemory)
            let registry = SessionRegistryActor(database: database)
            let event = EventEnvelope(
                eventID: EventID(UUID()), eventType: "tool.started",
                source: EventSource(adapterID: AdapterID("codex"), adapterVersion: "1", nodeID: nodeID),
                sessionID: sessionID, sequence: 1, occurredAt: now, receivedAt: now,
                payload: .object([:]), privacyClass: .privateMetadata,
                correlationID: EnvelopeID(UUID()), schemaHash: "test"
            )
            let session = AgentSession(
                id: sessionID, nodeID: nodeID, adapterID: AdapterID("codex"), externalSessionID: "thread",
                project: ProjectReference(id: ProjectID(UUID()), name: "Project", rootURL: URL(fileURLWithPath: "/tmp/project")),
                terminalContext: nil, parentSessionID: nil, state: .running, startedAt: now,
                endedAt: nil, lastMeaningfulEventAt: now, snapshotRevision: 1
            )
            #expect(try await registry.ingest(.init(envelope: event, initialSession: session)) == .recordedWithoutStateChange)
            #expect(try await database.sessions().first?.activitySummary?.kind == .usingTool)
            await database.close()
        }

        private func envelope(type: String, payload: JSONValue, privacy: PrivacyClass) -> EventEnvelope {
            let now = Date(timeIntervalSince1970: 1_784_544_400)
            return EventEnvelope(
                eventID: EventID(UUID()), eventType: type,
                source: EventSource(adapterID: AdapterID("codex"), adapterVersion: "1", nodeID: NodeID(UUID())),
                sessionID: SessionID(UUID()), sequence: 1, occurredAt: now, receivedAt: now,
                payload: payload, privacyClass: privacy, correlationID: EnvelopeID(UUID()), schemaHash: "test"
            )
        }
    }
#endif
