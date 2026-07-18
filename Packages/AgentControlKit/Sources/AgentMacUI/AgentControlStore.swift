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

    @MainActor
    @Observable
    // The observable store intentionally centralizes the dashboard's cached read models.
    // swiftlint:disable:next type_body_length
    public final class AgentControlStore {
        public private(set) var connectionState: HelperConnectionState = .loading
        public private(set) var sessions: [SessionListItem] = []
        public private(set) var pendingDecisions: [PendingHookDecision] = []
        public private(set) var selectedSession: AgentSession?
        public private(set) var selectedEvents: [PersistedSessionEvent] = []
        public private(set) var helperHealth: HelperHealth?
        public private(set) var acknowledgmentStatuses: [UUID: LocalAcknowledgmentStatus] = [:]
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

        public var attentionSessions: [SessionListItem] {
            sessions.filter { [.waitingApproval, .waitingInput, .failed].contains($0.state) }
        }

        public var retainsDataWhileOffline: Bool {
            connectionState == .offline && (!sessions.isEmpty || !pendingDecisions.isEmpty)
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
            refreshInterval: Duration = .seconds(2)
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

        public func refreshNow() async {
            do {
                let snapshot = try await transport.snapshot(sessionLimit: 1000)
                helperHealth = snapshot.health
                sessions = snapshot.sessions
                pendingDecisions = Self.uniqueDecisions(snapshot.pendingDecisions)
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

        public func resolve(_ decision: PendingHookDecision, as value: HookDecision) async -> DecisionResolutionDisposition {
            guard DecisionAvailability.evaluate(decision) == .actionable else {
                acknowledgmentStatuses[decision.requestID] = .expired
                return .expired
            }
            acknowledgmentStatuses[decision.requestID] = .sending
            do {
                let disposition = try await transport.resolve(HookDecisionResolution(
                    requestID: decision.requestID,
                    revision: decision.revision,
                    decision: value
                ))
                acknowledgmentStatuses[decision.requestID] = Self.acknowledgment(for: disposition)
                await refreshNow()
                return disposition
            } catch {
                acknowledgmentStatuses[decision.requestID] = .failed
                connectionState = .offline
                return .notFound
            }
        }

        @discardableResult
        public func handleNotificationResponse(
            _ response: MacNotificationResponse,
            now: Date = Date()
        ) async -> NotificationResponseDisposition {
            guard let decision = pendingDecisions.first(where: { $0.requestID == response.requestID }) else {
                return .notFound
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
            switch response.action {
            case .approve:
                guard decision.kind == .approval || decision.kind == .plan else {
                    acknowledgmentStatuses[response.requestID] = .rejected
                    return .rejected
                }
                _ = await resolve(decision, as: .approve)
                return .sent
            case .deny:
                guard decision.kind == .approval || decision.kind == .plan else {
                    acknowledgmentStatuses[response.requestID] = .rejected
                    return .rejected
                }
                _ = await resolve(decision, as: .deny)
                return .sent
            case .review:
                selectedSection = .inbox
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
            guard url.scheme == "agentcontrol", url.host == "navigation-result",
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
                case .active, .inbox, .integrations:
                    break
                }
                operationsError = nil
            } catch {
                // Older helpers can still serve the Phase 7/8 dashboard. Keep that
                // cached state usable while clearly scoping the unavailable surface.
                operationsError = "This feature requires the Phase 9 helper."
            }
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
            if let index = sessions.firstIndex(where: { $0.id == notification.sessionID }) {
                let current = sessions[index]
                sessions[index] = SessionListItem(
                    id: current.id,
                    projectName: current.projectName,
                    adapterID: current.adapterID,
                    state: notification.state,
                    lastMeaningfulEventAt: Date(),
                    snapshotRevision: notification.snapshotRevision
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
    }
#endif
