import AgentDomain
import AgentPersistence
import AgentProtocol
import Foundation
import Testing

@Suite("Persistence performance fixtures")
struct PerformanceFixtureTests {
    @Test("100k event fixture")
    func hundredThousandEvents() async throws {
        guard ProcessInfo.processInfo.environment["AGENTCONTROL_RUN_PERFORMANCE_TESTS"] == "1" else { return }
        let database = try DatabaseActor(configuration: .inMemory)
        let node = NodeID(UUID()), project = ProjectID(UUID())
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sessions = (0 ..< 100).map { index in
            AgentSession(
                id: SessionID(UUID()), nodeID: node, adapterID: AdapterID("fixture"), externalSessionID: nil,
                project: ProjectReference(
                    id: project, name: "Performance \(index)", rootURL: URL(fileURLWithPath: "/fixture/\(index)")
                ),
                terminalContext: nil, parentSessionID: nil, state: .running, startedAt: start, endedAt: nil,
                lastMeaningfulEventAt: start, snapshotRevision: 1
            )
        }
        let source = EventSource(adapterID: AdapterID("fixture"), adapterVersion: "1", nodeID: node)
        let ingestionStarted = Date()
        for batchStart in stride(from: 0, to: 100_000, by: 1000) {
            let writes = (batchStart ..< batchStart + 1000).map { index in
                let session = sessions[index % sessions.count]
                return EventWrite(
                    envelope: EventEnvelope(
                        eventID: EventID(UUID()), eventType: "fixture.event", source: source, sessionID: session.id,
                        sequence: Int64(index), occurredAt: start, receivedAt: start, payload: .object([:]),
                        privacyClass: .publicMetadata, correlationID: EnvelopeID(UUID()), schemaHash: "fixture"
                    ),
                    snapshot: session
                )
            }
            _ = try await database.appendBatch(writes)
        }
        let ingestionDuration = Date().timeIntervalSince(ingestionStarted)
        #expect(try await database.eventCount() == 100_000)
        let queryStarted = Date()
        let summary = try await database.analytics(AnalyticsQuery(
            from: start.addingTimeInterval(-1), endDate: start.addingTimeInterval(1)
        ))
        let queryDuration = Date().timeIntervalSince(queryStarted)
        #expect(summary.totalSessions == 100)
        #expect(ingestionDuration < 120, "100-session/100k-event ingestion exceeded the 120-second release budget")
        #expect(queryDuration < 2.0, "100k analytics query exceeded the two-second release-test budget")
    }
}
