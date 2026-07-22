import AgentDomain
import AgentProtocol
import CryptoKit
import Foundation

extension DatabaseActor {
    func upsertSupportRows(for write: EventWrite, connection: SQLiteConnection) throws {
        try upsertNode(for: write, connection: connection)
        let projectID = try upsertProject(
            write.snapshot.project,
            startedAt: write.snapshot.startedAt,
            connection: connection
        )
        let terminalID = try upsertTerminal(for: write.snapshot, connection: connection)
        try upsertSession(for: write, projectID: projectID, terminalID: terminalID, connection: connection)
    }

    func insertEvent(_ envelope: EventEnvelope, connection: SQLiteConnection) throws {
        guard envelope.privacyClass != .secret else { throw PersistenceError.secretPersistenceForbidden }
        let filteredPayload = EventPayloadPrivacyFilter.filter(envelope.payload, settings: cachedPrivacySettings)
        let rawPayload = try encoder.encode(filteredPayload)
        let context = Data(envelope.eventID.description.utf8)
        let encrypted = envelope.privacyClass == .sensitive
        let payload = try encrypted ? cipher.encrypt(rawPayload, context: context) : rawPayload
        let metadata = StoredEnvelopeMetadata(envelope)
        try connection.execute(
            """
            INSERT INTO session_events(
                event_id, session_id, source_key, sequence, event_type, occurred_at, received_at,
                privacy_class, payload, payload_encoding, envelope_metadata, schema_hash
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(envelope.eventID.description), .text(envelope.sessionID.description),
                .text(Self.sourceKey(envelope)), .integer(envelope.sequence), .text(envelope.eventType),
                .real(envelope.occurredAt.timeIntervalSince1970), .real(envelope.receivedAt.timeIntervalSince1970),
                .text(envelope.privacyClass.rawValue), .blob(payload), .text(encrypted ? "aes-gcm" : "json"),
                .blob(encoder.encode(metadata)), .text(envelope.schemaHash)
            ]
        )
    }

    private func upsertNode(for write: EventWrite, connection: SQLiteConnection) throws {
        try connection.execute(
            """
            INSERT INTO nodes(id, display_name, platform, trust_state, last_seen_at)
            VALUES (?, ?, ?, 'local', ?)
            ON CONFLICT(id) DO UPDATE SET last_seen_at = MAX(nodes.last_seen_at, excluded.last_seen_at)
            """,
            bindings: [
                .text(write.snapshot.nodeID.description), .text("Local node"), .text("macOS"),
                .real(write.envelope.receivedAt.timeIntervalSince1970)
            ]
        )
    }

    private func upsertProject(
        _ project: ProjectReference,
        startedAt: Date,
        connection: SQLiteConnection
    ) throws -> String {
        let standardizedPath = project.rootURL.standardizedFileURL.path(percentEncoded: false)
        let pathHash = SHA256.hash(data: Data(standardizedPath.utf8)).map { String(format: "%02x", $0) }.joined()

        if let canonicalID = try projectID(
            matching: "stable_path_hash",
            value: pathHash,
            connection: connection
        ) {
            try updateProject(canonicalID, from: project, connection: connection)
            return canonicalID
        }
        if let canonicalID = try projectID(
            matching: "id",
            value: project.id.description,
            connection: connection
        ) {
            try updateProject(canonicalID, from: project, connection: connection)
            return canonicalID
        }

        try connection.execute(
            """
            INSERT INTO projects(id, stable_path_hash, display_name, redacted_path, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(project.id.description), .text(pathHash), .text(project.name),
                .text(project.rootURL.lastPathComponent), .real(startedAt.timeIntervalSince1970)
            ]
        )
        return project.id.description
    }

    private func projectID(
        matching column: String,
        value: String,
        connection: SQLiteConnection
    ) throws -> String? {
        guard let row = try connection.query(
            "SELECT id FROM projects WHERE \(column) = ? LIMIT 1",
            bindings: [.text(value)]
        ).first?.first else { return nil }
        guard case let .text(identifier) = row else {
            throw PersistenceError.invalidStoredValue("project.id")
        }
        return identifier
    }

    private func updateProject(
        _ identifier: String,
        from project: ProjectReference,
        connection: SQLiteConnection
    ) throws {
        try connection.execute(
            "UPDATE projects SET display_name = ?, redacted_path = ? WHERE id = ?",
            bindings: [.text(project.name), .text(project.rootURL.lastPathComponent), .text(identifier)]
        )
    }

    private func upsertTerminal(for session: AgentSession, connection: SQLiteConnection) throws -> String? {
        guard let terminal = session.terminalContext else { return nil }
        let terminalID = session.id.description + ":terminal"
        try connection.execute(
            """
            INSERT INTO terminal_contexts(
                id, application_bundle_id, process_id, window_identifier, tab_identifier,
                pane_identifier, workspace_uri, correlation_token, captured_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                process_id = excluded.process_id, window_identifier = excluded.window_identifier,
                tab_identifier = excluded.tab_identifier, pane_identifier = excluded.pane_identifier,
                workspace_uri = excluded.workspace_uri, captured_at = excluded.captured_at
            """,
            bindings: [
                .text(terminalID), .text(terminal.applicationBundleID),
                terminal.processID.map { .integer(Int64($0)) } ?? .null,
                terminal.windowIdentifier.map(SQLiteValue.text) ?? .null,
                terminal.tabIdentifier.map(SQLiteValue.text) ?? .null,
                terminal.paneIdentifier.map(SQLiteValue.text) ?? .null,
                terminal.workspaceURI.map { .text($0.absoluteString) } ?? .null,
                .text(terminal.correlationToken), .real(terminal.capturedAt.timeIntervalSince1970)
            ]
        )
        return terminalID
    }

    private func upsertSession(
        for write: EventWrite,
        projectID: String,
        terminalID: String?,
        connection: SQLiteConnection
    ) throws {
        let session = write.snapshot
        let activitySummaryValue: SQLiteValue = try session.activitySummary
            .map { .blob(try encoder.encode($0)) } ?? .null
        try connection.execute(
            """
            INSERT INTO agent_sessions(
                id, provider_session_id, adapter_id, adapter_version, node_id, project_id,
                parent_session_id, state, started_at, ended_at, last_meaningful_event_at,
                snapshot_revision, terminal_context_id, usage_metrics, activity_summary
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                provider_session_id = excluded.provider_session_id,
                adapter_version = excluded.adapter_version,
                state = excluded.state,
                ended_at = excluded.ended_at,
                last_meaningful_event_at = excluded.last_meaningful_event_at,
                snapshot_revision = excluded.snapshot_revision,
                terminal_context_id = excluded.terminal_context_id,
                usage_metrics = excluded.usage_metrics,
                activity_summary = excluded.activity_summary
            WHERE excluded.snapshot_revision > agent_sessions.snapshot_revision
            """,
            bindings: [
                .text(session.id.description), session.externalSessionID.map(SQLiteValue.text) ?? .null,
                .text(session.adapterID.rawValue), .text(write.envelope.source.adapterVersion),
                .text(session.nodeID.description), .text(projectID),
                session.parentSessionID.map { .text($0.description) } ?? .null,
                .text(session.state.rawValue), .real(session.startedAt.timeIntervalSince1970),
                session.endedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .real(session.lastMeaningfulEventAt.timeIntervalSince1970), .integer(session.snapshotRevision),
                terminalID.map(SQLiteValue.text) ?? .null,
                .blob(encoder.encode(session.usageMetrics)),
                activitySummaryValue
            ]
        )
    }
}
