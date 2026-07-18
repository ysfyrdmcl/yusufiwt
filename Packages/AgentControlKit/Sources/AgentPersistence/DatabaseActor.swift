import AgentDomain
import AgentProtocol
import Foundation

/// Serializes all SQLite access away from UI executors and owns transaction boundaries.
public actor DatabaseActor {
    var connection: SQLiteConnection?
    let cipher: any SensitiveFieldCipher
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    public init(
        configuration: DatabaseConfiguration,
        cipher: any SensitiveFieldCipher = UnavailableSensitiveFieldCipher(),
        migrations: [DatabaseMigration] = AgentControlMigrations.all,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.cipher = cipher
        let sortedMigrations = migrations.sorted { $0.version < $1.version }
        if let url = configuration.url {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        let opened = try SQLiteConnection(url: configuration.url)
        connection = opened
        do {
            try Self.configure(opened, busyTimeoutMilliseconds: configuration.busyTimeoutMilliseconds)
            try Self.runMigrations(
                migrations: sortedMigrations,
                connection: opened,
                databaseURL: configuration.url,
                backupBeforeMigration: configuration.automaticBackupBeforeMigration,
                appliedAt: now()
            )
        } catch {
            opened.close()
            connection = nil
            throw error
        }
    }

    public func close() {
        connection?.close()
        connection = nil
    }

    public func append(_ write: EventWrite) throws -> EventAppendResult {
        try appendBatch([write]).first ?? .duplicate
    }

    /// Writes events and their materialized session snapshots in one SQLite transaction.
    public func appendBatch(_ writes: [EventWrite]) throws -> [EventAppendResult] {
        guard let connection else { throw PersistenceError.databaseClosed }
        return try connection.transaction {
            try writes.map { write in
                if try connection.scalarInt(
                    "SELECT 1 FROM session_events WHERE event_id = ? LIMIT 1",
                    bindings: [.text(write.envelope.eventID.description)]
                ) != nil {
                    return .duplicate
                }
                try upsertSupportRows(for: write, connection: connection)
                try insertEvent(write.envelope, connection: connection)
                return .appended
            }
        }
    }

    /// Deletes old event rows in a bounded transaction so foreground writes are not starved.
    @discardableResult
    public func runRetentionCleanup(eventsBefore cutoff: Date, batchSize: Int = 1000) throws -> Int {
        guard let connection else { throw PersistenceError.databaseClosed }
        let boundedBatch = max(1, min(batchSize, 10000))
        return try connection.transaction {
            try connection.execute(
                """
                DELETE FROM session_events WHERE event_id IN (
                    SELECT event_id FROM session_events
                    WHERE received_at < ? ORDER BY received_at ASC LIMIT ?
                )
                """,
                bindings: [.real(cutoff.timeIntervalSince1970), .integer(Int64(boundedBatch))]
            )
            return Int(connection.changes)
        }
    }

    public nonisolated func scheduleRetentionCleanup(
        eventsBefore cutoff: Date,
        batchSize: Int = 1000
    ) -> Task<Int, Error> {
        Task(priority: .utility) {
            try await self.runRetentionCleanup(eventsBefore: cutoff, batchSize: batchSize)
        }
    }

    public func appendAudit(_ entry: AuditEntry) throws {
        guard let connection else { throw PersistenceError.databaseClosed }
        try connection.execute(
            "INSERT INTO audit_log(id, category, action, target_id, metadata, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            bindings: [
                .text(entry.id.uuidString.lowercased()), .text(entry.category), .text(entry.action),
                entry.targetID.map(SQLiteValue.text) ?? .null,
                entry.metadata.map(SQLiteValue.blob) ?? .null,
                .real(entry.createdAt.timeIntervalSince1970)
            ]
        )
    }

    public func checkpoint() throws {
        guard let connection else { throw PersistenceError.databaseClosed }
        try connection.execute("PRAGMA wal_checkpoint(PASSIVE)")
    }

    public func createBackup(at destinationURL: URL) throws {
        guard let connection else { throw PersistenceError.databaseClosed }
        try connection.execute("PRAGMA wal_checkpoint(FULL)")
        try connection.backup(to: destinationURL)
    }

    public func integrityCheck() throws -> DatabaseHealth {
        guard let connection else { throw PersistenceError.databaseClosed }
        let results = try connection.query("PRAGMA integrity_check").compactMap { Self.string($0.first ?? .null) }
        return results == ["ok"] ? .healthy : .corrupt(details: results.joined(separator: "; "))
    }

    /// Opens a suspect database read-only and returns enough state to drive recovery UI.
    public static func inspectForRecovery(at url: URL) -> RecoveryReport {
        do {
            let readOnly = try SQLiteConnection(url: url, readOnly: true)
            defer { readOnly.close() }
            let results = try readOnly.query("PRAGMA integrity_check").compactMap { string($0.first ?? .null) }
            if results == ["ok"] {
                return RecoveryReport(health: .healthy, canOpenReadOnly: true, userFacingRecoveryRequired: false)
            }
            return RecoveryReport(
                health: .corrupt(details: results.joined(separator: "; ")),
                canOpenReadOnly: true,
                userFacingRecoveryRequired: true
            )
        } catch {
            return RecoveryReport(
                health: .unreadable(details: String(describing: error)),
                canOpenReadOnly: false,
                userFacingRecoveryRequired: true
            )
        }
    }

    /// Exports all readable pages without opening the source database for writes.
    public static func exportRecoverableDatabase(from sourceURL: URL, to destinationURL: URL) throws {
        let readOnly = try SQLiteConnection(url: sourceURL, readOnly: true)
        defer { readOnly.close() }
        try readOnly.backup(to: destinationURL)
    }
}
