import AgentProtocol
import Foundation

extension DatabaseActor {
    static func configure(_ connection: SQLiteConnection, busyTimeoutMilliseconds: Int) throws {
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.execute("PRAGMA synchronous = FULL")
        try connection.execute("PRAGMA busy_timeout = \(max(0, busyTimeoutMilliseconds))")
        try connection.execute("PRAGMA wal_autocheckpoint = 1000")
        guard try connection.scalarInt("PRAGMA foreign_keys") == 1 else {
            throw PersistenceError.invalidStoredValue("foreign_keys pragma")
        }
    }

    static func runMigrations(
        migrations: [DatabaseMigration],
        connection: SQLiteConnection,
        databaseURL: URL?,
        backupBeforeMigration: Bool,
        appliedAt: Date
    ) throws {
        try validateMigrationSequence(migrations)
        let hasMigrationTable = try connection.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations'"
        ) == 1
        let appliedRows = hasMigrationTable
            ? try connection.query("SELECT version, checksum FROM schema_migrations ORDER BY version")
            : []
        try validateAppliedMigrations(appliedRows, against: migrations)
        let appliedVersions = Set(appliedRows.compactMap { int($0[0]).map(Int.init) })
        let pending = migrations.filter { !appliedVersions.contains($0.version) }
        guard !pending.isEmpty else { return }

        try backupBeforePendingMigration(
            pending,
            hasMigrationTable: hasMigrationTable,
            enabled: backupBeforeMigration,
            databaseURL: databaseURL,
            connection: connection
        )
        for migration in pending {
            try apply(migration, at: appliedAt, connection: connection)
        }
    }

    private static func validateMigrationSequence(_ migrations: [DatabaseMigration]) throws {
        for (offset, migration) in migrations.enumerated() where migration.version != offset + 1 {
            throw PersistenceError.migrationGap(expected: offset + 1, found: migration.version)
        }
    }

    private static func validateAppliedMigrations(
        _ appliedRows: [[SQLiteValue]],
        against migrations: [DatabaseMigration]
    ) throws {
        for row in appliedRows {
            guard let version = int(row[0]), let checksum = string(row[1]),
                  let migration = migrations.first(where: { $0.version == Int(version) })
            else { throw PersistenceError.invalidStoredValue("schema_migrations row") }
            guard migration.checksum == checksum else {
                throw PersistenceError.migrationChecksumMismatch(version: Int(version))
            }
        }
    }

    private static func backupBeforePendingMigration(
        _ pending: [DatabaseMigration],
        hasMigrationTable: Bool,
        enabled: Bool,
        databaseURL: URL?,
        connection: SQLiteConnection
    ) throws {
        guard hasMigrationTable, enabled, let databaseURL else { return }
        try connection.execute("PRAGMA wal_checkpoint(FULL)")
        let backupURL = databaseURL.appendingPathExtension("pre-migration-v\(pending[0].version).backup")
        try? FileManager.default.removeItem(at: backupURL)
        try connection.backup(to: backupURL)
    }

    private static func apply(
        _ migration: DatabaseMigration,
        at appliedAt: Date,
        connection: SQLiteConnection
    ) throws {
        try connection.transaction {
            for statement in migration.statements {
                try connection.execute(statement)
            }
            try connection.execute(
                "INSERT INTO schema_migrations(version, name, applied_at, checksum) VALUES (?, ?, ?, ?)",
                bindings: [
                    .integer(Int64(migration.version)), .text(migration.name),
                    .real(appliedAt.timeIntervalSince1970), .text(migration.checksum)
                ]
            )
        }
    }

    static func sourceKey(_ envelope: EventEnvelope) -> String {
        "\(envelope.source.adapterID.rawValue)|\(envelope.source.nodeID.description)|\(envelope.source.processID.map(String.init) ?? "-")"
    }

    static func string(_ value: SQLiteValue) -> String? {
        if case let .text(value) = value {
            return value
        }
        return nil
    }

    static func int(_ value: SQLiteValue) -> Int64? {
        if case let .integer(value) = value {
            return value
        }
        return nil
    }

    static func double(_ value: SQLiteValue) -> Double? {
        switch value {
        case let .real(value):
            value
        case let .integer(value):
            Double(value)
        default:
            nil
        }
    }

    static func data(_ value: SQLiteValue) -> Data? {
        if case let .blob(value) = value {
            return value
        }
        return nil
    }

    static func uuid(_ value: SQLiteValue) -> UUID? {
        string(value).flatMap(UUID.init(uuidString:))
    }
}
