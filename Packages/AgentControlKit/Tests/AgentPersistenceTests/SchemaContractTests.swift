@testable import AgentPersistence
import Foundation
import Testing

@Suite("Persistence schema contract", .serialized)
struct SchemaContractTests {
    @Test("Initial schema contains every planned table, index, and valid foreign key")
    func schemaObjects() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaContractTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("schema.sqlite")
        let actor = try DatabaseActor(configuration: DatabaseConfiguration(url: url))
        await actor.close()

        let connection = try SQLiteConnection(url: url, readOnly: true)
        defer { connection.close() }
        let tables = try Set(connection.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).compactMap { row -> String? in
            guard case let .text(value) = row[0] else { return nil }
            return value
        })
        let requiredTables: Set = [
            "schema_migrations", "nodes", "projects", "agent_sessions", "session_events", "turns", "tool_runs",
            "approval_requests", "approval_decisions", "questions", "terminal_contexts", "integration_installations",
            "rules", "notification_deliveries", "paired_devices", "sync_outbox", "replay_nonces", "audit_log",
            "settings", "diagnostic_incidents"
        ]
        #expect(requiredTables.isSubset(of: tables))
        #expect(try connection.query("PRAGMA foreign_key_check").isEmpty)

        let indexes = try Set(connection.query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'"
        ).compactMap { row -> String? in
            guard case let .text(value) = row[0] else { return nil }
            return value
        })
        #expect(indexes.contains("idx_events_session_sequence"))
        #expect(indexes.contains("idx_sessions_state_activity"))
        #expect(indexes.contains("idx_approvals_pending"))

        let sessionColumns = try Set(connection.query("PRAGMA table_info(agent_sessions)").compactMap { row -> String? in
            guard row.count > 1, case let .text(value) = row[1] else { return nil }
            return value
        })
        #expect(sessionColumns.contains("usage_metrics"))
    }

    @Test("Database-level triggers keep audit history append-only")
    func auditTriggers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditTriggerTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("audit.sqlite")
        let actor = try DatabaseActor(configuration: DatabaseConfiguration(url: url))
        try await actor.appendAudit(AuditEntry(id: UUID(), category: "test", action: "append", createdAt: Date()))
        await actor.close()

        let connection = try SQLiteConnection(url: url)
        defer { connection.close() }
        #expect(throws: (any Error).self) {
            try connection.execute("UPDATE audit_log SET action = 'changed'")
        }
        #expect(throws: (any Error).self) {
            try connection.execute("DELETE FROM audit_log")
        }
    }
}
