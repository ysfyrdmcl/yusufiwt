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
        func resolve(_ resolution: HookDecisionResolution) async throws -> DecisionResolutionDisposition
        func notifications() async -> AsyncStream<RegistryNotification>
        func disconnect() async
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
