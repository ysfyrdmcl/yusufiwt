#if os(macOS)
    import AgentDomain
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
                case .requestDecision, .pendingDecisions, .resolveDecision, .listSessions, .sessionSnapshot,
                     .sessionEvents, .history, .analytics, .listRules, .upsertRule, .deleteRule,
                     .activeAlerts, .privacySettings, .savePrivacySettings, .diagnostics, .repair,
                     .deleteCompletedHistory:
                    return .failure(code: "helper.internal_routing", safeMessage: "The helper could not route the request.")
                case .prepareForUpdate:
                    return try await .updateHandoff(prepareForUpdate())
                }
            } catch {
                return .failure(code: "helper.request_failed", safeMessage: "The helper could not process the request.")
            }
        }

        // Routing stays centralized so every operation crosses the same helper authority boundary.
        // swiftlint:disable:next cyclomatic_complexity function_body_length
        private func handleRoutedRequest(_ request: HelperRequest) async throws -> HelperResponse? {
            switch request {
            case let .requestDecision(decisionRequest):
                _ = try await registry.ingest(decisionRequest.submission)
                if decisionRequest.kind == .approval, let approval = PendingHookDecision(request: decisionRequest).approval {
                    let rules = try await database.automationRules(enabledOnly: true)
                    switch OperationsRuleEngine.automation(
                        for: approval,
                        session: decisionRequest.submission.initialSession,
                        rules: rules
                    ) {
                    case let .allow(ruleID):
                        try await database.appendAudit(AuditEntry(
                            id: UUID(), category: "automation", action: "allowed.lowRisk",
                            targetID: approval.id.description,
                            metadata: JSONEncoder().encode(["ruleID": ruleID.uuidString.lowercased()]),
                            createdAt: now()
                        ))
                        return .decision(HookDecisionResult(
                            requestID: decisionRequest.requestID,
                            revision: decisionRequest.revision,
                            decision: .approve
                        ))
                    case .requireHuman:
                        break
                    }
                }
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
            case let .history(query):
                return try await .history(database.history(query))
            case let .analytics(query):
                let settings = try await database.privacySettings()
                guard settings.analyticsEnabled else {
                    return .failure(code: "analytics.disabled", safeMessage: "Analytics is disabled in privacy settings.")
                }
                return try await .analytics(database.analytics(query))
            case .listRules:
                return try await .rules(database.rules())
            case let .upsertRule(rule):
                try await database.upsertRule(rule)
                return .ruleSaved(rule)
            case let .deleteRule(id):
                return try await .ruleDeleted(database.deleteRule(id: id))
            case .activeAlerts:
                let snapshots = try await database.activeSessionSnapshots()
                let rules = try await database.alertRules(enabledOnly: true)
                return .activeAlerts(OperationsRuleEngine.alerts(
                    for: snapshots,
                    rules: rules,
                    clock: FixedAgentClock(now: now(), monotonicNanoseconds: 0)
                ))
            case .privacySettings:
                return try await .privacySettings(database.privacySettings())
            case let .savePrivacySettings(settings):
                try await database.savePrivacySettings(settings, at: now())
                return .privacySettings(settings)
            case .diagnostics:
                let report = try await database.diagnostics(at: now())
                let pendingCount = await decisions.pending().count
                let spoolCount = try await spool.pendingCount()
                let helperChecks = report.checks + [
                    DiagnosticCheck(
                        id: "helper.socket",
                        status: socketAcceptingConnections ? .healthy : .warning,
                        safeSummary: socketAcceptingConnections
                            ? "Hook socket is accepting connections."
                            : "Hook socket is not accepting connections."
                    ),
                    DiagnosticCheck(
                        id: "helper.spool",
                        status: spoolCount == 0 ? .healthy : .warning,
                        safeSummary: "Hook spool queue was checked."
                    ),
                    DiagnosticCheck(
                        id: "helper.decisions",
                        status: .healthy,
                        safeSummary: "\(pendingCount) decision requests are pending."
                    )
                ]
                return .diagnostics(DiagnosticsReport(
                    generatedAt: report.generatedAt, checks: helperChecks,
                    activeSessionCount: report.activeSessionCount,
                    persistedEventCount: report.persistedEventCount,
                    schemaVersion: report.schemaVersion
                ))
            case let .repair(action):
                return try await .repair(database.repair(action, now: now()))
            case let .deleteCompletedHistory(cutoff):
                return try await .dataDeletion(database.deleteCompletedHistory(endedBefore: cutoff))
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
