// swiftlint:disable file_length
#if os(macOS)
    import AgentDomain
    import AgentLocalIPC
    import AgentPersistence
    import Foundation
    import Observation

    public enum DashboardSection: String, CaseIterable, Identifiable, Sendable {
        case overview
        case active
        case inbox
        case history
        case analytics
        case rules
        case diagnostics
        case privacy
        case integrations

        public var id: String {
            rawValue
        }
    }

    public enum HelperConnectionState: Sendable, Equatable {
        case loading
        case online
        case offline
        case error(String)
    }

    public enum NotificationResponseDisposition: Sendable, Equatable {
        case sent
        case reviewed
        case openedTerminal
        case notFound
        case superseded
        case expired
        case rejected
    }

    public enum NotificationRouteState: Sendable, Equatable {
        case selected(UUID)
        case inactive(SessionID?)
        case helperUnavailable
    }

    public struct ProviderIntegrationActivity: Sendable, Equatable {
        public let lastEventAt: Date?
        public let lastEventType: String?
        public let lastDecisionAt: Date?
        public let lastDecisionKind: HookDecisionKind?
        public let lastDecisionState: DecisionLifecycleState?
        public let lastProviderAcknowledgmentAt: Date?
        public let lastProviderAcknowledgmentState: DecisionLifecycleState?
        public let lastRedactedErrorKey: String?

        public init(
            lastEventAt: Date? = nil,
            lastEventType: String? = nil,
            lastDecisionAt: Date? = nil,
            lastDecisionKind: HookDecisionKind? = nil,
            lastDecisionState: DecisionLifecycleState? = nil,
            lastProviderAcknowledgmentAt: Date? = nil,
            lastProviderAcknowledgmentState: DecisionLifecycleState? = nil,
            lastRedactedErrorKey: String? = nil
        ) {
            self.lastEventAt = lastEventAt
            self.lastEventType = lastEventType
            self.lastDecisionAt = lastDecisionAt
            self.lastDecisionKind = lastDecisionKind
            self.lastDecisionState = lastDecisionState
            self.lastProviderAcknowledgmentAt = lastProviderAcknowledgmentAt
            self.lastProviderAcknowledgmentState = lastProviderAcknowledgmentState
            self.lastRedactedErrorKey = lastRedactedErrorKey
        }
    }

    @MainActor
    @Observable
    // The observable store intentionally centralizes the dashboard's cached read models.
    // swiftlint:disable:next type_body_length
    public final class AgentControlStore {
        public private(set) var connectionState: HelperConnectionState = .loading
        public private(set) var sessions: [SessionListItem] = []
        public private(set) var pendingDecisions: [PendingHookDecision] = []
        public private(set) var decisionLifecycles: [DecisionLifecycleSnapshot] = []
        public private(set) var selectedSession: AgentSession?
        public private(set) var selectedEvents: [PersistedSessionEvent] = []
        public private(set) var helperHealth: HelperHealth?
        public private(set) var acknowledgmentStatuses: [UUID: LocalAcknowledgmentStatus] = [:]
        public private(set) var selectedDecisionID: UUID?
        public private(set) var notificationRouteState: NotificationRouteState?
        public private(set) var integrationActivities: [String: ProviderIntegrationActivity] = [:]
        public private(set) var historyPage = HistoryPage(items: [], totalCount: 0)
        public private(set) var analyticsSummary: AnalyticsSummary?
        public private(set) var operationsRules: [OperationsRule] = []
        public private(set) var activeAlerts: [SessionAlert] = []
        public private(set) var privacy = PrivacySettings.privacyFirst
        public private(set) var diagnosticsReport: DiagnosticsReport?
        public private(set) var operationsError: String?
        public private(set) var lastRepairResult: RepairResult?
        public private(set) var lastNavigationResult: NavigationResult?
        private var pendingNavigationToken: String?
        public var historyQuery = HistoryQuery()
        public var selectedSection: DashboardSection = .overview
        public var selectedSessionID: SessionID?
        public var isPanelExpanded = false

        public var activeSessions: [SessionListItem] {
            sessions.filter { !$0.state.isTerminal }
        }

        /// Sessions that have produced a provider event recently enough to still be live.
        /// This keeps abandoned hook records from making the always-on notch look busy forever.
        public func liveSessions(
            at referenceDate: Date = Date(),
            inactivityLimit: TimeInterval = 20 * 60
        ) -> [SessionListItem] {
            activeSessions.filter {
                referenceDate.timeIntervalSince($0.lastMeaningfulEventAt) <= inactivityLimit
            }
        }

        public var attentionSessions: [SessionListItem] {
            sessions.filter { [.waitingApproval, .waitingInput, .failed].contains($0.state) }
        }

        public var decisionAwaitingProviderAcknowledgment: DecisionLifecycleSnapshot? {
            decisionLifecycles.first {
                $0.state == .userResolvedAwaitingProviderAck
                    || $0.state == .automaticallyResolvedAwaitingProviderAck
                    || $0.state == .providerAcknowledged
            }
        }

        public var retainsDataWhileOffline: Bool {
            connectionState == .offline && (!sessions.isEmpty || !pendingDecisions.isEmpty)
        }

        public func usagePresentation(
            at referenceDate: Date = Date(),
            staleAfter: TimeInterval = SessionUsageMetric.defaultStaleAfter
        ) -> SessionUsagePresentation {
            let session: SessionListItem? = if let selectedSessionID {
                sessions.first { $0.id == selectedSessionID }
            } else {
                activeSessions.max { $0.lastMeaningfulEventAt < $1.lastMeaningfulEventAt }
            }
            return SessionUsagePresentation(session: session, at: referenceDate, staleAfter: staleAfter)
        }

        private let transport: any AgentControlTransport
        private let notificationCoordinator: MacNotificationCoordinator?
        private let navigator: any TerminalNavigating
        private let refreshInterval: Duration
        private var refreshTask: Task<Void, Never>?
        private var notificationTask: Task<Void, Never>?

        public init(
            transport: any AgentControlTransport = XPCAgentControlTransport(),
            notificationCoordinator: MacNotificationCoordinator? = nil,
            navigator: (any TerminalNavigating)? = nil,
            refreshInterval: Duration = .seconds(10)
        ) {
            self.transport = transport
            self.notificationCoordinator = notificationCoordinator
            self.navigator = navigator ?? TerminalNavigationCoordinator()
            self.refreshInterval = refreshInterval
        }

        public func start() {
            guard refreshTask == nil else { return }
            connectionState = .loading
            refreshTask = Task { [weak self] in
                await self?.refreshLoop()
            }
            notificationTask = Task { [weak self, transport] in
                let stream = await transport.notifications()
                for await notification in stream {
                    guard !Task.isCancelled else { break }
                    await self?.consume(notification)
                }
            }
        }

        public func stop() {
            refreshTask?.cancel()
            notificationTask?.cancel()
            refreshTask = nil
            notificationTask = nil
            Task { [transport] in await transport.disconnect() }
        }

        #if DEBUG
            public func loadNotchDemo(now: Date = Date()) {
                stop()
                connectionState = .online
                pendingDecisions = []
                activeAlerts = []
                selectedSession = nil
                selectedEvents = []
                sessions = [
                    SessionListItem(
                        id: SessionID(UUID()),
                        projectName: "yusufiwt · Polish the live notch panel",
                        adapterID: AdapterID("codex"),
                        state: .executing,
                        startedAt: now.addingTimeInterval(-31 * 60),
                        lastMeaningfulEventAt: now.addingTimeInterval(-4),
                        snapshotRevision: 3
                    ),
                    SessionListItem(
                        id: SessionID(UUID()),
                        projectName: "website · Verify responsive layout",
                        adapterID: AdapterID("claude"),
                        state: .thinking,
                        startedAt: now.addingTimeInterval(-42),
                        lastMeaningfulEventAt: now.addingTimeInterval(-2),
                        snapshotRevision: 2
                    )
                ]
            }

            public func resumeLiveData() {
                sessions = []
                pendingDecisions = []
                connectionState = .loading
                start()
            }
        #endif

        public func refreshNow() async {
            do {
                let snapshot = try await transport.snapshot(sessionLimit: 1000)
                helperHealth = snapshot.health
                sessions = snapshot.sessions
                pendingDecisions = Self.uniqueDecisions(snapshot.pendingDecisions)
                decisionLifecycles = snapshot.decisionLifecycles
                synchronizeAcknowledgmentStatuses()
                connectionState = .online
                await notificationCoordinator?.reconcile(pendingDecisions)
                if let alerts = try? await transport.alerts() {
                    activeAlerts = alerts
                    await notificationCoordinator?.reconcile(alerts)
                }
                if let selectedSessionID {
                    await loadSession(id: selectedSessionID)
                }
                await refreshSelectedOperations()
            } catch is CancellationError {
                return
            } catch {
                connectionState = sessions.isEmpty && pendingDecisions.isEmpty
                    ? .error(Self.safeMessage(error))
                    : .offline
            }
        }

        public func selectSession(_ id: SessionID?) {
            selectedSessionID = id
            guard let id else {
                selectedSession = nil
                selectedEvents = []
                return
            }
            Task { [weak self] in await self?.loadSession(id: id) }
        }

        public func selectDecision(_ requestID: UUID) {
            guard pendingDecisions.contains(where: { $0.requestID == requestID }) else { return }
            selectedDecisionID = requestID
            notificationRouteState = .selected(requestID)
            moveDecisionToFront(requestID)
        }

        public func resolve(_ decision: PendingHookDecision, as value: HookDecision) async -> DecisionResolutionDisposition {
            guard DecisionAvailability.evaluate(decision) == .actionable else {
                acknowledgmentStatuses[decision.requestID] = .expired
                return .expired
            }
            guard acknowledgmentStatuses[decision.requestID] != .sending else { return .notFound }
            acknowledgmentStatuses[decision.requestID] = .sending
            do {
                let disposition = try await transport.resolve(HookDecisionResolution(
                    requestID: decision.requestID,
                    revision: decision.revision,
                    decision: value
                ))
                acknowledgmentStatuses[decision.requestID] = Self.acknowledgment(for: disposition)
                if disposition == .accepted || disposition == .expired || disposition == .revisionMismatch {
                    notificationCoordinator?.remove(
                        requestID: decision.requestID,
                        revision: decision.revision,
                        kind: decision.kind
                    )
                }
                await refreshNow()
                return disposition
            } catch {
                acknowledgmentStatuses[decision.requestID] = .failed
                connectionState = .offline
                return .notFound
            }
        }

        @discardableResult
        // Notification actions cross availability, revision, privacy, and helper-state gates.
        // swiftlint:disable:next cyclomatic_complexity function_body_length
        public func handleNotificationResponse(
            _ response: MacNotificationResponse,
            now: Date = Date()
        ) async -> NotificationResponseDisposition {
            await refreshNow()
            if response.action == .approve || response.action == .deny, connectionState != .online {
                notificationRouteState = .helperUnavailable
                acknowledgmentStatuses[response.requestID] = .rejected
                return .rejected
            }
            guard let decision = pendingDecisions.first(where: { $0.requestID == response.requestID }) else {
                selectedDecisionID = nil
                notificationRouteState = .inactive(response.sessionID)
                if let sessionID = response.sessionID {
                    selectSession(sessionID)
                }
                if let kind = response.kind {
                    notificationCoordinator?.remove(
                        requestID: response.requestID,
                        revision: response.revision,
                        kind: kind
                    )
                }
                return .notFound
            }
            if let kind = response.kind, kind != decision.kind {
                acknowledgmentStatuses[response.requestID] = .rejected
                return .rejected
            }
            guard decision.revision == response.revision else {
                acknowledgmentStatuses[response.requestID] = .superseded
                return .superseded
            }
            guard DecisionAvailability.evaluate(decision, now: now) != .expired else {
                acknowledgmentStatuses[response.requestID] = .expired
                return .expired
            }
            let isSecret = DecisionAvailability.evaluate(decision, now: now) == .secretRequiresTerminal
            guard !isSecret || response.action == .openTerminal || response.action == .review else {
                acknowledgmentStatuses[response.requestID] = .rejected
                return .rejected
            }
            if response.action == .approve || response.action == .deny {
                let category = MacNotificationCoordinator.category(for: decision)
                guard category == .approval || category == .plan else {
                    acknowledgmentStatuses[response.requestID] = .rejected
                    return .rejected
                }
            }
            switch response.action {
            case .approve:
                guard decision.kind == .approval || decision.kind == .plan else {
                    acknowledgmentStatuses[response.requestID] = .rejected
                    return .rejected
                }
                return await Self.notificationDisposition(for: resolve(decision, as: .approve))
            case .deny:
                guard decision.kind == .approval || decision.kind == .plan else {
                    acknowledgmentStatuses[response.requestID] = .rejected
                    return .rejected
                }
                return await Self.notificationDisposition(for: resolve(decision, as: .deny))
            case .review:
                selectedSection = .inbox
                selectedDecisionID = decision.requestID
                notificationRouteState = .selected(decision.requestID)
                moveDecisionToFront(decision.requestID)
                return .reviewed
            case .openTerminal:
                pendingNavigationToken = decision.terminalContext?.correlationToken
                lastNavigationResult = await navigator.navigate(
                    context: decision.terminalContext,
                    projectURL: decision.projectRootURL
                )
                return .openedTerminal
            }
        }

        public func openTerminal(for decision: PendingHookDecision) {
            pendingNavigationToken = decision.terminalContext?.correlationToken
            Task { [weak self, navigator] in
                let result = await navigator.navigate(
                    context: decision.terminalContext,
                    projectURL: decision.projectRootURL
                )
                self?.lastNavigationResult = result
            }
        }

        public func navigate(to session: AgentSession) {
            pendingNavigationToken = session.terminalContext?.correlationToken
            Task { [weak self, navigator] in
                let result = await navigator.navigate(
                    context: session.terminalContext,
                    projectURL: session.project.rootURL
                )
                self?.lastNavigationResult = result
            }
        }

        public func handleNavigationCallback(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), ["agentcontrol", "yusufiwt"].contains(scheme),
                  url.host == "navigation-result",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
                  token == pendingNavigationToken,
                  let value = components.queryItems?.first(where: { $0.name == "level" })?.value,
                  let level = NavigationResultLevel(rawValue: value)
            else { return }
            lastNavigationResult = NavigationResult(
                level: level,
                applicationBundleID: lastNavigationResult?.applicationBundleID,
                mechanism: "extension-callback",
                reason: level >= .window ? nil : .exactTargetUnavailable
            )
            pendingNavigationToken = nil
        }

        public func refreshSelectedOperations() async {
            do {
                switch selectedSection {
                case .overview:
                    activeAlerts = try await transport.alerts()
                case .history:
                    historyPage = try await transport.history(historyQuery)
                case .analytics:
                    let now = Date()
                    analyticsSummary = try await transport.analytics(AnalyticsQuery(
                        from: Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now,
                        endDate: now
                    ))
                case .rules:
                    operationsRules = try await transport.rules()
                case .diagnostics:
                    diagnosticsReport = try await transport.diagnostics()
                case .privacy:
                    privacy = try await transport.privacySettings()
                case .integrations:
                    await refreshIntegrationActivities()
                case .active, .inbox:
                    break
                }
                operationsError = nil
            } catch {
                // Older helpers can still serve the Phase 7/8 dashboard. Keep that
                // cached state usable while clearly scoping the unavailable surface.
                operationsError = "This feature requires the Phase 9 helper."
            }
        }

        public func integrationActivity(provider: String) -> ProviderIntegrationActivity {
            integrationActivities[provider] ?? ProviderIntegrationActivity()
        }

        private func refreshIntegrationActivities() async {
            var activities: [String: ProviderIntegrationActivity] = [:]
            for provider in ["codex", "claude", "gemini", "cursor"] {
                let providerSessions = sessions
                    .filter { $0.adapterID.rawValue == provider }
                    .sorted { $0.lastMeaningfulEventAt > $1.lastMeaningfulEventAt }
                let session = providerSessions.first
                var events: [PersistedSessionEvent] = []
                for item in providerSessions.prefix(20) {
                    await events += (try? transport.events(sessionID: item.id, limit: 500)) ?? []
                }
                let lastEvent = events.max { $0.envelope.occurredAt < $1.envelope.occurredAt }
                let lifecycles = decisionLifecycles.filter { $0.provider == provider }
                let lastDecision = lifecycles.max { $0.updatedAt < $1.updatedAt }
                let lastAcknowledgment = lifecycles
                    .filter {
                        $0.state == .providerAcknowledged || $0.state == .applied
                            || $0.state == .deniedApplied || $0.state == .providerRejected
                            || $0.state == .cancelled
                    }
                    .max { $0.updatedAt < $1.updatedAt }
                let persistedDecision = events
                    .compactMap(Self.persistedDecisionActivity)
                    .max { $0.date < $1.date }
                let persistedAcknowledgment = events
                    .compactMap(Self.persistedAcknowledgmentActivity)
                    .max { $0.date < $1.date }
                activities[provider] = ProviderIntegrationActivity(
                    lastEventAt: lastEvent?.envelope.occurredAt ?? session?.lastMeaningfulEventAt,
                    lastEventType: lastEvent?.envelope.eventType,
                    lastDecisionAt: lastDecision?.updatedAt ?? persistedDecision?.date,
                    lastDecisionKind: lastDecision?.kind ?? persistedDecision?.kind,
                    lastDecisionState: lastDecision?.state ?? persistedDecision?.state,
                    lastProviderAcknowledgmentAt: lastAcknowledgment?.updatedAt ?? persistedAcknowledgment?.date,
                    lastProviderAcknowledgmentState: lastAcknowledgment?.state ?? persistedAcknowledgment?.state,
                    lastRedactedErrorKey: session?.state == .failed
                        ? "integrations.error.providerReportedFailure"
                        : nil
                )
            }
            integrationActivities = activities
        }

        private struct PersistedDecisionActivity {
            let date: Date
            let kind: HookDecisionKind
            let state: DecisionLifecycleState
        }

        private static func persistedDecisionActivity(
            _ item: PersistedSessionEvent
        ) -> PersistedDecisionActivity? {
            let kind: HookDecisionKind
            switch item.envelope.eventType {
            case "approval.requested": kind = .approval
            case "question.requested": kind = .question
            case "plan.reviewRequested": kind = .plan
            default: return nil
            }
            return PersistedDecisionActivity(
                date: item.envelope.occurredAt,
                kind: kind,
                state: .awaitingUser
            )
        }

        private static func persistedAcknowledgmentActivity(
            _ item: PersistedSessionEvent
        ) -> (date: Date, state: DecisionLifecycleState)? {
            guard item.envelope.eventType == "approval.statusChanged"
                || item.envelope.eventType == "decision.statusChanged",
                let value = item.envelope.payload["status"]?.stringValue,
                let status = ApprovalStatus(rawValue: value)
            else { return nil }
            let state: DecisionLifecycleState? = switch status {
            case .providerAcknowledged: .providerAcknowledged
            case .applied: .applied
            case .deniedApplied: .deniedApplied
            case .expired: .expired
            case .superseded: .superseded
            case .cancelledByProvider: .cancelled
            case .providerRejected, .policyRejected, .deliveryFailed: .providerRejected
            case .received, .classified, .presented, .userDecisionPending,
                 .signedDecisionReceived, .policyValidated, .sentToProvider:
                nil
            }
            return state.map { (item.envelope.occurredAt, $0) }
        }

        public func searchHistory() async {
            historyQuery.offset = 0
            do {
                historyPage = try await transport.history(historyQuery)
                operationsError = nil
            } catch {
                operationsError = Self.safeMessage(error)
            }
        }

        public func saveRule(_ rule: OperationsRule) async {
            do {
                try await transport.saveRule(rule)
                operationsRules = try await transport.rules()
                activeAlerts = try await transport.alerts()
                operationsError = nil
            } catch {
                operationsError = Self.safeMessage(error)
            }
        }

        public func deleteRule(id: UUID) async {
            do {
                _ = try await transport.deleteRule(id: id)
                operationsRules = try await transport.rules()
                operationsError = nil
            } catch {
                operationsError = Self.safeMessage(error)
            }
        }

        public func savePrivacy(_ value: PrivacySettings) async {
            do {
                try await transport.savePrivacySettings(value)
                privacy = try await transport.privacySettings()
                operationsError = nil
            } catch {
                operationsError = Self.safeMessage(error)
            }
        }

        public func repair(_ action: RepairAction) async {
            do {
                lastRepairResult = try await transport.repair(action)
                diagnosticsReport = try await transport.diagnostics()
                operationsError = nil
            } catch {
                operationsError = Self.safeMessage(error)
            }
        }

        public func deleteCompletedHistory(endedBefore cutoff: Date) async -> DataDeletionResult? {
            do {
                let result = try await transport.deleteCompletedHistory(endedBefore: cutoff)
                await refreshNow()
                return result
            } catch {
                operationsError = Self.safeMessage(error)
                return nil
            }
        }

        private func refreshLoop() async {
            while !Task.isCancelled {
                await refreshNow()
                do {
                    try await Task.sleep(for: refreshInterval)
                } catch {
                    break
                }
            }
        }

        private func consume(_ notification: RegistryNotification) async {
            let projectName = sessions.first(where: { $0.id == notification.sessionID })?.projectName
            await notificationCoordinator?.reconcile(notification, projectName: projectName)
            if let index = sessions.firstIndex(where: { $0.id == notification.sessionID }) {
                let current = sessions[index]
                sessions[index] = SessionListItem(
                    id: current.id,
                    projectName: current.projectName,
                    adapterID: current.adapterID,
                    state: notification.state,
                    startedAt: current.startedAt,
                    lastMeaningfulEventAt: Date(),
                    snapshotRevision: notification.snapshotRevision,
                    usageMetrics: current.usageMetrics
                )
            }
            await refreshNow()
        }

        private func loadSession(id: SessionID) async {
            do {
                async let session = transport.session(id: id)
                async let events = transport.events(sessionID: id, limit: 500)
                selectedSession = try await session
                selectedEvents = try await events
            } catch {
                if sessions.isEmpty {
                    connectionState = .error(Self.safeMessage(error))
                }
            }
        }

        private static func safeMessage(_ error: any Error) -> String {
            if let localError = error as? LocalIPCError {
                return localError.description
            }
            return "The helper is unavailable."
        }

        private static func uniqueDecisions(_ decisions: [PendingHookDecision]) -> [PendingHookDecision] {
            let newest = Dictionary(grouping: decisions, by: \.requestID).compactMap { _, values in
                values.max { $0.revision < $1.revision }
            }
            return newest.sorted {
                ($0.expiresAt ?? .distantFuture, $0.requestID.uuidString)
                    < ($1.expiresAt ?? .distantFuture, $1.requestID.uuidString)
            }
        }

        private static func acknowledgment(for disposition: DecisionResolutionDisposition) -> LocalAcknowledgmentStatus {
            switch disposition {
            case .accepted: .sentToProvider
            case .expired: .expired
            case .revisionMismatch: .superseded
            case .invalidDecision: .rejected
            case .notFound: .failed
            }
        }

        private static func notificationDisposition(
            for disposition: DecisionResolutionDisposition
        ) -> NotificationResponseDisposition {
            switch disposition {
            case .accepted: .sent
            case .expired: .expired
            case .revisionMismatch: .superseded
            case .invalidDecision: .rejected
            case .notFound: .notFound
            }
        }

        // Exhaustive lifecycle-to-UI acknowledgment mapping stays explicit.
        // swiftlint:disable:next cyclomatic_complexity
        private func synchronizeAcknowledgmentStatuses() {
            for lifecycle in decisionLifecycles {
                guard lifecycle.state != .awaitingUser else { continue }
                let status: LocalAcknowledgmentStatus = switch lifecycle.state {
                case .awaitingUser: .failed // Unreachable after the guard above.
                case .userResolvedAwaitingProviderAck: .sentToProvider
                case .automaticallyResolvedAwaitingProviderAck: .automaticallySentToProvider
                case .providerAcknowledged: .providerAcknowledged
                case .applied: .applied
                case .deniedApplied: .deniedApplied
                case .expired: .expired
                case .cancelled: .cancelled
                case .superseded: .superseded
                case .providerRejected: .rejected
                }
                acknowledgmentStatuses[lifecycle.requestID] = status
            }
        }

        private func moveDecisionToFront(_ requestID: UUID) {
            guard let index = pendingDecisions.firstIndex(where: { $0.requestID == requestID }), index != 0 else { return }
            let decision = pendingDecisions.remove(at: index)
            pendingDecisions.insert(decision, at: 0)
        }
    }
#endif
