#if os(macOS)
    import AgentDomain
    import AgentLocalIPC
    import AgentPersistence
    import SwiftUI

    public struct DashboardView: View {
        @Bindable private var store: AgentControlStore
        @Bindable private var phase10: Phase10Coordinator

        public init(store: AgentControlStore, phase10: Phase10Coordinator = Phase10Coordinator()) {
            self.store = store
            self.phase10 = phase10
        }

        public var body: some View {
            NavigationSplitView {
                List(DashboardSection.allCases, selection: $store.selectedSection) { section in
                    Label(section.titleKey, systemImage: section.symbol)
                        .badge(section == .inbox ? store.pendingDecisions.count : 0)
                        .tag(section)
                }
                .navigationTitle("app.name")
                .accessibilityLabel("sidebar.accessibility")
            } detail: {
                VStack(spacing: 0) {
                    ConnectionBanner(store: store)
                    dashboardContent
                }
            }
            .frame(minWidth: 860, minHeight: 560)
            .task { store.start() }
            .onChange(of: store.selectedSection) { _, _ in
                Task { await store.refreshSelectedOperations() }
            }
            .sheet(isPresented: $phase10.isOnboardingPresented) {
                AgentControlOnboardingView(coordinator: phase10)
            }
        }

        @ViewBuilder
        private var dashboardContent: some View {
            if case .loading = store.connectionState, store.sessions.isEmpty {
                LoadingStateView()
            } else if case let .error(message) = store.connectionState, store.sessions.isEmpty {
                ErrorStateView(message: message) { await store.refreshNow() }
            } else {
                switch store.selectedSection {
                case .overview: OverviewView(store: store)
                case .active: ActiveSessionsView(store: store)
                case .inbox: InboxView(store: store)
                case .history: HistoryView(store: store)
                case .analytics: AnalyticsView(store: store)
                case .rules: RulesView(store: store)
                case .diagnostics: DiagnosticsView(store: store)
                case .privacy: PrivacySettingsView(store: store)
                case .integrations: IntegrationManagerView(coordinator: phase10)
                }
            }
        }
    }

    private struct ConnectionBanner: View {
        let store: AgentControlStore

        var body: some View {
            if store.connectionState == .offline {
                HStack {
                    Image(systemName: "wifi.slash")
                    Text(store.retainsDataWhileOffline ? "connection.offlineCached" : "connection.offline")
                    Spacer()
                    Button("action.retry") { Task { await store.refreshNow() } }
                }
                .font(.callout)
                .padding(.horizontal, AgentControlSpacing.page)
                .padding(.vertical, AgentControlSpacing.compact)
                .background(Color.orange.opacity(0.16))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private struct OverviewView: View {
        let store: AgentControlStore

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AgentControlSpacing.section) {
                    Text("overview.title")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: AgentControlSpacing.standard) {
                        MetricCard(title: "overview.active", value: store.activeSessions.count, symbol: "bolt.fill", color: .blue)
                        MetricCard(title: "overview.inbox", value: store.pendingDecisions.count, symbol: "tray.full.fill", color: .orange)
                        MetricCard(title: "overview.attention", value: store.attentionSessions.count, symbol: "exclamationmark.triangle.fill", color: .red)
                    }
                    if !store.activeAlerts.isEmpty {
                        Text("overview.alerts")
                            .font(.title2.bold())
                        ForEach(store.activeAlerts) { alert in
                            Label(
                                "\(alert.kind.rawValue) • \(Int(alert.observedDurationSeconds / 60)) min",
                                systemImage: "bell.badge.fill"
                            )
                            .foregroundStyle(.orange)
                            .agentCard()
                        }
                    }
                    Text("overview.recent")
                        .font(.title2.bold())
                    if store.sessions.isEmpty {
                        ContentUnavailableView("empty.sessions.title", systemImage: "rectangle.stack.badge.plus", description: Text("empty.sessions.message"))
                    } else {
                        ForEach(store.sessions.prefix(8), id: \.id) { session in
                            SessionRow(item: session)
                                .onTapGesture {
                                    store.selectedSection = .active
                                    store.selectSession(session.id)
                                }
                        }
                    }
                }
                .padding(AgentControlSpacing.page)
            }
        }
    }

    private struct MetricCard: View {
        let title: LocalizedStringKey
        let value: Int
        let symbol: String
        let color: Color

        var body: some View {
            HStack(spacing: AgentControlSpacing.standard) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(color)
                VStack(alignment: .leading) {
                    Text(value, format: .number).font(.title.bold()).monospacedDigit()
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity)
            .agentCard()
            .accessibilityElement(children: .combine)
        }
    }

    private struct ActiveSessionsView: View {
        @Bindable var store: AgentControlStore

        var body: some View {
            HSplitView {
                Group {
                    if store.activeSessions.isEmpty {
                        ContentUnavailableView("empty.active.title", systemImage: "bolt.slash", description: Text("empty.active.message"))
                    } else {
                        List(store.activeSessions, selection: $store.selectedSessionID) { session in
                            SessionRow(item: session)
                                .tag(session.id)
                        }
                        .onChange(of: store.selectedSessionID) { _, id in store.selectSession(id) }
                        .accessibilityLabel("active.list.accessibility")
                    }
                }
                .frame(minWidth: 340)
                SessionDetailView(store: store, session: store.selectedSession, events: store.selectedEvents)
                    .frame(minWidth: 400)
            }
            .navigationTitle("active.title")
        }
    }

    public struct SessionRow: View {
        public let item: SessionListItem

        public init(item: SessionListItem) {
            self.item = item
        }

        public var body: some View {
            let token = SessionStatusToken.token(for: item.state)
            HStack(spacing: AgentControlSpacing.standard) {
                Image(systemName: token.symbol)
                    .foregroundStyle(token.color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.projectName).font(.headline).lineLimit(1)
                    HStack {
                        Text(item.adapterID.rawValue.capitalized)
                        Text("•")
                        Text(token.titleKey)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.lastMeaningfulEventAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(item.projectName), \(item.adapterID.rawValue)"))
        }
    }

    private struct SessionDetailView: View {
        let store: AgentControlStore
        let session: AgentSession?
        let events: [PersistedSessionEvent]

        var body: some View {
            if let session {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AgentControlSpacing.section) {
                        VStack(alignment: .leading, spacing: AgentControlSpacing.compact) {
                            Text(session.project.name).font(.largeTitle.bold())
                            Label(session.adapterID.rawValue.capitalized, systemImage: "cpu")
                                .foregroundStyle(.secondary)
                            StatusBadge(state: session.state)
                            Button("action.openTerminal") { store.navigate(to: session) }
                            if let result = store.lastNavigationResult {
                                Label(
                                    "navigation.result.\(result.level.rawValue)",
                                    systemImage: result.level >= .window ? "scope" : "arrow.up.forward.app"
                                )
                                .font(.caption)
                                .foregroundStyle(result.level >= .window ? .green : .orange)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        Divider()
                        Text("session.timeline").font(.title2.bold())
                        if events.isEmpty {
                            Text("session.timeline.empty").foregroundStyle(.secondary)
                        }
                        ForEach(events, id: \.envelope.eventID) { event in
                            HStack(alignment: .top) {
                                Image(systemName: "circle.fill").font(.system(size: 6)).padding(.top, 6)
                                VStack(alignment: .leading) {
                                    Text(event.envelope.eventType).font(.body.monospaced())
                                    Text(event.envelope.occurredAt, style: .time).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(AgentControlSpacing.page)
                }
            } else {
                ContentUnavailableView("session.select.title", systemImage: "sidebar.right", description: Text("session.select.message"))
            }
        }
    }

    private struct InboxView: View {
        let store: AgentControlStore

        var body: some View {
            Group {
                if store.pendingDecisions.isEmpty {
                    ContentUnavailableView("empty.inbox.title", systemImage: "tray", description: Text("empty.inbox.message"))
                } else {
                    List(store.pendingDecisions, id: \.requestID) { decision in
                        DecisionRow(store: store, decision: decision)
                    }
                    .accessibilityLabel("inbox.list.accessibility")
                }
            }
            .navigationTitle("inbox.title")
        }
    }

    private struct StatusBadge: View {
        let state: SessionState

        var body: some View {
            let token = SessionStatusToken.token(for: state)
            Label(token.titleKey, systemImage: token.symbol)
                .font(.caption.bold())
                .foregroundStyle(token.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(token.color.opacity(0.12), in: Capsule())
        }
    }

    private struct LoadingStateView: View {
        var body: some View {
            VStack(spacing: AgentControlSpacing.standard) {
                ProgressView()
                Text("state.loading")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    private struct ErrorStateView: View {
        let message: String
        let retry: () async -> Void

        var body: some View {
            ContentUnavailableView {
                Label("state.error.title", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("action.retry") { Task { await retry() } }
            }
        }
    }

    private extension DashboardSection {
        var titleKey: LocalizedStringKey {
            switch self {
            case .overview: "sidebar.overview"
            case .active: "sidebar.active"
            case .inbox: "sidebar.inbox"
            case .history: "sidebar.history"
            case .analytics: "sidebar.analytics"
            case .rules: "sidebar.rules"
            case .diagnostics: "sidebar.diagnostics"
            case .privacy: "sidebar.privacy"
            case .integrations: "sidebar.integrations"
            }
        }

        var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .active: "bolt"
            case .inbox: "tray.full"
            case .history: "clock.arrow.circlepath"
            case .analytics: "chart.bar.xaxis"
            case .rules: "list.bullet.rectangle"
            case .diagnostics: "stethoscope"
            case .privacy: "hand.raised"
            case .integrations: "puzzlepiece.extension"
            }
        }
    }

#endif
