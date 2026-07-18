import AgentDomain
import AgentProtocol
import CryptoKit
import Foundation

extension DatabaseActor {
    func upsertSupportRows(for write: EventWrite, connection: SQLiteConnection) throws {
        try upsertNode(for: write, connection: connection)
        try upsertProject(write.snapshot.project, startedAt: write.snapshot.startedAt, connection: connection)
        let terminalID = try upsertTerminal(for: write.snapshot, connection: connection)
        try upsertSession(for: write, terminalID: terminalID, connection: connection)
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
    ) throws {
        let standardizedPath = project.rootURL.standardizedFileURL.path(percentEncoded: false)
        let pathHash = SHA256.hash(data: Data(standardizedPath.utf8)).map { String(format: "%02x", $0) }.joined()
        try connection.execute(
            """
            INSERT INTO projects(id, stable_path_hash, display_name, redacted_path, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET display_name = excluded.display_name, redacted_path = excluded.redacted_path
            """,
            bindings: [
                .text(project.id.description), .text(pathHash), .text(project.name),
                .text(project.rootURL.lastPathComponent), .real(startedAt.timeIntervalSince1970)
            ]
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
        terminalID: String?,
        connection: SQLiteConnection
    ) throws {
        let session = write.snapshot
        try connection.execute(
            """
            INSERT INTO agent_sessions(
                id, provider_session_id, adapter_id, adapter_version, node_id, project_id,
                parent_session_id, state, started_at, ended_at, last_meaningful_event_at,
                snapshot_revision, terminal_context_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                provider_session_id = excluded.provider_session_id,
                adapter_version = excluded.adapter_version,
                state = excluded.state,
                ended_at = excluded.ended_at,
                last_meaningful_event_at = excluded.last_meaningful_event_at,
                snapshot_revision = excluded.snapshot_revision,
                terminal_context_id = excluded.terminal_context_id
            WHERE excluded.snapshot_revision > agent_sessions.snapshot_revision
            """,
            bindings: [
                .text(session.id.description), session.externalSessionID.map(SQLiteValue.text) ?? .null,
                .text(session.adapterID.rawValue), .text(write.envelope.source.adapterVersion),
                .text(session.nodeID.description), .text(session.project.id.description),
                session.parentSessionID.map { .text($0.description) } ?? .null,
                .text(session.state.rawValue), .real(session.startedAt.timeIntervalSince1970),
                session.endedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .real(session.lastMeaningfulEventAt.timeIntervalSince1970), .integer(session.snapshotRevision),
                terminalID.map(SQLiteValue.text) ?? .null
            ]
        )
    }
}
