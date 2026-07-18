#if os(macOS)
    import AgentDomain
    import AgentLocalIPC
    import AgentPersistence
    import Foundation

    public struct AgentControlSnapshot: Sendable, Equatable {
        public let health: HelperHealth
        public let sessions: [SessionListItem]
        public let pendingDecisions: [PendingHookDecision]

        public init(
            health: HelperHealth,
            sessions: [SessionListItem],
            pendingDecisions: [PendingHookDecision]
        ) {
            self.health = health
            self.sessions = sessions
            self.pendingDecisions = pendingDecisions
        }
    }

    public protocol AgentControlTransport: Sendable {
        func snapshot(sessionLimit: Int) async throws -> AgentControlSnapshot
        func session(id: SessionID) async throws -> AgentSession?
        func events(sessionID: SessionID, limit: Int) async throws -> [PersistedSessionEvent]
        func history(_ query: HistoryQuery) async throws -> HistoryPage
        func analytics(_ query: AnalyticsQuery) async throws -> AnalyticsSummary
        func rules() async throws -> [OperationsRule]
        func saveRule(_ rule: OperationsRule) async throws
        func deleteRule(id: UUID) async throws -> Bool
        func alerts() async throws -> [SessionAlert]
        func privacySettings() async throws -> PrivacySettings
        func savePrivacySettings(_ settings: PrivacySettings) async throws
        func diagnostics() async throws -> DiagnosticsReport
        func repair(_ action: RepairAction) async throws -> RepairResult
        func deleteCompletedHistory(endedBefore: Date) async throws -> DataDeletionResult
        func resolve(_ resolution: HookDecisionResolution) async throws -> DecisionResolutionDisposition
        func notifications() async -> AsyncStream<RegistryNotification>
        func disconnect() async
    }

    public extension AgentControlTransport {
        func history(_: HistoryQuery) async throws -> HistoryPage {
            throw LocalIPCError.unavailable
        }

        func analytics(_: AnalyticsQuery) async throws -> AnalyticsSummary {
            throw LocalIPCError.unavailable
        }

        func rules() async throws -> [OperationsRule] {
            throw LocalIPCError.unavailable
        }

        func saveRule(_: OperationsRule) async throws {
            throw LocalIPCError.unavailable
        }

        func deleteRule(id _: UUID) async throws -> Bool {
            throw LocalIPCError.unavailable
        }

        func alerts() async throws -> [SessionAlert] {
            throw LocalIPCError.unavailable
        }

        func privacySettings() async throws -> PrivacySettings {
            throw LocalIPCError.unavailable
        }

        func savePrivacySettings(_: PrivacySettings) async throws {
            throw LocalIPCError.unavailable
        }

        func diagnostics() async throws -> DiagnosticsReport {
            throw LocalIPCError.unavailable
        }

        func repair(_: RepairAction) async throws -> RepairResult {
            throw LocalIPCError.unavailable
        }

        func deleteCompletedHistory(endedBefore _: Date) async throws -> DataDeletionResult {
            throw LocalIPCError.unavailable
        }
    }

    public actor XPCAgentControlTransport: AgentControlTransport {
        private let client: HelperXPCClient

        public init(client: HelperXPCClient = HelperXPCClient()) {
            self.client = client
        }

        public func snapshot(sessionLimit: Int) async throws -> AgentControlSnapshot {
            async let healthResponse = client.send(.health)
            async let sessionsResponse = client.send(.listSessions(limit: sessionLimit))
            async let pendingResponse = client.send(.pendingDecisions)
            let (health, sessions, pending) = try await (healthResponse, sessionsResponse, pendingResponse)
            guard case let .health(helperHealth) = health,
                  case let .sessionList(sessionItems) = sessions,
                  case let .pendingDecisions(decisions) = pending
            else { throw LocalIPCError.malformedPayload }
            return AgentControlSnapshot(
                health: helperHealth,
                sessions: sessionItems,
                pendingDecisions: decisions
            )
        }

        public func session(id: SessionID) async throws -> AgentSession? {
            let response = try await client.send(.sessionSnapshot(id))
            guard case let .sessionSnapshot(session) = response else { throw LocalIPCError.malformedPayload }
            return session
        }

        public func events(sessionID: SessionID, limit: Int) async throws -> [PersistedSessionEvent] {
            let response = try await client.send(.sessionEvents(sessionID: sessionID, limit: limit))
            guard case let .sessionEvents(events) = response else { throw LocalIPCError.malformedPayload }
            return events
        }

        public func history(_ query: HistoryQuery) async throws -> HistoryPage {
            let response = try await client.send(.history(query))
            guard case let .history(page) = response else { throw LocalIPCError.malformedPayload }
            return page
        }

        public func analytics(_ query: AnalyticsQuery) async throws -> AnalyticsSummary {
            let response = try await client.send(.analytics(query))
            guard case let .analytics(summary) = response else { throw LocalIPCError.malformedPayload }
            return summary
        }

        public func rules() async throws -> [OperationsRule] {
            let response = try await client.send(.listRules)
            guard case let .rules(rules) = response else { throw LocalIPCError.malformedPayload }
            return rules
        }

        public func saveRule(_ rule: OperationsRule) async throws {
            let response = try await client.send(.upsertRule(rule))
            guard case .ruleSaved = response else { throw LocalIPCError.malformedPayload }
        }

        public func deleteRule(id: UUID) async throws -> Bool {
            let response = try await client.send(.deleteRule(id))
            guard case let .ruleDeleted(deleted) = response else { throw LocalIPCError.malformedPayload }
            return deleted
        }

        public func alerts() async throws -> [SessionAlert] {
            let response = try await client.send(.activeAlerts)
            guard case let .activeAlerts(alerts) = response else { throw LocalIPCError.malformedPayload }
            return alerts
        }

        public func privacySettings() async throws -> PrivacySettings {
            let response = try await client.send(.privacySettings)
            guard case let .privacySettings(settings) = response else { throw LocalIPCError.malformedPayload }
            return settings
        }

        public func savePrivacySettings(_ settings: PrivacySettings) async throws {
            let response = try await client.send(.savePrivacySettings(settings))
            guard case .privacySettings = response else { throw LocalIPCError.malformedPayload }
        }

        public func diagnostics() async throws -> DiagnosticsReport {
            let response = try await client.send(.diagnostics)
            guard case let .diagnostics(report) = response else { throw LocalIPCError.malformedPayload }
            return report
        }

        public func repair(_ action: RepairAction) async throws -> RepairResult {
            let response = try await client.send(.repair(action))
            guard case let .repair(result) = response else { throw LocalIPCError.malformedPayload }
            return result
        }

        public func deleteCompletedHistory(endedBefore: Date) async throws -> DataDeletionResult {
            let response = try await client.send(.deleteCompletedHistory(endedBefore: endedBefore))
            guard case let .dataDeletion(result) = response else { throw LocalIPCError.malformedPayload }
            return result
        }

        public func resolve(_ resolution: HookDecisionResolution) async throws -> DecisionResolutionDisposition {
            let response = try await client.send(.resolveDecision(resolution))
            guard case let .decisionResolution(disposition) = response else { throw LocalIPCError.malformedPayload }
            return disposition
        }

        public func notifications() async -> AsyncStream<RegistryNotification> {
            await client.notifications()
        }

        public func disconnect() async {
            await client.disconnect()
        }
    }
#endif
