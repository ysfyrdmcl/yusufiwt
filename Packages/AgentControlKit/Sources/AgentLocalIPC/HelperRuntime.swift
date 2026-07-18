#if os(macOS)
    import AgentPersistence
    import Foundation

    public actor HelperRuntime {
        private let database: DatabaseActor
        private let registry: SessionRegistryActor
        private let spool: HookSpool
        private let decisions: HookDecisionBroker
        private let paths: AgentControlPaths
        private let startedAt: Date
        private let now: @Sendable () -> Date
        private var heartbeatSequence: UInt64 = 0
        private var socketAcceptingConnections = false
        private var shuttingDown = false

        public init(
            database: DatabaseActor,
            registry: SessionRegistryActor,
            spool: HookSpool,
            decisions: HookDecisionBroker = HookDecisionBroker(),
            paths: AgentControlPaths,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.database = database
            self.registry = registry
            self.spool = spool
            self.decisions = decisions
            self.paths = paths
            self.now = now
            startedAt = now()
        }

        public func setSocketAcceptingConnections(_ accepting: Bool) {
            socketAcceptingConnections = accepting
        }

        public func notifications() async -> AsyncStream<RegistryNotification> {
            await registry.notifications()
        }

        public func handle(_ request: HelperRequest) async -> HelperResponse {
            if shuttingDown {
                return .neutral(reason: .shuttingDown)
            }
            do {
                if let response = try await handleRoutedRequest(request) {
                    return response
                }
                switch request {
                case let .negotiate(supportedVersions):
                    guard supportedVersions.contains(LocalIPCContract.currentVersion) else {
                        return .neutral(reason: .unsupportedProtocol)
                    }
                    return .negotiated(version: LocalIPCContract.currentVersion)
                case .health:
                    return try await .health(health())
                case .heartbeat:
                    heartbeatSequence &+= 1
                    return .heartbeat(HelperHeartbeat(sequence: heartbeatSequence, emittedAt: now()))
                case let .submitEvent(submission):
                    return try await .eventAccepted(registry.ingest(submission))
                case .requestDecision, .pendingDecisions, .resolveDecision, .listSessions, .sessionSnapshot, .sessionEvents:
                    return .failure(code: "helper.internal_routing", safeMessage: "The helper could not route the request.")
                case .prepareForUpdate:
                    return try await .updateHandoff(prepareForUpdate())
                }
            } catch {
                return .failure(code: "helper.request_failed", safeMessage: "The helper could not process the request.")
            }
        }

        private func handleRoutedRequest(_ request: HelperRequest) async throws -> HelperResponse? {
            switch request {
            case let .requestDecision(decisionRequest):
                _ = try await registry.ingest(decisionRequest.submission)
                return await decisions.wait(for: decisionRequest)
            case .pendingDecisions:
                return await .pendingDecisions(decisions.pending())
            case let .resolveDecision(resolution):
                return await .decisionResolution(decisions.resolve(resolution))
            case let .listSessions(limit):
                return try await .sessionList(database.sessions(limit: limit))
            case let .sessionSnapshot(id):
                return try await .sessionSnapshot(database.session(id: id))
            case let .sessionEvents(sessionID, limit):
                return try await .sessionEvents(database.events(sessionID: sessionID, limit: limit))
            default:
                return nil
            }
        }

        public func health() async throws -> HelperHealth {
            let databaseHealth = try await database.integrityCheck()
            let pendingDecisionCount = await decisions.pending().count
            return try await HelperHealth(
                protocolVersion: LocalIPCContract.currentVersion,
                processID: ProcessInfo.processInfo.processIdentifier,
                uptimeSeconds: max(0, now().timeIntervalSince(startedAt)),
                activeSessionCount: registry.activeSessionCount(),
                persistedEventCount: database.eventCount(),
                spoolPendingCount: spool.pendingCount(),
                pendingDecisionCount: pendingDecisionCount,
                socketAcceptingConnections: socketAcceptingConnections,
                databaseHealthy: databaseHealth == .healthy
            )
        }

        @discardableResult
        public func importSpool(limit: Int = 1000) async throws -> SpoolImportReport {
            try await spool.importPending(limit: limit) { [registry] data in
                let submission = try JSONDecoder().decode(HelperEventSubmission.self, from: data)
                _ = try await registry.ingest(submission)
            }
        }

        public func prepareForUpdate() async throws -> UpdateHandoff {
            try await database.checkpoint()
            let handoff = try await UpdateHandoff(
                token: UUID(),
                preparedAt: now(),
                persistedEventCount: database.eventCount()
            )
            let data = try JSONEncoder().encode(handoff)
            try data.write(to: paths.handoffURL, options: .atomic)
            return handoff
        }

        public func gracefulShutdown() async {
            guard !shuttingDown else { return }
            shuttingDown = true
            await decisions.cancelAll(reason: .shuttingDown)
            socketAcceptingConnections = false
            _ = try? await importSpool()
            try? await database.checkpoint()
            await database.close()
        }
    }
#endif
