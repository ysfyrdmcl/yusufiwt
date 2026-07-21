import CryptoKit
import Foundation

public struct DatabaseMigration: Sendable, Equatable {
    public let version: Int
    public let name: String
    public let statements: [String]

    public init(version: Int, name: String, statements: [String]) {
        self.version = version
        self.name = name
        self.statements = statements
    }

    public var checksum: String {
        let input = "\(version)\u{0}\(name)\u{0}\(statements.joined(separator: "\u{0}"))"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum AgentControlMigrations {
    public static let all: [DatabaseMigration] = [initialSchema, phase9Indexes, sessionUsageSnapshot]

    public static let initialSchema = DatabaseMigration(
        version: 1,
        name: "initial_event_store",
        statements: [
            """
            CREATE TABLE schema_migrations (
                version INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                applied_at REAL NOT NULL,
                checksum TEXT NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE nodes (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                platform TEXT NOT NULL,
                os_version TEXT,
                app_version TEXT,
                public_key BLOB,
                trust_state TEXT NOT NULL DEFAULT 'local',
                last_seen_at REAL,
                revoked_at REAL
            ) STRICT
            """,
            """
            CREATE TABLE projects (
                id TEXT PRIMARY KEY,
                stable_path_hash TEXT NOT NULL UNIQUE,
                display_name TEXT NOT NULL,
                redacted_path TEXT,
                repository_identity TEXT,
                created_at REAL NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE terminal_contexts (
                id TEXT PRIMARY KEY,
                application_bundle_id TEXT NOT NULL,
                process_id INTEGER,
                window_identifier TEXT,
                tab_identifier TEXT,
                pane_identifier TEXT,
                workspace_uri TEXT,
                correlation_token TEXT NOT NULL,
                captured_at REAL NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE agent_sessions (
                id TEXT PRIMARY KEY,
                provider_session_id TEXT,
                adapter_id TEXT NOT NULL,
                adapter_version TEXT,
                node_id TEXT NOT NULL REFERENCES nodes(id),
                project_id TEXT NOT NULL REFERENCES projects(id),
                parent_session_id TEXT REFERENCES agent_sessions(id),
                state TEXT NOT NULL,
                attention_state TEXT,
                started_at REAL NOT NULL,
                ended_at REAL,
                last_meaningful_event_at REAL NOT NULL,
                snapshot_revision INTEGER NOT NULL CHECK(snapshot_revision >= 0),
                terminal_context_id TEXT REFERENCES terminal_contexts(id)
            ) STRICT
            """,
            """
            CREATE TABLE session_events (
                event_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
                source_key TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                event_type TEXT NOT NULL,
                occurred_at REAL NOT NULL,
                received_at REAL NOT NULL,
                privacy_class TEXT NOT NULL,
                payload BLOB NOT NULL,
                payload_encoding TEXT NOT NULL CHECK(payload_encoding IN ('json', 'aes-gcm')),
                envelope_metadata BLOB NOT NULL,
                schema_hash TEXT NOT NULL,
                UNIQUE(session_id, source_key, sequence)
            ) STRICT
            """,
            """
            CREATE TABLE turns (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
                provider_turn_id TEXT,
                state TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL,
                safe_summary TEXT
            ) STRICT
            """,
            """
            CREATE TABLE tool_runs (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
                turn_id TEXT REFERENCES turns(id) ON DELETE SET NULL,
                tool_name TEXT NOT NULL,
                safe_action_summary TEXT,
                state TEXT NOT NULL,
                started_at REAL,
                ended_at REAL,
                risk_level TEXT
            ) STRICT
            """,
            """
            CREATE TABLE approval_requests (
                id TEXT PRIMARY KEY,
                provider_request_id TEXT NOT NULL,
                session_id TEXT NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
                type TEXT NOT NULL,
                risk_level TEXT NOT NULL,
                risk_reasons BLOB NOT NULL,
                action_summary TEXT NOT NULL,
                revision INTEGER NOT NULL,
                status TEXT NOT NULL,
                created_at REAL NOT NULL,
                expires_at REAL,
                UNIQUE(session_id, provider_request_id, revision)
            ) STRICT
            """,
            """
            CREATE TABLE approval_decisions (
                id TEXT PRIMARY KEY,
                request_id TEXT NOT NULL REFERENCES approval_requests(id) ON DELETE CASCADE,
                actor_device_id TEXT REFERENCES paired_devices(id),
                decision TEXT NOT NULL,
                signature BLOB,
                policy_result TEXT NOT NULL,
                sent_at REAL,
                applied_at REAL,
                provider_ack BLOB
            ) STRICT
            """,
            """
            CREATE TABLE questions (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
                type TEXT NOT NULL,
                prompt_summary TEXT NOT NULL,
                options_json BLOB,
                response BLOB,
                response_encoding TEXT,
                status TEXT NOT NULL,
                created_at REAL NOT NULL,
                expires_at REAL
            ) STRICT
            """,
            """
            CREATE TABLE integration_installations (
                id TEXT PRIMARY KEY, adapter_id TEXT NOT NULL, version TEXT,
                status TEXT NOT NULL, config_path TEXT, updated_at REAL NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
                predicate_json BLOB NOT NULL, action_json BLOB NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE notification_deliveries (
                id TEXT PRIMARY KEY, event_id TEXT REFERENCES session_events(event_id) ON DELETE SET NULL,
                channel TEXT NOT NULL, status TEXT NOT NULL, attempted_at REAL NOT NULL, delivered_at REAL, error_code TEXT
            ) STRICT
            """,
            """
            CREATE TABLE paired_devices (
                id TEXT PRIMARY KEY, display_name TEXT NOT NULL, public_key BLOB NOT NULL,
                trust_state TEXT NOT NULL, paired_at REAL NOT NULL, last_seen_at REAL, revoked_at REAL
            ) STRICT
            """,
            """
            CREATE TABLE sync_outbox (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, encrypted_envelope BLOB NOT NULL,
                created_at REAL NOT NULL, expires_at REAL NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0, next_attempt_at REAL
            ) STRICT
            """,
            """
            CREATE TABLE replay_nonces (
                nonce BLOB PRIMARY KEY, device_id TEXT NOT NULL, observed_at REAL NOT NULL, expires_at REAL NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE audit_log (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                category TEXT NOT NULL,
                action TEXT NOT NULL,
                target_id TEXT,
                metadata BLOB,
                created_at REAL NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE settings (
                key TEXT PRIMARY KEY, value BLOB NOT NULL, privacy_class TEXT NOT NULL, updated_at REAL NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE diagnostic_incidents (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, severity TEXT NOT NULL,
                safe_details TEXT NOT NULL, opened_at REAL NOT NULL, resolved_at REAL
            ) STRICT
            """,
            "CREATE INDEX idx_sessions_state_activity ON agent_sessions(state, last_meaningful_event_at DESC)",
            "CREATE INDEX idx_sessions_project ON agent_sessions(project_id, last_meaningful_event_at DESC)",
            "CREATE INDEX idx_events_session_sequence ON session_events(session_id, source_key, sequence)",
            "CREATE INDEX idx_events_received ON session_events(received_at)",
            "CREATE INDEX idx_approvals_pending ON approval_requests(status, expires_at)",
            "CREATE INDEX idx_questions_pending ON questions(status, expires_at)",
            "CREATE INDEX idx_outbox_delivery ON sync_outbox(next_attempt_at, expires_at)",
            "CREATE INDEX idx_nonces_expiry ON replay_nonces(expires_at)",
            "CREATE INDEX idx_audit_created ON audit_log(created_at DESC)",
            "CREATE TRIGGER audit_log_no_update BEFORE UPDATE ON audit_log BEGIN SELECT RAISE(ABORT, 'audit_log is append-only'); END",
            "CREATE TRIGGER audit_log_no_delete BEFORE DELETE ON audit_log BEGIN SELECT RAISE(ABORT, 'audit_log is append-only'); END"
        ]
    )

    public static let phase9Indexes = DatabaseMigration(
        version: 2,
        name: "phase9_history_analytics_indexes",
        statements: [
            "CREATE INDEX idx_sessions_history ON agent_sessions(started_at DESC, adapter_id, state)",
            "CREATE INDEX idx_events_type_received ON session_events(event_type, received_at)",
            "CREATE INDEX idx_rules_enabled_updated ON rules(enabled, updated_at DESC)",
            "CREATE INDEX idx_diagnostics_resolution ON diagnostic_incidents(resolved_at, opened_at DESC)"
        ]
    )

    public static let sessionUsageSnapshot = DatabaseMigration(
        version: 3,
        name: "session_usage_snapshot",
        statements: [
            "ALTER TABLE agent_sessions ADD COLUMN usage_metrics BLOB"
        ]
    )
}
