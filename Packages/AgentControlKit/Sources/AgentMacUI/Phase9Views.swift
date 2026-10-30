// Keep the existing operations views together, including privacy save feedback.
// swiftlint:disable file_length
#if os(macOS)
    import AgentDomain
    import AgentPersistence
    import AppKit
    import Charts
    import SwiftUI

    struct HistoryView: View {
        @Bindable var store: AgentControlStore
        @State private var searchText = ""
        @State private var stateFilter: HistoryStateFilter = .all

        init(store: AgentControlStore) {
            self.store = store
            _searchText = State(initialValue: store.historyQuery.searchText)
            _stateFilter = State(initialValue: HistoryStateFilter.allCases.first { $0.states == store.historyQuery.states } ?? .all)
        }

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    TextField("history.search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { search() }
                    Picker("history.state", selection: $stateFilter) {
                        ForEach(HistoryStateFilter.allCases) { filter in
                            Text(filter.titleKey).tag(filter)
                        }
                    }
                    .frame(width: 170)
                    Button("action.search", action: search)
                }
                .padding(AgentControlSpacing.page)

                if let error = store.operationsError {
                    OperationsErrorView(message: error)
                } else if store.historyPage.items.isEmpty {
                    ContentUnavailableView("history.empty", systemImage: "clock")
                } else {
                    List(store.historyPage.items) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.projectName).font(.headline)
                                (Text(item.adapterID.rawValue.capitalized)
                                    + Text(" • ")
                                    + Text(LocalizedStringKey(NotchPanelFormatting.stateTitleKey(item.state))))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(item.startedAt, style: .date)
                                HStack(spacing: 3) {
                                    Text(item.eventCount, format: .number)
                                    Text("history.events")
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.selectedSection = .active
                            store.selectSession(item.id)
                        }
                    }
                }
            }
            .navigationTitle("history.title")
        }

        private func search() {
            store.historyQuery.searchText = searchText
            store.historyQuery.states = stateFilter.states
            Task { await store.searchHistory() }
        }
    }

    private enum HistoryStateFilter: String, CaseIterable, Identifiable {
        case all, completed, failed, cancelled
        var id: String {
            rawValue
        }

        var states: Set<SessionState> {
            switch self {
            case .all: []
            case .completed: [.completed]
            case .failed: [.failed]
            case .cancelled: [.cancelled]
            }
        }

        var titleKey: LocalizedStringKey {
            LocalizedStringKey("history.filter." + rawValue)
        }
    }

    struct AnalyticsView: View {
        let store: AgentControlStore

        var body: some View {
            ScrollView {
                if let error = store.operationsError {
                    OperationsErrorView(message: error)
                } else if let summary = store.analyticsSummary {
                    LazyVStack(alignment: .leading, spacing: AgentControlSpacing.section) {
                        HStack {
                            AnalyticsMetric(title: "analytics.sessions", value: summary.totalSessions)
                            AnalyticsMetric(title: "analytics.completed", value: summary.completedSessions)
                            AnalyticsMetric(title: "analytics.failed", value: summary.failedSessions)
                            AnalyticsMetric(title: "analytics.approvals", value: summary.approvalRequests)
                        }
                        Chart(summary.buckets) { bucket in
                            BarMark(
                                x: .value("analytics.date", bucket.start, unit: .day),
                                y: .value("analytics.sessions", bucket.sessionCount)
                            )
                            .foregroundStyle(.blue)
                        }
                        .frame(minHeight: 280)
                        .accessibilityLabel("analytics.chart.accessibility")
                    }
                    .padding(AgentControlSpacing.page)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("analytics.title")
        }
    }

    private struct AnalyticsMetric: View {
        let title: LocalizedStringKey
        let value: Int
        var body: some View {
            VStack(alignment: .leading) {
                Text(value, format: .number).font(.title.bold()).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentCard()
        }
    }

    struct RulesView: View {
        let store: AgentControlStore
        @State private var showingAlertBuilder = false
        @State private var showingAutomationBuilder = false

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Button("rules.addAlert") { showingAlertBuilder = true }
                    Button("rules.addAutomation") { showingAutomationBuilder = true }
                    Spacer()
                    Label("rules.lowRiskOnly", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(AgentControlSpacing.page)
                if let error = store.operationsError {
                    OperationsErrorView(message: error)
                } else if store.operationsRules.isEmpty {
                    ContentUnavailableView("rules.empty", systemImage: "list.bullet.rectangle")
                } else {
                    List(store.operationsRules) { rule in
                        HStack {
                            Image(systemName: rule.isAutomation ? "bolt.shield" : "bell.badge")
                            VStack(alignment: .leading) {
                                Text(rule.name).font(.headline)
                                Text(rule.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(rule.isEnabled ? "action.disable" : "action.enable") {
                                Task { await store.saveRule(rule.settingEnabled(!rule.isEnabled)) }
                            }
                            Button("action.delete", role: .destructive) {
                                Task { await store.deleteRule(id: rule.id) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("rules.title")
            .sheet(isPresented: $showingAlertBuilder) {
                AlertRuleBuilder { rule in
                    Task { await store.saveRule(.alert(rule)) }
                    showingAlertBuilder = false
                }
            }
            .sheet(isPresented: $showingAutomationBuilder) {
                AutomationRuleBuilder { rule in
                    Task { await store.saveRule(.automation(rule)) }
                    showingAutomationBuilder = false
                }
            }
        }
    }

    private extension OperationsRule {
        var name: String {
            switch self {
            case let .alert(rule):
                rule.name
            case let .automation(rule):
                rule.name
            }
        }

        var isAutomation: Bool {
            if case .automation = self {
                true
            } else {
                false
            }
        }

        var isEnabled: Bool {
            switch self {
            case let .alert(rule):
                rule.isEnabled
            case let .automation(rule):
                rule.isEnabled
            }
        }

        func settingEnabled(_ enabled: Bool) -> OperationsRule {
            switch self {
            case var .alert(rule):
                rule.isEnabled = enabled
                rule.updatedAt = Date()
                return .alert(rule)
            case var .automation(rule):
                rule.isEnabled = enabled
                rule.updatedAt = Date()
                return .automation(rule)
            }
        }

        var detail: String {
            switch self {
            case let .alert(rule):
                "\(NotchPanelFormatting.alertTitle(rule.kind)) • \(Int(rule.thresholdSeconds / 60)) min"
            case let .automation(rule):
                rule.actionKinds.map { NotchPanelFormatting.automationTitle($0) }.sorted().joined(separator: ", ")
            }
        }
    }

    private struct AlertRuleBuilder: View {
        let save: (AlertRule) -> Void
        @State private var name = ""
        @State private var kind: SessionAlertKind = .longRunning
        @State private var minutes = 15

        var body: some View {
            Form {
                TextField("rules.name", text: $name)
                Picker("rules.condition", selection: $kind) {
                    ForEach(SessionAlertKind.allCases, id: \.self) {
                        Text(NotchPanelFormatting.alertTitle($0)).tag($0)
                    }
                }
                Stepper(value: $minutes, in: 1 ... 1440) {
                    Text("rules.minutes") + Text(" \(minutes)")
                }
                Button("action.save") {
                    save(AlertRule(name: name, kind: kind, thresholdSeconds: TimeInterval(minutes * 60)))
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding().frame(width: 420)
        }
    }

    private struct AutomationRuleBuilder: View {
        let save: (LowRiskAutomationRule) -> Void
        @State private var name = ""
        @State private var readFiles = true
        @State private var readOnlyTools = false

        var body: some View {
            Form {
                TextField("rules.name", text: $name)
                Toggle("rules.readFiles", isOn: $readFiles)
                Toggle("rules.readOnlyTools", isOn: $readOnlyTools)
                Text("rules.automationWarning").font(.caption).foregroundStyle(.secondary)
                Button("action.save") {
                    var kinds: Set<AutomationActionKind> = []
                    if readFiles {
                        kinds.insert(.readFile)
                    }
                    if readOnlyTools {
                        kinds.insert(.readOnlyTool)
                    }
                    save(LowRiskAutomationRule(name: name, actionKinds: kinds))
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!readFiles && !readOnlyTools))
            }
            .padding().frame(width: 420)
        }
    }

    struct DiagnosticsView: View {
        let store: AgentControlStore
        @State private var exportStatus: String?

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: AgentControlSpacing.section) {
                    if let error = store.operationsError {
                        OperationsErrorView(message: error)
                    } else if let report = store.diagnosticsReport {
                        ForEach(report.checks) { check in
                            Label(check.safeSummary, systemImage: check.status == .healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(check.status == .healthy ? .green : .orange)
                        }
                        Divider()
                        HStack {
                            Button("diagnostics.checkpoint") { Task { await store.repair(.checkpointDatabase) } }
                            Button("diagnostics.retention") { Task { await store.repair(.applyRetention) } }
                            Button("diagnostics.export") { export(report) }
                        }
                        if let result = store.lastRepairResult {
                            Text(result.safeMessage).font(.caption)
                        }
                        if let exportStatus {
                            Text(exportStatus).font(.caption)
                        }
                    } else {
                        ProgressView()
                    }
                }
                .padding(AgentControlSpacing.page)
            }
            .navigationTitle("diagnostics.title")
        }

        private func export(_ report: DiagnosticsReport) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "agentcontrol-diagnostics.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                let data = try RedactedDiagnosticExporter.export(
                    report: report,
                    includePrivateMetadata: store.privacy.includePrivateMetadataInDiagnostics
                )
                try data.write(to: url, options: .atomic)
                exportStatus = String(localized: "diagnostics.exported")
            } catch {
                exportStatus = String(localized: "diagnostics.exportFailed")
            }
        }
    }

    struct PrivacySettingsView: View {
        let store: AgentControlStore
        @State private var settings = PrivacySettings.privacyFirst
        @State private var showingDeleteConfirmation = false
        @State private var deletionMessage: String?

        var body: some View {
            Form {
                Toggle("privacy.analytics", isOn: $settings.analyticsEnabled)
                Stepper(value: $settings.retentionDays, in: 1 ... 3650) {
                    Text("privacy.retentionDays") + Text(" \(settings.retentionDays)")
                }
                Toggle("privacy.privateDiagnostics", isOn: $settings.includePrivateMetadataInDiagnostics)
                Toggle("privacy.promptContent", isOn: $settings.storePromptContent)
                Toggle("privacy.terminalOutput", isOn: $settings.storeTerminalOutput)
                HStack {
                    Button("action.save") { Task { await store.savePrivacy(settings) } }
                    Button("privacy.deleteHistory", role: .destructive) { showingDeleteConfirmation = true }
                }
                if let error = store.operationsError {
                    OperationsErrorView(message: error)
                }
                if let deletionMessage {
                    Text(deletionMessage).font(.caption)
                }
            }
            .padding(AgentControlSpacing.page)
            .navigationTitle("privacy.title")
            .task { settings = store.privacy }
            .onChange(of: store.privacy) { oldValue, value in
                if settings == oldValue {
                    settings = value
                }
            }
            .alert("privacy.deleteConfirm", isPresented: $showingDeleteConfirmation) {
                Button("action.delete", role: .destructive) {
                    Task {
                        let result = await store.deleteCompletedHistory(endedBefore: Date())
                        deletionMessage = result.map {
                            String(
                                format: String(localized: "privacy.deletedFormat"),
                                $0.deletedSessions, $0.deletedEvents
                            )
                        }
                    }
                }
                Button("action.cancel", role: .cancel) {}
            }
        }
    }

    private struct OperationsErrorView: View {
        let message: String
        var body: some View {
            ContentUnavailableView("state.error.title", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }
#endif
