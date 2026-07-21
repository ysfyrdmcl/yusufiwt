import AgentDomain
import AgentLocalIPC
import AgentPersistence
import AgentProtocol
import Foundation
import Testing

struct LocalIPCFixture: Sendable {
    let nodeID: NodeID
    let projectID: ProjectID
    let sessionID: SessionID
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        nodeID = try NodeID(#require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")))
        projectID = try ProjectID(#require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")))
        sessionID = try SessionID(#require(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")))
    }

    func submission(sequence: Int64 = 1, state: SessionState = .running) -> HelperEventSubmission {
        let envelope = EventEnvelope(
            eventID: EventID(UUID()),
            eventType: "session.stateChanged",
            source: EventSource(adapterID: AdapterID("test"), adapterVersion: "1", nodeID: nodeID),
            sessionID: sessionID,
            sequence: sequence,
            occurredAt: date.addingTimeInterval(Double(sequence)),
            receivedAt: date.addingTimeInterval(Double(sequence)),
            payload: .object(["state": .string(state.rawValue)]),
            privacyClass: .privateMetadata,
            correlationID: EnvelopeID(UUID()),
            schemaHash: "test"
        )
        let initial = AgentSession(
            id: sessionID,
            nodeID: nodeID,
            adapterID: AdapterID("test"),
            externalSessionID: nil,
            project: ProjectReference(id: projectID, name: "Test", rootURL: URL(fileURLWithPath: "/tmp/Test")),
            terminalContext: nil,
            parentSessionID: nil,
            state: .discovered,
            startedAt: date,
            endedAt: nil,
            lastMeaningfulEventAt: date,
            snapshotRevision: 0
        )
        return HelperEventSubmission(envelope: envelope, initialSession: initial)
    }

    func usageSubmission(sequence: Int64, remainingPercent: Double) throws -> HelperEventSubmission {
        let metric = SessionUsageMetric(
            provider: AdapterID("test"),
            kind: .quotaRemaining,
            remainingPercent: remainingPercent,
            source: "fixture",
            updatedAt: date.addingTimeInterval(Double(sequence))
        )
        let update = SessionUsageUpdate(metrics: [metric], concurrentState: .running)
        let envelope = try EventEnvelope(
            eventID: EventID(UUID()),
            eventType: "session.usageUpdated",
            source: EventSource(adapterID: AdapterID("test"), adapterVersion: "1", nodeID: nodeID),
            sessionID: sessionID,
            sequence: sequence,
            occurredAt: date.addingTimeInterval(Double(sequence)),
            receivedAt: date.addingTimeInterval(Double(sequence)),
            payload: JSONValue.encoding(update),
            privacyClass: .publicMetadata,
            correlationID: EnvelopeID(UUID()),
            schemaHash: "test"
        )
        let initial = AgentSession(
            id: sessionID,
            nodeID: nodeID,
            adapterID: AdapterID("test"),
            externalSessionID: nil,
            project: ProjectReference(id: projectID, name: "Test", rootURL: URL(fileURLWithPath: "/tmp/Test")),
            terminalContext: nil,
            parentSessionID: nil,
            state: .discovered,
            startedAt: date,
            endedAt: nil,
            lastMeaningfulEventAt: date,
            snapshotRevision: 0
        )
        return HelperEventSubmission(envelope: envelope, initialSession: initial)
    }
}

func temporaryPaths() throws -> AgentControlPaths {
    let directory = URL(fileURLWithPath: "/private/tmp/acipc-\(UUID().uuidString)", isDirectory: true)
    return AgentControlPaths(baseDirectory: directory)
}

func makeTestRuntime(
    paths: AgentControlPaths,
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_100) }
) async throws -> TestRuntimeStack {
    try paths.prepare()
    let cipher = try AESGCMFieldCipher(keyData: Data(repeating: 7, count: 32))
    let database = try DatabaseActor(configuration: DatabaseConfiguration(url: paths.databaseURL), cipher: cipher)
    let registry = SessionRegistryActor(database: database)
    _ = try await registry.restoreActiveSnapshots()
    let spool = HookSpool(directory: paths.spoolDirectory)
    try await spool.prepare()
    let runtime = HelperRuntime(database: database, registry: registry, spool: spool, paths: paths, now: now)
    return TestRuntimeStack(database: database, registry: registry, spool: spool, runtime: runtime)
}

struct TestRuntimeStack {
    let database: DatabaseActor
    let registry: SessionRegistryActor
    let spool: HookSpool
    let runtime: HelperRuntime
}
