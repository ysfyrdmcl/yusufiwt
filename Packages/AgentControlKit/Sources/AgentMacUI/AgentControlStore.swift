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
    public final class AgentControlStore {
        public private(set) var connectionState: HelperConnectionState = .loading
        public private(set) var sessions: [SessionListItem] = []
        public private(set) var pendingDecisions: [PendingHookDecision] = []
        public private(set) var selectedSession: AgentSession?
        public private(set) var selectedEvents: [PersistedSessionEvent] = []
        public private(set) var helperHealth: HelperHealth?
        public private(set) var acknowledgmentStatuses: [UUID: LocalAcknowledgmentStatus] = [:]
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
        private let refreshInterval: Duration
        private var refreshTask: Task<Void, Never>?
        private var notificationTask: Task<Void, Never>?

        public init(
            transport: any AgentControlTransport = XPCAgentControlTransport(),
            notificationCoordinator: MacNotificationCoordinator? = nil,
            refreshInterval: Duration = .seconds(2)
        ) {
            self.transport = transport
            self.notificationCoordinator = notificationCoordinator
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
                if let selectedSessionID {
                    await loadSession(id: selectedSessionID)
                }
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
                TerminalFallback.open(for: decision)
                return .openedTerminal
            }
        }

        public func openTerminal(for decision: PendingHookDecision) {
            TerminalFallback.open(for: decision)
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
