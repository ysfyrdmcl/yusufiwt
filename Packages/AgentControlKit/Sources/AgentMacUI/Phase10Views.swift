#if os(macOS)
    import AgentDomain
    import AgentHookKit
    import AppKit
    import SwiftUI

    public struct IntegrationManagerView: View {
        @Bindable var coordinator: Phase10Coordinator
        @State private var previewProvider: HookProvider?

        public init(coordinator: Phase10Coordinator) {
            self.coordinator = coordinator
        }

        public var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AgentControlSpacing.section) {
                    HStack {
                        Text("integrations.title").font(.largeTitle.bold())
                        Spacer()
                        Button("action.retry") { Task { await coordinator.refreshIntegrations() } }
                    }
                    ForEach(coordinator.integrations) { record in
                        integrationCard(record)
                    }
                    Divider()
                    Text("integrations.terminals").font(.title2.bold())
                    if coordinator.detectedTerminals.isEmpty {
                        Text("integrations.terminals.none").foregroundStyle(.secondary)
                    } else {
                        ForEach(coordinator.detectedTerminals, id: \.self) { terminal in
                            Label(terminal.title, systemImage: "terminal")
                        }
                    }
                    if let message = coordinator.message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .padding(AgentControlSpacing.page)
            }
            .task { await coordinator.refreshIntegrations() }
            .sheet(isPresented: Binding(
                get: { previewProvider != nil },
                set: {
                    if !$0 {
                        previewProvider = nil
                    }
                }
            )) {
                if let provider = previewProvider {
                    IntegrationDiffView(provider: provider, preview: coordinator.previews[provider])
                        .task { await coordinator.preview(provider) }
                }
            }
        }

        private func integrationCard(_ record: AgentIntegrationRecord) -> some View {
            VStack(alignment: .leading, spacing: AgentControlSpacing.compact) {
                HStack {
                    Label(record.provider.rawValue.capitalized, systemImage: "cpu")
                        .font(.headline)
                    Spacer()
                    Text("integration.state.\(record.state.rawValue)")
                        .font(.caption.bold())
                }
                LabeledContent("integrations.version", value: record.detectedVersion?.description ?? "—")
                LabeledContent("integrations.config", value: record.configURL.path)
                LabeledContent(
                    "integrations.capabilities",
                    value: record.capabilities.supported.map(\.rawValue).sorted().joined(separator: ", ")
                )
                if let warning = record.compatibilityWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                HStack {
                    Button("integrations.viewChanges") { previewProvider = record.provider }
                    Button("integrations.test") { Task { await coordinator.testIntegration() } }
                    Button("integrations.repair") { Task { await coordinator.repair(record.provider) } }
                        .disabled(record.detectedVersion == nil)
                    Button("integrations.restore") { Task { await coordinator.restoreBackup(record.provider) } }
                    Button("integrations.uninstall", role: .destructive) {
                        Task { await coordinator.uninstall(record.provider) }
                    }
                    .disabled(record.state == .notInstalled)
                }
            }
            .agentCard()
        }
    }

    public struct AgentControlOnboardingView: View {
        @Bindable var coordinator: Phase10Coordinator

        public init(coordinator: Phase10Coordinator) {
            self.coordinator = coordinator
        }

        public var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Label("onboarding.title", systemImage: "bolt.shield")
                        .font(.title2.bold())
                    Spacer()
                    Text("\(stepNumber)/7").foregroundStyle(.secondary)
                }
                .padding()
                Divider()
                Group { stepContent }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(28)
                Divider()
                HStack {
                    Button("action.cancel") { coordinator.cancelOnboarding() }
                    Spacer()
                    if coordinator.busy {
                        ProgressView().controlSize(.small)
                    }
                    primaryAction
                }
                .padding()
            }
            .frame(width: 720, height: 590)
            .interactiveDismissDisabled()
        }

        @ViewBuilder
        private var stepContent: some View {
            switch coordinator.onboardingStep {
            case .welcome:
                onboardingPage(
                    title: "onboarding.welcome.title",
                    message: "onboarding.welcome.message",
                    symbol: "macbook.and.iphone"
                )
            case .mode:
                VStack(alignment: .leading, spacing: 18) {
                    pageTitle("onboarding.mode.title", symbol: "network")
                    Picker("onboarding.mode.title", selection: Binding(
                        get: { coordinator.workingMode },
                        set: { coordinator.setMode($0) }
                    )) {
                        Text("onboarding.mode.local").tag(AgentControlWorkingMode.localOnly)
                        Text("onboarding.mode.personal").tag(AgentControlWorkingMode.personalRemote)
                        Text("onboarding.mode.selfHosted").tag(AgentControlWorkingMode.selfHostedRemote)
                    }
                    .pickerStyle(.radioGroup)
                    if coordinator.workingMode != .localOnly {
                        Label("onboarding.mode.remoteDeferred", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            case .coreServices:
                VStack(alignment: .leading, spacing: 18) {
                    pageTitle("onboarding.core.title", symbol: "gearshape.2")
                    Text("onboarding.core.message")
                    Label("onboarding.core.helper", systemImage: "checkmark.shield")
                    Label("onboarding.core.notifications", systemImage: "bell")
                }
            case .discovery:
                VStack(alignment: .leading, spacing: 18) {
                    pageTitle("onboarding.discovery.title", symbol: "magnifyingglass")
                    Text("onboarding.discovery.message")
                }
            case .review:
                VStack(alignment: .leading, spacing: 14) {
                    pageTitle("onboarding.review.title", symbol: "doc.text.magnifyingglass")
                    Text("onboarding.review.message")
                    ForEach(coordinator.integrations.filter { $0.detectedVersion != nil }) { record in
                        Toggle(isOn: Binding(
                            get: { coordinator.selectedProviders.contains(record.provider) },
                            set: { selected in
                                if selected {
                                    coordinator.selectedProviders.insert(record.provider)
                                } else {
                                    coordinator.selectedProviders.remove(record.provider)
                                }
                                Task { await coordinator.preparePreviews() }
                            }
                        )) {
                            VStack(alignment: .leading) {
                                Text(record.provider.rawValue.capitalized).font(.headline)
                                Text(record.configURL.path).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ScrollView {
                        Text(coordinator.previews.values.map(\.diff).filter { !$0.isEmpty }.joined(separator: "\n\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                .task { await coordinator.preparePreviews() }
            case .navigation:
                VStack(alignment: .leading, spacing: 18) {
                    pageTitle("onboarding.navigation.title", symbol: "arrow.up.forward.app")
                    Text("onboarding.navigation.message")
                    Button("onboarding.navigation.accessibility") { coordinator.enableAccessibilityNavigation() }
                    ForEach(coordinator.detectedTerminals.filter { [.terminal, .iTerm2, .ghostty].contains($0) }, id: \.self) { app in
                        Button("\(String(localized: "onboarding.navigation.automation")) \(app.title)") {
                            coordinator.requestAutomation(for: app)
                        }
                    }
                    Text("onboarding.navigation.optional").font(.caption).foregroundStyle(.secondary)
                }
            case .verification:
                VStack(alignment: .leading, spacing: 18) {
                    pageTitle("onboarding.verify.title", symbol: "checkmark.circle")
                    Text("onboarding.verify.message")
                    if coordinator.testEventSucceeded {
                        Label("onboarding.verify.success", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    if let message = coordinator.message {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("onboarding.verify.monitorOnly") { coordinator.continueMonitorOnly() }
                    }
                }
            }
        }

        @ViewBuilder
        private var primaryAction: some View {
            switch coordinator.onboardingStep {
            case .welcome:
                Button("onboarding.continue") { coordinator.setStep(.mode) }.keyboardShortcut(.defaultAction)
            case .mode:
                Button("onboarding.continue") { coordinator.setStep(.coreServices) }.keyboardShortcut(.defaultAction)
            case .coreServices:
                Button("onboarding.core.configure") { Task { await coordinator.configureCoreServices() } }
                    .keyboardShortcut(.defaultAction)
            case .discovery:
                Button("onboarding.discovery.scan") { Task { await coordinator.discover() } }
                    .keyboardShortcut(.defaultAction)
            case .review:
                Button("onboarding.review.install") { Task { await coordinator.installSelected() } }
                    .keyboardShortcut(.defaultAction)
            case .navigation:
                Button("onboarding.continue") { coordinator.skipNavigationPermissions() }.keyboardShortcut(.defaultAction)
            case .verification:
                Button("onboarding.verify.test") { Task { await coordinator.verifyTestEvent() } }
                    .keyboardShortcut(.defaultAction)
            }
        }

        private var stepNumber: Int {
            (OnboardingStep.allCases.firstIndex(of: coordinator.onboardingStep) ?? 0) + 1
        }

        private func onboardingPage(title: LocalizedStringKey, message: LocalizedStringKey, symbol: String) -> some View {
            VStack(spacing: 20) {
                Image(systemName: symbol).font(.system(size: 58)).foregroundStyle(.tint)
                Text(title).font(.largeTitle.bold())
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
        }

        private func pageTitle(_ title: LocalizedStringKey, symbol: String) -> some View {
            Label(title, systemImage: symbol).font(.largeTitle.bold())
        }
    }

    private struct IntegrationDiffView: View {
        let provider: HookProvider
        let preview: ManagedConfigPreview?

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(provider.rawValue.capitalized).font(.title.bold())
                if let preview {
                    ScrollView {
                        Text(preview.diff.isEmpty ? String(localized: "integrations.noChanges") : preview.diff)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ProgressView()
                }
            }
            .padding()
            .frame(width: 680, height: 480)
        }
    }

    private extension TerminalApplication {
        var title: String {
            switch self {
            case .terminal: "Terminal.app"
            case .iTerm2: "iTerm2"
            case .ghostty: "Ghostty"
            case .warp: "Warp"
            case .wezTerm: "WezTerm"
            case .visualStudioCode: "Visual Studio Code"
            case .cursor: "Cursor"
            case .unknown: "Unknown"
            }
        }
    }
#endif
