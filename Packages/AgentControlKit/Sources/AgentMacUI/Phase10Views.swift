#if os(macOS)
    // Onboarding and integration views share package-private presentation helpers in this file.
    // swiftlint:disable file_length
    import AgentDomain
    import AgentHookKit
    import AgentLocalIPC
    import AppKit
    import SwiftUI

    public struct IntegrationManagerView: View {
        @Bindable var store: AgentControlStore
        @Bindable var coordinator: Phase10Coordinator
        @State private var previewProvider: HookProvider?
        @State private var previewOperation = IntegrationPreviewOperation.inspect

        public init(store: AgentControlStore, coordinator: Phase10Coordinator) {
            self.store = store
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
                        Phase10MessageLabel(message: message, systemImage: "exclamationmark.triangle")
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
                    IntegrationDiffView(
                        provider: provider,
                        preview: coordinator.previews[provider],
                        applyTitle: previewOperation.applyTitle,
                        onApply: previewOperation == .inspect ? nil : {
                            Task {
                                switch previewOperation {
                                case .inspect:
                                    break
                                case .installOrRepair:
                                    await coordinator.repair(provider)
                                case .uninstall:
                                    await coordinator.uninstall(provider)
                                }
                                previewProvider = nil
                            }
                        }
                    )
                    .task { await coordinator.preview(provider, uninstall: previewOperation == .uninstall) }
                }
            }
        }

        private func integrationCard(_ record: AgentIntegrationRecord) -> some View {
            let activity = store.integrationActivity(provider: record.provider.rawValue)
            return VStack(alignment: .leading, spacing: AgentControlSpacing.compact) {
                HStack {
                    Label(record.provider.rawValue.capitalized, systemImage: "cpu")
                        .font(.headline)
                    Spacer()
                    Text("integration.state.\(record.state.rawValue)")
                        .font(.caption.bold())
                }
                LabeledContent(
                    "integrations.detected",
                    value: record.detectedVersion == nil
                        ? String(localized: "general.no")
                        : String(localized: "general.yes")
                )
                LabeledContent("integrations.version", value: record.detectedVersion?.description ?? "—")
                LabeledContent("integrations.config", value: record.configURL.path)
                LabeledContent(
                    "integrations.capabilities",
                    value: record.capabilities.supported.map(capabilityTitle).sorted().joined(separator: ", ")
                )
                activityRows(activity)
                if let warning = record.compatibilityWarning {
                    Label {
                        Text(LocalizedStringKey(warning))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                }
                unavailableCapabilities(record)
                integrationActions(record)
            }
            .agentCard()
        }

        private func integrationActions(_ record: AgentIntegrationRecord) -> some View {
            HStack {
                Button("integrations.viewChanges") { showPreview(record.provider, operation: .inspect) }
                Button("integrations.test") { Task { await coordinator.testIntegration(record.provider) } }
                if record.state == .notInstalled {
                    Button("integrations.install") {
                        showPreview(record.provider, operation: .installOrRepair)
                    }
                    .disabled(record.detectedVersion == nil)
                } else {
                    Button("integrations.repair") {
                        showPreview(record.provider, operation: .installOrRepair)
                    }
                    .disabled(record.detectedVersion == nil)
                }
                Button("integrations.restore") { Task { await coordinator.restoreBackup(record.provider) } }
                Button("integrations.uninstall", role: .destructive) {
                    showPreview(record.provider, operation: .uninstall)
                }
                .disabled(record.state == .notInstalled)
            }
        }

        @ViewBuilder
        private func activityRows(_ activity: ProviderIntegrationActivity) -> some View {
            LabeledContent("integrations.lastEvent") {
                diagnosticValue(activity.lastEventType, at: activity.lastEventAt)
            }
            LabeledContent("integrations.lastDecision") {
                diagnosticValue(
                    decisionActivityValue(
                        kind: activity.lastDecisionKind,
                        state: activity.lastDecisionState
                    ),
                    at: activity.lastDecisionAt
                )
            }
            LabeledContent("integrations.lastProviderAck") {
                diagnosticValue(
                    activity.lastProviderAcknowledgmentState.map(lifecycleTitle),
                    at: activity.lastProviderAcknowledgmentAt
                )
            }
            LabeledContent("integrations.lastError") {
                if let key = activity.lastRedactedErrorKey {
                    Text(LocalizedStringKey(key)).foregroundStyle(.orange)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
        }

        private func diagnosticValue(_ value: String?, at date: Date?) -> some View {
            HStack(spacing: 5) {
                Text(value ?? "—")
                if let date {
                    Text("·")
                    Text(date, style: .relative)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        private func capabilityTitle(_ capability: AgentCapability) -> String {
            switch capability {
            case .monitorSessions: String(localized: "capability.monitorSessions")
            case .approveRequests: String(localized: "capability.approveRequests")
            case .denyRequests: String(localized: "capability.denyRequests")
            case .answerQuestions: String(localized: "capability.answerQuestions")
            case .reviewPlans: String(localized: "capability.reviewPlans")
            case .stopSession: String(localized: "capability.stopSession")
            case .resumeSession: String(localized: "capability.resumeSession")
            case .navigateToSession: String(localized: "capability.navigateToSession")
            }
        }

        private func decisionActivityValue(
            kind: HookDecisionKind?,
            state: DecisionLifecycleState?
        ) -> String? {
            guard let state else { return nil }
            let kindTitle = switch kind {
            case .approval: String(localized: "decision.approval")
            case .question: String(localized: "decision.question")
            case .plan: String(localized: "decision.plan")
            case nil: String(localized: "integrations.decision")
            }
            return "\(kindTitle) · \(lifecycleTitle(state))"
        }

        private func lifecycleTitle(_ state: DecisionLifecycleState) -> String {
            switch state {
            case .awaitingUser: String(localized: "lifecycle.awaitingUser")
            case .userResolvedAwaitingProviderAck: String(localized: "lifecycle.userAwaitingProvider")
            case .automaticallyResolvedAwaitingProviderAck: String(localized: "lifecycle.automaticAwaitingProvider")
            case .providerAcknowledged: String(localized: "lifecycle.providerAcknowledged")
            case .applied: String(localized: "lifecycle.applied")
            case .deniedApplied: String(localized: "lifecycle.deniedApplied")
            case .expired: String(localized: "lifecycle.expired")
            case .cancelled: String(localized: "lifecycle.cancelled")
            case .superseded: String(localized: "lifecycle.superseded")
            case .providerRejected: String(localized: "lifecycle.providerRejected")
            }
        }

        private func showPreview(_ provider: HookProvider, operation: IntegrationPreviewOperation) {
            previewOperation = operation
            previewProvider = provider
        }

        @ViewBuilder
        private func unavailableCapabilities(_ record: AgentIntegrationRecord) -> some View {
            if !record.unsupportedCapabilityReasons.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("integrations.unavailableCapabilities")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(
                        record.unsupportedCapabilityReasons.keys.sorted { $0.rawValue < $1.rawValue },
                        id: \.rawValue
                    ) { capability in
                        Label {
                            Text(capabilityTitle(capability)) + Text(": ")
                                + Text(LocalizedStringKey(record.unsupportedCapabilityReasons[capability] ?? ""))
                        } icon: {
                            Image(systemName: "minus.circle")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private enum IntegrationPreviewOperation {
        case inspect
        case installOrRepair
        case uninstall

        var applyTitle: LocalizedStringKey? {
            switch self {
            case .inspect: nil
            case .installOrRepair: "integrations.applyManagedChanges"
            case .uninstall: "integrations.confirmUninstall"
            }
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
                    Image("YusufiwtBrandMark")
                        .resizable()
                        .frame(width: 34, height: 34)
                        .accessibilityHidden(true)
                    Text("onboarding.title")
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
                    }
                    .pickerStyle(.radioGroup)
                    Label("onboarding.mode.remoteDeferred", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
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
                        Phase10MessageLabel(message: message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
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

    private struct Phase10MessageLabel: View {
        let message: Phase10Message
        let systemImage: String

        var body: some View {
            Label {
                switch message {
                case let .localized(key):
                    Text(LocalizedStringKey(key))
                case let .verbatim(value):
                    Text(verbatim: value)
                }
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }

    private struct IntegrationDiffView: View {
        let provider: HookProvider
        let preview: ManagedConfigPreview?
        let applyTitle: LocalizedStringKey?
        let onApply: (() -> Void)?

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
                if let applyTitle, preview != nil {
                    HStack {
                        Spacer()
                        Button(applyTitle) { onApply?() }
                            .buttonStyle(.borderedProminent)
                    }
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
