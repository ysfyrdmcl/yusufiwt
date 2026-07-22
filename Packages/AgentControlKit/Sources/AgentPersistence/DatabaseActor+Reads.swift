import AgentDomain
import AgentProtocol
import Foundation

extension DatabaseActor {
    public func session(id: SessionID) throws -> AgentSession? {
        guard let connection else { throw PersistenceError.databaseClosed }
        let rows = try connection.query(Self.sessionSelect + " WHERE s.id = ?", bindings: [.text(id.description)])
        return try rows.first.map(decodeSession)
    }

    public func sessionAdapterVersion(id: SessionID) throws -> String? {
        guard let connection else { throw PersistenceError.databaseClosed }
        guard let value = try connection.query(
            "SELECT adapter_version FROM agent_sessions WHERE id = ? LIMIT 1",
            bindings: [.text(id.description)]
        ).first?.first else { return nil }
        guard case let .text(version) = value else {
            throw PersistenceError.invalidStoredValue("agent_sessions.adapter_version")
        }
        return version
    }

    public func sessions(state: SessionState? = nil, limit: Int = 100) throws -> [SessionListItem] {
        guard let connection else { throw PersistenceError.databaseClosed }
        let boundedLimit = max(1, min(limit, 1000))
        var sql = """
        SELECT s.id, p.display_name, s.adapter_id, s.state, s.started_at,
               s.last_meaningful_event_at, s.snapshot_revision, s.usage_metrics, s.activity_summary,
               t.application_bundle_id, t.process_id, t.window_identifier, t.tab_identifier,
               t.pane_identifier, t.workspace_uri, t.correlation_token, t.captured_at
        FROM agent_sessions s JOIN projects p ON p.id = s.project_id
        LEFT JOIN terminal_contexts t ON t.id = s.terminal_context_id
        """
        var bindings: [SQLiteValue] = []
        if let state {
            sql += " WHERE s.state = ?"
            bindings.append(.text(state.rawValue))
        }
        sql += " ORDER BY s.last_meaningful_event_at DESC LIMIT ?"
        bindings.append(.integer(Int64(boundedLimit)))
        return try connection.query(sql, bindings: bindings).map(Self.decodeSessionListItem)
    }

    public func events(
        sessionID: SessionID,
        afterSequence: Int64? = nil,
        limit: Int = 500
    ) throws -> [PersistedSessionEvent] {
        guard let connection else { throw PersistenceError.databaseClosed }
        let boundedLimit = max(1, min(limit, 10000))
        var sql = """
        SELECT payload, payload_encoding, envelope_metadata
        FROM session_events WHERE session_id = ?
        """
        var bindings: [SQLiteValue] = [.text(sessionID.description)]
        if let afterSequence {
            sql += " AND sequence > ?"
            bindings.append(.integer(afterSequence))
        }
        sql += " ORDER BY sequence ASC LIMIT ?"
        bindings.append(.integer(Int64(boundedLimit)))
        return try connection.query(sql, bindings: bindings).map(decodeEvent)
    }

    public func eventCount() throws -> Int {
        guard let connection else { throw PersistenceError.databaseClosed }
        return try Int(connection.scalarInt("SELECT COUNT(*) FROM session_events") ?? 0)
    }

    public func latestSequenceBySource(sessionID: SessionID) throws -> [String: Int64] {
        guard let connection else { throw PersistenceError.databaseClosed }
        let rows = try connection.query(
            "SELECT source_key, MAX(sequence) FROM session_events WHERE session_id = ? GROUP BY source_key",
            bindings: [.text(sessionID.description)]
        )
        var result: [String: Int64] = [:]
        for row in rows {
            guard row.count == 2, let source = Self.string(row[0]), let sequence = Self.int(row[1]) else {
                throw PersistenceError.invalidStoredValue("session sequence checkpoint")
            }
            result[source] = sequence
        }
        return result
    }

    public func runtimeSettings() throws -> DatabaseRuntimeSettings {
        guard let connection else { throw PersistenceError.databaseClosed }
        let journalMode = try connection.query("PRAGMA journal_mode").first?.first.flatMap(Self.string)
        let foreignKeys = try connection.scalarInt("PRAGMA foreign_keys")
        let busyTimeout = try connection.scalarInt("PRAGMA busy_timeout")
        guard let journalMode, let foreignKeys, let busyTimeout else {
            throw PersistenceError.invalidStoredValue("database runtime settings")
        }
        return DatabaseRuntimeSettings(
            journalMode: journalMode,
            foreignKeysEnabled: foreignKeys == 1,
            busyTimeoutMilliseconds: Int(busyTimeout)
        )
    }

    public func auditEntries(limit: Int = 200) throws -> [AuditEntry] {
        guard let connection else { throw PersistenceError.databaseClosed }
        return try connection.query(
            "SELECT id, category, action, target_id, metadata, created_at FROM audit_log ORDER BY sequence DESC LIMIT ?",
            bindings: [.integer(Int64(max(1, min(limit, 1000))))]
        ).map(Self.decodeAuditEntry)
    }

    private func decodeEvent(_ row: [SQLiteValue]) throws -> PersistedSessionEvent {
        guard row.count == 3,
              let storedPayload = Self.data(row[0]),
              let encoding = Self.string(row[1]),
              let metadataData = Self.data(row[2])
        else { throw PersistenceError.invalidStoredValue("event row") }
        let metadata = try decoder.decode(StoredEnvelopeMetadata.self, from: metadataData)
        let encrypted = encoding == "aes-gcm"
        let context = Data(metadata.eventID.description.utf8)
        let payloadData = try encrypted ? cipher.decrypt(storedPayload, context: context) : storedPayload
        let payload = try decoder.decode(JSONValue.self, from: payloadData)
        return PersistedSessionEvent(envelope: metadata.envelope(payload: payload), wasEncrypted: encrypted)
    }

    private func decodeSession(_ row: [SQLiteValue]) throws -> AgentSession {
        guard row.count == 26,
              let sessionUUID = Self.uuid(row[0]), let adapter = Self.string(row[2]),
              let nodeUUID = Self.uuid(row[4]), let projectUUID = Self.uuid(row[13]),
              let projectName = Self.string(row[14]), let rootString = Self.string(row[15]),
              let stateString = Self.string(row[7]), let state = SessionState(rawValue: stateString),
              let started = Self.double(row[8]), let activity = Self.double(row[10]), let revision = Self.int(row[11])
        else { throw PersistenceError.invalidStoredValue("session snapshot row") }
        return try AgentSession(
            id: SessionID(sessionUUID), nodeID: NodeID(nodeUUID), adapterID: AdapterID(adapter),
            externalSessionID: Self.string(row[1]),
            project: ProjectReference(id: ProjectID(projectUUID), name: projectName, rootURL: URL(fileURLWithPath: rootString)),
            terminalContext: Self.decodeTerminal(row), parentSessionID: Self.uuid(row[6]).map(SessionID.init), state: state,
            startedAt: Date(timeIntervalSince1970: started),
            endedAt: Self.double(row[9]).map(Date.init(timeIntervalSince1970:)),
            lastMeaningfulEventAt: Date(timeIntervalSince1970: activity), snapshotRevision: revision,
            usageMetrics: Self.decodeUsageMetrics(row[24]),
            activitySummary: Self.decodeActivitySummary(row[25])
        )
    }

    private static func decodeTerminal(_ row: [SQLiteValue]) -> TerminalContext? {
        guard let bundleID = string(row[16]), let token = string(row[22]), let captured = double(row[23]) else {
            return nil
        }
        return TerminalContext(
            applicationBundleID: bundleID, processID: int(row[17]).map(Int32.init),
            windowIdentifier: string(row[18]), tabIdentifier: string(row[19]), paneIdentifier: string(row[20]),
            workspaceURI: string(row[21]).flatMap(URL.init(string:)), correlationToken: token,
            capturedAt: Date(timeIntervalSince1970: captured)
        )
    }

    private static func decodeSessionListItem(_ row: [SQLiteValue]) throws -> SessionListItem {
        guard row.count == 17, let id = uuid(row[0]), let projectName = string(row[1]),
              let adapter = string(row[2]), let stateName = string(row[3]),
              let state = SessionState(rawValue: stateName), let started = double(row[4]),
              let activity = double(row[5]), let revision = int(row[6])
        else { throw PersistenceError.invalidStoredValue("session list row") }
        return try SessionListItem(
            id: SessionID(id), projectName: projectName, adapterID: AdapterID(adapter), state: state,
            startedAt: Date(timeIntervalSince1970: started),
            lastMeaningfulEventAt: Date(timeIntervalSince1970: activity), snapshotRevision: revision,
            usageMetrics: decodeUsageMetrics(row[7]),
            activitySummary: decodeActivitySummary(row[8]),
            terminalContext: decodeListTerminal(row)
        )
    }

    private static func decodeListTerminal(_ row: [SQLiteValue]) -> TerminalContext? {
        guard let bundleID = string(row[9]), let token = string(row[15]), let captured = double(row[16]) else {
            return nil
        }
        return TerminalContext(
            applicationBundleID: bundleID, processID: int(row[10]).map(Int32.init),
            windowIdentifier: string(row[11]), tabIdentifier: string(row[12]), paneIdentifier: string(row[13]),
            workspaceURI: string(row[14]).flatMap(URL.init(string:)), correlationToken: token,
            capturedAt: Date(timeIntervalSince1970: captured)
        )
    }

    private static func decodeActivitySummary(_ value: SQLiteValue) throws -> SessionActivitySummary? {
        if case .null = value { return nil }
        guard let data = data(value) else { throw PersistenceError.invalidStoredValue("session activity summary") }
        do {
            return try JSONDecoder().decode(SessionActivitySummary.self, from: data)
        } catch {
            throw PersistenceError.invalidStoredValue("session activity summary")
        }
    }

    private static func decodeUsageMetrics(_ value: SQLiteValue) throws -> [SessionUsageMetric] {
        if case .null = value {
            return []
        }
        guard let data = data(value) else { throw PersistenceError.invalidStoredValue("session usage metrics") }
        do {
            return try JSONDecoder().decode([SessionUsageMetric].self, from: data)
        } catch {
            throw PersistenceError.invalidStoredValue("session usage metrics")
        }
    }

    private static func decodeAuditEntry(_ row: [SQLiteValue]) throws -> AuditEntry {
        guard row.count == 6, let id = uuid(row[0]), let category = string(row[1]),
              let action = string(row[2]), let createdAt = double(row[5])
        else { throw PersistenceError.invalidStoredValue("audit row") }
        return AuditEntry(
            id: id, category: category, action: action, targetID: string(row[3]), metadata: data(row[4]),
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    private static let sessionSelect = """
    SELECT s.id, s.provider_session_id, s.adapter_id, s.adapter_version, s.node_id, s.project_id,
           s.parent_session_id, s.state, s.started_at, s.ended_at, s.last_meaningful_event_at,
           s.snapshot_revision, s.terminal_context_id,
           p.id, p.display_name, p.redacted_path,
           t.application_bundle_id, t.process_id, t.window_identifier, t.tab_identifier,
           t.pane_identifier, t.workspace_uri, t.correlation_token, t.captured_at,
           s.usage_metrics, s.activity_summary
    FROM agent_sessions s
    JOIN projects p ON p.id = s.project_id
    LEFT JOIN terminal_contexts t ON t.id = s.terminal_context_id
    """
}
