import AgentDomain
import Foundation

public extension DatabaseActor {
    func history(_ query: HistoryQuery) throws -> HistoryPage {
        guard let connection else { throw PersistenceError.databaseClosed }
        let (whereClause, bindings) = Self.historyPredicate(query)
        let total = try connection.scalarInt(
            "SELECT COUNT(*) FROM agent_sessions s JOIN projects p ON p.id = s.project_id" + whereClause,
            bindings: bindings
        ) ?? 0
        let limit = max(1, min(query.limit, 500))
        let offset = max(0, query.offset)
        let rows = try connection.query(
            """
            SELECT s.id, p.display_name, s.adapter_id, s.state, s.started_at, s.ended_at,
                   s.last_meaningful_event_at,
                   (SELECT COUNT(*) FROM session_events e WHERE e.session_id = s.id)
            FROM agent_sessions s JOIN projects p ON p.id = s.project_id
            """ + whereClause + " ORDER BY s.started_at DESC, s.id LIMIT ? OFFSET ?",
            bindings: bindings + [.integer(Int64(limit)), .integer(Int64(offset))]
        )
        return try HistoryPage(items: rows.map(Self.decodeHistorySession), totalCount: Int(total))
    }

    // The query is deliberately kept in one method so all aggregate reads share one SQLite snapshot.
    // swiftlint:disable:next function_body_length
    func analytics(_ query: AnalyticsQuery) throws -> AnalyticsSummary {
        guard let connection else { throw PersistenceError.databaseClosed }
        guard query.endDate >= query.from else { throw PersistenceError.invalidStoredValue("analytics date range") }
        let bucketWidth: Int64 = query.interval == .day ? 86400 : 604_800
        var sessionFilter = "s.started_at >= ? AND s.started_at < ?"
        var sessionBindings: [SQLiteValue] = [
            .real(query.from.timeIntervalSince1970), .real(query.endDate.timeIntervalSince1970)
        ]
        if let adapterID = query.adapterID {
            sessionFilter += " AND s.adapter_id = ?"
            sessionBindings.append(.text(adapterID.rawValue))
        }
        let totals = try connection.query(
            """
            SELECT COUNT(*),
                   SUM(CASE WHEN s.state = 'completed' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN s.state = 'failed' THEN 1 ELSE 0 END),
                   COALESCE(AVG(CASE WHEN s.ended_at IS NOT NULL THEN s.ended_at - s.started_at END), 0)
            FROM agent_sessions s WHERE \(sessionFilter)
            """,
            bindings: sessionBindings
        ).first ?? []
        let sessionRows = try connection.query(
            """
            SELECT CAST(s.started_at / ? AS INTEGER) * ?, COUNT(*),
                   SUM(CASE WHEN s.state = 'completed' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN s.state = 'failed' THEN 1 ELSE 0 END)
            FROM agent_sessions s WHERE \(sessionFilter)
            GROUP BY 1 ORDER BY 1
            """,
            bindings: [.integer(bucketWidth), .integer(bucketWidth)] + sessionBindings
        )
        var approvalFilter = "e.received_at >= ? AND e.received_at < ? AND e.event_type = 'approval.requested'"
        var approvalBindings: [SQLiteValue] = [
            .real(query.from.timeIntervalSince1970), .real(query.endDate.timeIntervalSince1970)
        ]
        if let adapterID = query.adapterID {
            approvalFilter += " AND s.adapter_id = ?"
            approvalBindings.append(.text(adapterID.rawValue))
        }
        let approvalRows = try connection.query(
            """
            SELECT CAST(e.received_at / ? AS INTEGER) * ?, COUNT(*)
            FROM session_events e JOIN agent_sessions s ON s.id = e.session_id
            WHERE \(approvalFilter) GROUP BY 1 ORDER BY 1
            """,
            bindings: [.integer(bucketWidth), .integer(bucketWidth)] + approvalBindings
        )
        let approvalByBucket = Dictionary(uniqueKeysWithValues: approvalRows.compactMap { row -> (Int64, Int)? in
            guard let start = Self.int(row[0]), let count = Self.int(row[1]) else { return nil }
            return (start, Int(count))
        })
        var buckets = try sessionRows.map { row -> AnalyticsBucket in
            guard let start = Self.int(row[0]), let sessions = Self.int(row[1]),
                  let completed = Self.int(row[2]), let failed = Self.int(row[3])
            else { throw PersistenceError.invalidStoredValue("analytics bucket") }
            return AnalyticsBucket(
                start: Date(timeIntervalSince1970: TimeInterval(start)),
                sessionCount: Int(sessions),
                completedCount: Int(completed),
                failedCount: Int(failed),
                approvalRequestCount: approvalByBucket[start, default: 0]
            )
        }
        let existingStarts = Set(buckets.map { Int64($0.start.timeIntervalSince1970) })
        for (start, count) in approvalByBucket where !existingStarts.contains(start) {
            buckets.append(AnalyticsBucket(
                start: Date(timeIntervalSince1970: TimeInterval(start)),
                sessionCount: 0, completedCount: 0, failedCount: 0, approvalRequestCount: count
            ))
        }
        buckets.sort { $0.start < $1.start }
        let approvalTotal = approvalByBucket.values.reduce(0, +)
        return AnalyticsSummary(
            totalSessions: Int(Self.int(totals[safe: 0] ?? .integer(0)) ?? 0),
            completedSessions: Int(Self.int(totals[safe: 1] ?? .integer(0)) ?? 0),
            failedSessions: Int(Self.int(totals[safe: 2] ?? .integer(0)) ?? 0),
            approvalRequests: approvalTotal,
            averageDurationSeconds: Self.double(totals[safe: 3] ?? .real(0)) ?? 0,
            buckets: buckets
        )
    }

    func rules() throws -> [OperationsRule] {
        guard let connection else { throw PersistenceError.databaseClosed }
        return try connection.query(
            "SELECT predicate_json, action_json FROM rules ORDER BY updated_at DESC, id"
        ).map { row in
            guard let predicate = Self.data(row[0]), let action = Self.data(row[1]),
                  let discriminator = try? decoder.decode(StoredRuleAction.self, from: action)
            else { throw PersistenceError.invalidStoredValue("rule") }
            switch discriminator.type {
            case .notify:
                return try .alert(decoder.decode(AlertRule.self, from: predicate))
            case .allowLowRisk:
                return try .automation(decoder.decode(LowRiskAutomationRule.self, from: predicate))
            }
        }
    }

    func alertRules(enabledOnly: Bool = false) throws -> [AlertRule] {
        try rules().compactMap { rule in
            guard case let .alert(value) = rule, !enabledOnly || value.isEnabled else { return nil }
            return value
        }
    }

    func automationRules(enabledOnly: Bool = false) throws -> [LowRiskAutomationRule] {
        try rules().compactMap { rule in
            guard case let .automation(value) = rule, !enabledOnly || value.isEnabled else { return nil }
            return value
        }
    }

    func upsertRule(_ rule: OperationsRule) throws {
        guard let connection else { throw PersistenceError.databaseClosed }
        let values: StoredRuleValues = switch rule {
        case let .alert(value):
            try StoredRuleValues(rule: value, predicate: encoder.encode(value), action: .init(type: .notify))
        case let .automation(value):
            try StoredRuleValues(rule: value, predicate: encoder.encode(value), action: .init(type: .allowLowRisk))
        }
        try connection.execute(
            """
            INSERT INTO rules(id, name, enabled, predicate_json, action_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, enabled = excluded.enabled,
                predicate_json = excluded.predicate_json, action_json = excluded.action_json,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(values.id.uuidString.lowercased()), .text(values.name), .integer(values.isEnabled ? 1 : 0),
                .blob(values.predicate), .blob(encoder.encode(values.action)),
                .real(values.createdAt.timeIntervalSince1970), .real(values.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    @discardableResult
    func deleteRule(id: UUID) throws -> Bool {
        guard let connection else { throw PersistenceError.databaseClosed }
        try connection.execute("DELETE FROM rules WHERE id = ?", bindings: [.text(id.uuidString.lowercased())])
        return connection.changes > 0
    }

    func privacySettings() throws -> PrivacySettings {
        guard connection != nil else { throw PersistenceError.databaseClosed }
        return cachedPrivacySettings
    }

    func savePrivacySettings(_ settings: PrivacySettings, at date: Date = Date()) throws {
        guard let connection else { throw PersistenceError.databaseClosed }
        let normalized = PrivacySettings(
            analyticsEnabled: settings.analyticsEnabled,
            retentionDays: settings.retentionDays,
            includePrivateMetadataInDiagnostics: settings.includePrivateMetadataInDiagnostics,
            storePromptContent: settings.storePromptContent,
            storeTerminalOutput: settings.storeTerminalOutput
        )
        try connection.execute(
            """
            INSERT INTO settings(key, value, privacy_class, updated_at) VALUES ('privacy', ?, 'privateMetadata', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """,
            bindings: [.blob(encoder.encode(normalized)), .real(date.timeIntervalSince1970)]
        )
        cachedPrivacySettings = normalized
    }

    func activeSessionSnapshots(limit: Int = 1000) throws -> [AgentSession] {
        let items = try sessions(limit: limit).filter { !$0.state.isTerminal }
        return try items.compactMap { try session(id: $0.id) }
    }

    func diagnostics(at date: Date = Date()) throws -> DiagnosticsReport {
        guard let connection else { throw PersistenceError.databaseClosed }
        let health = try integrityCheck()
        let schemaVersion = try Int(connection.scalarInt("SELECT MAX(version) FROM schema_migrations") ?? 0)
        let active = try Int(connection.scalarInt(
            "SELECT COUNT(*) FROM agent_sessions WHERE ended_at IS NULL"
        ) ?? 0)
        let events = try eventCount()
        let checks = try [
            DiagnosticCheck(
                id: "database.integrity",
                status: health == .healthy ? .healthy : .failed,
                safeSummary: health == .healthy ? "Database integrity check passed." : "Database recovery is required."
            ),
            DiagnosticCheck(
                id: "database.wal",
                status: runtimeSettings().journalMode.lowercased() == "wal" ? .healthy : .warning,
                safeSummary: "Database journal mode was checked."
            )
        ]
        return DiagnosticsReport(
            generatedAt: date, checks: checks, activeSessionCount: active,
            persistedEventCount: events, schemaVersion: schemaVersion
        )
    }

    func repair(_ action: RepairAction, now: Date = Date()) throws -> RepairResult {
        guard let connection else { throw PersistenceError.databaseClosed }
        switch action {
        case .checkpointDatabase:
            try checkpoint()
            return RepairResult(action: action, affectedRows: 0, safeMessage: "Database checkpoint completed.")
        case .applyRetention:
            let settings = try privacySettings()
            let cutoff = now.addingTimeInterval(-TimeInterval(settings.retentionDays) * 86400)
            var deleted = 0
            while true {
                let count = try runRetentionCleanup(eventsBefore: cutoff, batchSize: 1000)
                deleted += count
                if count < 1000 {
                    break
                }
            }
            return RepairResult(action: action, affectedRows: deleted, safeMessage: "Retention cleanup completed.")
        case .clearResolvedDiagnostics:
            try connection.execute("DELETE FROM diagnostic_incidents WHERE resolved_at IS NOT NULL")
            return RepairResult(
                action: action, affectedRows: Int(connection.changes),
                safeMessage: "Resolved diagnostic incidents were cleared."
            )
        }
    }

    func deleteCompletedHistory(endedBefore cutoff: Date) throws -> DataDeletionResult {
        guard let connection else { throw PersistenceError.databaseClosed }
        return try connection.transaction {
            let events = try Int(connection.scalarInt(
                """
                SELECT COUNT(*) FROM session_events WHERE session_id IN (
                    SELECT id FROM agent_sessions WHERE ended_at IS NOT NULL AND ended_at < ?
                )
                """,
                bindings: [.real(cutoff.timeIntervalSince1970)]
            ) ?? 0)
            try connection.execute(
                "DELETE FROM agent_sessions WHERE ended_at IS NOT NULL AND ended_at < ?",
                bindings: [.real(cutoff.timeIntervalSince1970)]
            )
            let sessions = Int(connection.changes)
            try connection.execute(
                "DELETE FROM terminal_contexts WHERE id NOT IN (SELECT terminal_context_id FROM agent_sessions WHERE terminal_context_id IS NOT NULL)"
            )
            return DataDeletionResult(deletedSessions: sessions, deletedEvents: events)
        }
    }

    private static func historyPredicate(_ query: HistoryQuery) -> (String, [SQLiteValue]) {
        var clauses: [String] = []
        var bindings: [SQLiteValue] = []
        let search = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            clauses.append("(p.display_name LIKE ? ESCAPE '\\' COLLATE NOCASE OR s.adapter_id LIKE ? ESCAPE '\\' COLLATE NOCASE)")
            let pattern = "%" + escapeLike(search) + "%"
            bindings += [.text(pattern), .text(pattern)]
        }
        if let adapterID = query.adapterID {
            clauses.append("s.adapter_id = ?")
            bindings.append(.text(adapterID.rawValue))
        }
        if !query.states.isEmpty {
            clauses.append("s.state IN (" + Array(repeating: "?", count: query.states.count).joined(separator: ",") + ")")
            bindings += query.states.sorted { $0.rawValue < $1.rawValue }.map { .text($0.rawValue) }
        }
        if let after = query.startedAfter {
            clauses.append("s.started_at >= ?")
            bindings.append(.real(after.timeIntervalSince1970))
        }
        if let before = query.startedBefore {
            clauses.append("s.started_at < ?")
            bindings.append(.real(before.timeIntervalSince1970))
        }
        return (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND "), bindings)
    }

    private static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func decodeHistorySession(_ row: [SQLiteValue]) throws -> HistorySession {
        guard row.count == 8, let id = uuid(row[0]), let project = string(row[1]),
              let adapter = string(row[2]), let stateName = string(row[3]),
              let state = SessionState(rawValue: stateName), let started = double(row[4]),
              let activity = double(row[6]), let eventCount = int(row[7])
        else { throw PersistenceError.invalidStoredValue("history session") }
        return HistorySession(
            id: SessionID(id), projectName: project, adapterID: AdapterID(adapter), state: state,
            startedAt: Date(timeIntervalSince1970: started),
            endedAt: double(row[5]).map(Date.init(timeIntervalSince1970:)),
            lastMeaningfulEventAt: Date(timeIntervalSince1970: activity), eventCount: Int(eventCount)
        )
    }
}

private struct StoredRuleAction: Codable {
    enum Kind: String, Codable { case notify, allowLowRisk }
    let type: Kind
}

private struct StoredRuleValues {
    let id: UUID
    let name: String
    let isEnabled: Bool
    let predicate: Data
    let action: StoredRuleAction
    let createdAt: Date
    let updatedAt: Date

    init(rule: AlertRule, predicate: Data, action: StoredRuleAction) {
        id = rule.id
        name = rule.name
        isEnabled = rule.isEnabled
        self.predicate = predicate
        self.action = action
        createdAt = rule.createdAt
        updatedAt = rule.updatedAt
    }

    init(rule: LowRiskAutomationRule, predicate: Data, action: StoredRuleAction) {
        id = rule.id
        name = rule.name
        isEnabled = rule.isEnabled
        self.predicate = predicate
        self.action = action
        createdAt = rule.createdAt
        updatedAt = rule.updatedAt
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
