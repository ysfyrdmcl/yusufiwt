import AgentDomain
import AgentPersistence
import AgentProtocol
import Foundation
import Testing

@Suite("SQLite event store", .serialized)
struct DatabaseActorTests {
    @Test("Event and snapshot commit atomically; duplicate is a no-op")
    func appendAndDeduplicate() async throws {
        let database = try DatabaseActor(configuration: .inMemory)
        let fixture = try Fixture()

        #expect(try await database.append(fixture.write(sequence: 1, revision: 1, state: .running)) == .appended)
        #expect(try await database.append(fixture.write(sequence: 1, revision: 99, state: .failed)) == .duplicate)
        #expect(try await database.eventCount() == 1)

        let session = try #require(try await database.session(id: fixture.sessionID))
        #expect(session.state == .running)
        #expect(session.snapshotRevision == 1)
        let events = try await database.events(sessionID: fixture.sessionID)
        #expect(events.count == 1)
        #expect(events[0].envelope.payload == .object(["state": .string("running")]))
        #expect(!events[0].wasEncrypted)
    }

    @Test("Different provider project IDs for one repository reuse the canonical project row")
    func canonicalProjectByPath() async throws {
        let database = try DatabaseActor(configuration: .inMemory)
        let first = try Fixture()
        let second = try Fixture(randomized: true)

        #expect(try await database.append(first.write(sequence: 1, revision: 1, state: .running)) == .appended)
        #expect(try await database.append(second.write(sequence: 1, revision: 1, state: .running)) == .appended)
        #expect(try await database.eventCount() == 2)
        #expect(try await database.session(id: first.sessionID) != nil)
        #expect(try await database.session(id: second.sessionID) != nil)
    }

    @Test("A failed batch rolls back every event and snapshot")
    func transactionRollback() async throws {
        let database = try DatabaseActor(configuration: .inMemory)
        let fixture = try Fixture()
        let first = fixture.write(sequence: 4, revision: 1, state: .running)
        let conflicting = fixture.write(sequence: 4, revision: 2, state: .completed, newEventID: true)

        await #expect(throws: (any Error).self) {
            try await database.appendBatch([first, conflicting])
        }
        #expect(try await database.eventCount() == 0)
        #expect(try await database.session(id: fixture.sessionID) == nil)
    }

    @Test("Committed WAL data survives close and reopen")
    func reopenCommittedDatabase() async throws {
        let location = try temporaryDatabaseURL()
        let fixture = try Fixture()
        let first = try DatabaseActor(configuration: DatabaseConfiguration(url: location))
        #expect(try await first.append(fixture.write(sequence: 1, revision: 1, state: .running)) == .appended)
        try await first.checkpoint()
        await first.close()

        let reopened = try DatabaseActor(configuration: DatabaseConfiguration(url: location))
        #expect(try await reopened.eventCount() == 1)
        #expect(try await reopened.session(id: fixture.sessionID)?.state == .running)
    }

    @Test("Usage metrics persist in the session snapshot and list read model")
    func usageSnapshotPersistence() async throws {
        let location = try temporaryDatabaseURL()
        let fixture = try Fixture()
        let usage = SessionUsageMetric(
            provider: AdapterID("codex"), kind: .quotaRemaining,
            remainingPercent: 73, source: "fixture", updatedAt: fixture.date
        )
        let database = try DatabaseActor(configuration: DatabaseConfiguration(url: location))
        #expect(try await database.append(fixture.write(
            sequence: 1, revision: 1, state: .running, usageMetrics: [usage]
        )) == .appended)
        try await database.checkpoint()
        await database.close()

        let reopened = try DatabaseActor(configuration: DatabaseConfiguration(url: location))
        #expect(try await reopened.session(id: fixture.sessionID)?.usageMetrics == [usage])
        #expect(try await reopened.sessions().first?.usageMetrics == [usage])
        await reopened.close()
    }

    @Test("Usage migration upgrades an existing version two database")
    func usageMigrationUpgrade() async throws {
        let location = try temporaryDatabaseURL()
        let old = try DatabaseActor(
            configuration: DatabaseConfiguration(url: location),
            migrations: [AgentControlMigrations.initialSchema, AgentControlMigrations.phase9Indexes]
        )
        await old.close()

        let migrated = try DatabaseActor(configuration: DatabaseConfiguration(url: location))
        let fixture = try Fixture()
        #expect(try await migrated.append(fixture.write(sequence: 1, revision: 1, state: .running)) == .appended)
        #expect(try await migrated.session(id: fixture.sessionID)?.usageMetrics == [])
        await migrated.close()
        #expect(FileManager.default.fileExists(atPath: location.appendingPathExtension("pre-migration-v3.backup").path))
    }

    @Test("MainActor callers open disk databases through a detached factory")
    @MainActor
    func detachedOpenFromMainActor() async throws {
        let location = try temporaryDatabaseURL()
        let database = try await DatabaseActor.open(configuration: DatabaseConfiguration(url: location))
        #expect(try await database.integrityCheck() == .healthy)
        await database.close()
    }

    @Test("Migration is idempotent and detects changed history")
    func migrations() async throws {
        let location = try temporaryDatabaseURL()
        let first = try DatabaseActor(configuration: DatabaseConfiguration(url: location))
        await first.close()
        let second = try DatabaseActor(configuration: DatabaseConfiguration(url: location))
        await second.close()

        let changed = DatabaseMigration(version: 1, name: "changed", statements: ["CREATE TABLE changed(id INTEGER)"])
        #expect(throws: PersistenceError.migrationChecksumMismatch(version: 1)) {
            _ = try DatabaseActor(configuration: DatabaseConfiguration(url: location), migrations: [changed])
        }
    }

    @Test("Migration sequence gaps fail before schema mutation")
    func migrationGap() throws {
        let gap = DatabaseMigration(version: 2, name: "gap", statements: ["CREATE TABLE gap(id INTEGER)"])
        #expect(throws: PersistenceError.migrationGap(expected: 1, found: 2)) {
            _ = try DatabaseActor(configuration: .inMemory, migrations: [gap])
        }
    }

    @Test("Sensitive payloads are encrypted and secret payloads are refused")
    func privacyStoragePolicy() async throws {
        let location = try temporaryDatabaseURL()
        let key = Data(repeating: 0x2A, count: 32)
        let database = try DatabaseActor(
            configuration: DatabaseConfiguration(url: location),
            cipher: AESGCMFieldCipher(keyData: key)
        )
        let fixture = try Fixture()
        let marker = "sensitive-marker-that-must-not-appear"
        let sensitive = fixture.write(sequence: 1, revision: 1, state: .running, privacy: .sensitive, marker: marker)
        #expect(try await database.append(sensitive) == .appended)
        let stored = try #require(try await database.events(sessionID: fixture.sessionID).first)
        #expect(stored.wasEncrypted)
        #expect(stored.envelope.payload == .object(["marker": .string(marker)]))

        let secret = fixture.write(sequence: 2, revision: 2, state: .running, privacy: .secret, marker: "secret")
        await #expect(throws: PersistenceError.secretPersistenceForbidden) {
            try await database.append(secret)
        }
        #expect(try await database.eventCount() == 1)
        try await database.checkpoint()
        await database.close()
        let bytes = try Data(contentsOf: location)
        #expect(!bytes.contains(Data(marker.utf8)))
    }

    @Test("Sensitive writes fail closed without a cipher")
    func sensitiveFailsClosed() async throws {
        let database = try DatabaseActor(configuration: .inMemory)
        let fixture = try Fixture()
        await #expect(throws: PersistenceError.encryptionUnavailable) {
            try await database.append(fixture.write(sequence: 1, revision: 1, state: .running, privacy: .sensitive))
        }
        #expect(try await database.eventCount() == 0)
    }

    @Test("Retention cleanup is bounded")
    func retention() async throws {
        let database = try DatabaseActor(configuration: .inMemory)
        let fixture = try Fixture()
        let writes = (1 ... 5).map { fixture.write(sequence: Int64($0), revision: Int64($0), state: .running) }
        #expect(try await database.appendBatch(writes).count == 5)
        #expect(try await database.runRetentionCleanup(eventsBefore: fixture.date.addingTimeInterval(10), batchSize: 2) == 2)
        #expect(try await database.eventCount() == 3)
    }

    @Test("SQLite safety pragmas are active")
    func runtimePragmas() async throws {
        let database = try DatabaseActor(configuration: DatabaseConfiguration(url: temporaryDatabaseURL(), busyTimeoutMilliseconds: 2500))
        let settings = try await database.runtimeSettings()
        #expect(settings == DatabaseRuntimeSettings(journalMode: "wal", foreignKeysEnabled: true, busyTimeoutMilliseconds: 2500))
        #expect(try await database.integrityCheck() == .healthy)
    }

    @Test("Backup is readable and integrity diagnostics classify corrupt files")
    func backupAndRecovery() async throws {
        let location = try temporaryDatabaseURL()
        let backup = location.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
        let fixture = try Fixture()
        let database = try DatabaseActor(configuration: DatabaseConfiguration(url: location))
        _ = try await database.append(fixture.write(sequence: 1, revision: 1, state: .running))
        try await database.createBackup(at: backup)
        let backupReport = DatabaseActor.inspectForRecovery(at: backup)
        #expect(backupReport.health == .healthy)

        let exported = location.deletingLastPathComponent().appendingPathComponent("export.sqlite")
        try DatabaseActor.exportRecoverableDatabase(from: backup, to: exported)
        #expect(DatabaseActor.inspectForRecovery(at: exported).health == .healthy)

        let corrupt = location.deletingLastPathComponent().appendingPathComponent("corrupt.sqlite")
        try Data("not a sqlite database".utf8).write(to: corrupt)
        let report = DatabaseActor.inspectForRecovery(at: corrupt)
        #expect(report.userFacingRecoveryRequired)
        #expect(report.health != .healthy)
    }

    @Test("Pending migration checkpoints and creates a pre-migration backup")
    func migrationBackup() async throws {
        let location = try temporaryDatabaseURL()
        let first = try DatabaseActor(
            configuration: DatabaseConfiguration(url: location),
            migrations: [AgentControlMigrations.initialSchema]
        )
        await first.close()
        let secondMigration = DatabaseMigration(
            version: 2,
            name: "test_addition",
            statements: ["CREATE TABLE migration_test(id INTEGER PRIMARY KEY) STRICT"]
        )
        let migrated = try DatabaseActor(
            configuration: DatabaseConfiguration(url: location),
            migrations: [AgentControlMigrations.initialSchema, secondMigration]
        )
        await migrated.close()
        let backup = location.appendingPathExtension("pre-migration-v2.backup")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(DatabaseActor.inspectForRecovery(at: backup).health == .healthy)
    }

    @Test("Audit entries can only be appended through the public API")
    func auditLog() async throws {
        let database = try DatabaseActor(configuration: .inMemory)
        let entry = AuditEntry(
            id: UUID(), category: "approval", action: "requested", targetID: "request-1",
            metadata: Data("safe".utf8), createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await database.appendAudit(entry)
        #expect(try await database.auditEntries() == [entry])
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("agent-control.sqlite")
    }
}

private struct Fixture: Sendable {
    let nodeID: NodeID
    let projectID: ProjectID
    let sessionID: SessionID
    let baseEventID: EventID
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    init(randomized: Bool = false) throws {
        if randomized {
            nodeID = NodeID(UUID())
            projectID = ProjectID(UUID())
            sessionID = SessionID(UUID())
            baseEventID = EventID(UUID())
            return
        }
        nodeID = try NodeID(#require(UUID(uuidString: "11111111-1111-1111-1111-111111111111")))
        projectID = try ProjectID(#require(UUID(uuidString: "22222222-2222-2222-2222-222222222222")))
        sessionID = try SessionID(#require(UUID(uuidString: "33333333-3333-3333-3333-333333333333")))
        baseEventID = try EventID(#require(UUID(uuidString: "44444444-4444-4444-4444-444444444444")))
    }

    func write(
        sequence: Int64,
        revision: Int64,
        state: SessionState,
        newEventID: Bool = false,
        privacy: PrivacyClass = .privateMetadata,
        marker: String? = nil,
        usageMetrics: [SessionUsageMetric] = []
    ) -> EventWrite {
        let eventID = newEventID || sequence != 1 ? EventID(UUID()) : baseEventID
        let payload: JSONValue = marker.map { .object(["marker": .string($0)]) }
            ?? .object(["state": .string(state.rawValue)])
        let envelope = EventEnvelope(
            eventID: eventID, eventType: "session.stateChanged",
            source: EventSource(adapterID: AdapterID("codex"), adapterVersion: "1.0", nodeID: nodeID, processID: 42),
            sessionID: sessionID, providerSessionID: "provider-session", sequence: sequence,
            occurredAt: date.addingTimeInterval(Double(sequence)), receivedAt: date.addingTimeInterval(Double(sequence)),
            payload: payload, privacyClass: privacy, correlationID: EnvelopeID(UUID()), schemaHash: "sha256:test"
        )
        let session = AgentSession(
            id: sessionID, nodeID: nodeID, adapterID: AdapterID("codex"), externalSessionID: "provider-session",
            project: ProjectReference(id: projectID, name: "AgentControl", rootURL: URL(fileURLWithPath: "/Users/example/AgentControl")),
            terminalContext: nil, parentSessionID: nil, state: state, startedAt: date, endedAt: state.isTerminal ? date : nil,
            lastMeaningfulEventAt: date.addingTimeInterval(Double(sequence)), snapshotRevision: revision,
            usageMetrics: usageMetrics
        )
        return EventWrite(envelope: envelope, snapshot: session)
    }
}
