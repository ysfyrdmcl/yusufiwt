#if os(macOS)
    import AgentDomain
    import AgentPersistence
    import Foundation

    // The helper keeps request routing in one authority boundary.
    // swiftlint:disable:next type_body_length
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

        // Protocol routing is exhaustive so unsupported requests fail neutrally.
        // swiftlint:disable:next cyclomatic_complexity
        public func handle(_ request: HelperRequest) async -> HelperResponse {
            if shuttingDown {
                return .neutral(reason: .shuttingDown)
            }
            do {
                if let response = try await handleRoutedRequest(request) {
                    return response
                }
                switch request {
                case let .negotiateProtocol(supportedVersions):
                    guard let version = LocalIPCContract.negotiate(supportedVersions: supportedVersions) else {
                        return .neutral(reason: .unsupportedProtocol)
                    }
                    return .protocolNegotiated(version: version)
                case let .negotiate(supportedVersions):
                    guard supportedVersions.contains(LocalIPCContract.currentVersion) else {
                        return .neutral(reason: .unsupportedProtocol)
                    }
                    return .negotiated(version: LocalIPCContract.currentVersion)
                case .health:
                    try await registry.expireInactiveSessions(at: now())
                    return try await .health(health())
                case .heartbeat:
                    heartbeatSequence &+= 1
                    return .heartbeat(HelperHeartbeat(sequence: heartbeatSequence, emittedAt: now()))
                case let .submitEvent(submission):
                    let disposition = try await registry.ingest(submission)
                    await observeDecisionStatus(in: submission)
                    return .eventAccepted(disposition)
                case .requestDecision, .pendingDecisions, .decisionLifecycles, .resolveDecision,
                     .listSessions, .sessionSnapshot, .interruptCodexSession,
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
                        let result = await decisions.recordAutomaticResolution(.approve, for: decisionRequest)
                        try await persistDecisionStatus(
                            requestID: decisionRequest.requestID,
                            status: .sentToProvider
                        )
                        return .decision(result)
                    case .requireHuman:
                        break
                    }
                }
                return await decisions.wait(for: decisionRequest)
            case .pendingDecisions:
                return await .pendingDecisions(decisions.pending())
            case .decisionLifecycles:
                return await .decisionLifecycles(decisions.lifecycles())
            case let .resolveDecision(resolution):
                let disposition = await decisions.resolve(resolution)
                if disposition == .accepted {
                    try await persistDecisionStatus(requestID: resolution.requestID, status: .sentToProvider)
                    try await database.appendAudit(AuditEntry(
                        id: UUID(),
                        category: "decision",
                        action: "resolved.user",
                        targetID: resolution.requestID.uuidString.lowercased(),
                        metadata: JSONEncoder().encode([
                            "revision": String(resolution.revision),
                            "outcome": Self.safeOutcome(resolution.decision)
                        ]),
                        createdAt: now()
                    ))
                }
                return .decisionResolution(disposition)
            case let .listSessions(limit):
                return try await .sessionList(database.sessions(limit: limit))
            case let .sessionSnapshot(id):
                return try await .sessionSnapshot(database.session(id: id))
            case let .interruptCodexSession(id):
                return try await interruptCodexSession(id)
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

        private func persistDecisionStatus(requestID: UUID, status: ApprovalStatus) async throws {
            guard let submission = await decisions.statusSubmission(requestID: requestID, status: status, at: now()) else {
                return
            }
            _ = try await registry.ingest(submission)
        }

        private func observeDecisionStatus(in submission: HelperEventSubmission) async {
            let envelope = submission.envelope
            guard envelope.eventType == "approval.statusChanged"
                || envelope.eventType == "decision.statusChanged",
                let rawID = envelope.payload["id"]?.stringValue,
                let requestID = UUID(uuidString: rawID),
                let rawStatus = envelope.payload["status"]?.stringValue,
                let status = ApprovalStatus(rawValue: rawStatus)
            else { return }
            let revision: Int64? = if case let .number(value)? = envelope.payload["revision"],
                                      value.rounded() == value {
                Int64(value)
            } else {
                nil
            }
            await decisions.observeProviderStatus(requestID: requestID, revision: revision, status: status)
            if [.providerAcknowledged, .applied, .deniedApplied, .providerRejected, .cancelledByProvider,
                .expired, .superseded].contains(status) {
                try? await database.appendAudit(AuditEntry(
                    id: UUID(),
                    category: "provider",
                    action: "decision.\(status.rawValue)",
                    targetID: requestID.uuidString.lowercased(),
                    metadata: JSONEncoder().encode(["revision": revision.map(String.init) ?? "unknown"]),
                    createdAt: now()
                ))
            }
        }

        private static func safeOutcome(_ decision: HookDecision) -> String {
            switch decision {
            case .approve: "approve"
            case .deny: "deny"
            case .answerChoice, .answerChoices, .answerText, .confirm: "answer"
            case .requestPlanChanges: "requestPlanChanges"
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

        private func interruptCodexSession(_ id: SessionID) async throws -> HelperResponse {
            await recordStop(id, outcome: "requested")
            guard let session = try await database.session(id: id), session.adapterID.rawValue == "codex",
                  !session.state.isTerminal, let threadID = session.externalSessionID else {
                await recordStop(id, outcome: "inactiveOrInvalidTarget")
                return .codexInterruptRequested(false)
            }
            guard CodexDesktopControl().isAvailable else {
                await recordStop(id, outcome: "connectionUnavailable")
                return .codexInterruptRequested(false)
            }
            do {
                let requested = try await CodexDesktopControl().interrupt(threadID: threadID)
                await recordStop(id, outcome: requested ? "acknowledged" : "noActiveTurn")
                return .codexInterruptRequested(requested)
            } catch {
                await recordStop(id, outcome: "failed")
                throw error
            }
        }

        private func recordStop(_ id: SessionID, outcome: String) async {
            try? await database.appendAudit(AuditEntry(
                id: UUID(), category: "sessionControl", action: "stop.\(outcome)",
                targetID: id.description, metadata: Data("{}".utf8), createdAt: now()
            ))
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
