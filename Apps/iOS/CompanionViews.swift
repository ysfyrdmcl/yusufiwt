import AgentCompanion
import AgentDomain
import AuthenticationServices
import SwiftUI
import VisionKit

// SwiftUI screen declarations are intentionally colocated to share a small private view vocabulary.
// swiftlint:disable file_length

struct CompanionRootView: View {
    @ObservedObject var model: CompanionAppModel
    @State private var tab = CompanionTab.status

    var body: some View {
        Group {
            if !model.signedIn {
                SignInView(model: model)
            } else if !model.paired {
                PairingView(model: model)
            } else {
                TabView(selection: $tab) {
                    MacStatusView(model: model)
                        .tabItem { Label(String(localized: "tab.status"), systemImage: "macbook") }
                        .tag(CompanionTab.status)
                    ActiveSessionsView(model: model)
                        .tabItem { Label(String(localized: "tab.active"), systemImage: "waveform.path.ecg") }
                        .tag(CompanionTab.active)
                    InboxView(model: model)
                        .tabItem { Label(String(localized: "tab.inbox"), systemImage: "tray.full") }
                        .badge(model.inbox.filter { $0.availability(at: Date()) == .available }.count)
                        .tag(CompanionTab.inbox)
                    HistoryView(model: model)
                        .tabItem { Label(String(localized: "tab.history"), systemImage: "clock.arrow.circlepath") }
                        .tag(CompanionTab.history)
                    CompanionSettingsView(model: model)
                        .tabItem { Label(String(localized: "tab.settings"), systemImage: "gearshape") }
                        .tag(CompanionTab.settings)
                }
            }
        }
        .alert(String(localized: "common.notice"), isPresented: Binding(
            get: { model.message != nil },
            set: {
                if !$0 {
                    model.message = nil
                }
            }
        )) {
            Button(String(localized: "common.ok")) { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
        .sheet(isPresented: Binding(
            get: { model.selectedInboxID != nil && model.paired },
            set: {
                if !$0 {
                    model.selectedInboxID = nil
                }
            }
        )) {
            if let item = model.inbox.first(where: { $0.id == model.selectedInboxID }) {
                NavigationStack { InboxDetailView(model: model, item: item) }
            }
        }
        .sheet(isPresented: Binding(
            get: { model.selectedSessionID != nil && model.paired },
            set: {
                if !$0 {
                    model.selectedSessionID = nil
                }
            }
        )) {
            if let session = model.sessions.first(where: { $0.id == model.selectedSessionID }) {
                NavigationStack { SessionDetailView(model: model, session: session) }
            }
        }
        .onChange(of: model.selectedInboxID) { _, value in
            if value != nil {
                tab = .inbox
            }
        }
    }
}

private enum CompanionTab: Hashable { case status, active, inbox, history, settings }

private struct SignInView: View {
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            YusufiwtBrandMark(size: 88)
            VStack(spacing: 8) {
                Text(String(localized: "app.name"))
                    .font(.largeTitle.bold())
                Text(String(localized: "signin.subtitle"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            SignInWithAppleButton(.signIn) { request in
                model.prepareAppleRequest(request)
            } onCompletion: { result in
                Task { await model.completeAppleSignIn(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 52)
            .clipShape(.rect(cornerRadius: 12))
            Text(String(localized: "signin.privacy"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(28)
    }
}

private struct PairingView: View {
    @ObservedObject var model: CompanionAppModel
    @State private var code = ""
    @State private var scannerPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ContentUnavailableView(
                        String(localized: "pair.title"),
                        systemImage: "qrcode.viewfinder",
                        description: Text(String(localized: "pair.subtitle"))
                    )
                    Button {
                        scannerPresented = true
                    } label: {
                        Label(String(localized: "pair.scan"), systemImage: "camera.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Section(String(localized: "pair.manual")) {
                    TextField(String(localized: "pair.codePlaceholder"), text: $code, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(String(localized: "pair.continue")) {
                        Task { await model.scanPairingCode(code) }
                    }
                    .disabled(code.isEmpty)
                }
            }
            .navigationTitle(String(localized: "pair.navigationTitle"))
        }
        .sheet(isPresented: $scannerPresented) {
            PairingCodeScanner { value in
                scannerPresented = false
                Task { await model.scanPairingCode(value) }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $model.pendingPairing) { pairing in
            NavigationStack {
                VStack(spacing: 24) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                    Text(String(localized: "pair.fingerprintTitle"))
                        .font(.title2.bold())
                    Text(pairing.fingerprint)
                        .font(.system(.title, design: .monospaced, weight: .bold))
                        .textSelection(.enabled)
                    Text(String(localized: "pair.fingerprintHelp"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "pair.matches")) {
                        Task { await model.confirmPairing() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button(String(localized: "pair.cancel"), role: .cancel) { model.cancelPairing() }
                }
                .padding(28)
                .navigationTitle(String(localized: "pair.confirm"))
            }
            .presentationDetents([.medium])
            .interactiveDismissDisabled()
        }
    }
}

private struct MacStatusView: View {
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: model.lastSyncAt == nil ? "macbook.slash" : "macbook")
                            .font(.title)
                            .foregroundStyle(model.lastSyncAt == nil ? Color.secondary : Color.green)
                        VStack(alignment: .leading) {
                            Text(model.macDisplayName).font(.headline)
                            Text(syncDescription).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
                Section(String(localized: "status.overview")) {
                    LabeledContent(String(localized: "status.active"), value: "\(activeCount)")
                    LabeledContent(String(localized: "status.attention"), value: "\(model.inbox.count)")
                    LabeledContent(String(localized: "status.pendingDecisions"), value: "\(pendingDecisionCount)")
                }
            }
            .navigationTitle(String(localized: "status.title"))
            .refreshable { await model.refresh() }
            .overlay {
                if model.isSyncing {
                    ProgressView()
                }
            }
        }
    }

    private var activeCount: Int {
        model.sessions.filter { !$0.state.isTerminal }.count
    }

    private var pendingDecisionCount: Int {
        model.outbox.filter { !$0.state.isFinal }.count
    }

    private var syncDescription: String {
        guard let lastSyncAt = model.lastSyncAt else { return String(localized: "status.notSynced") }
        return String(
            format: String(localized: "status.lastSyncFormat"),
            lastSyncAt.formatted(.relative(presentation: .named))
        )
    }
}

private struct ActiveSessionsView: View {
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.sessions.isEmpty {
                    ContentUnavailableView(
                        String(localized: "active.empty"), systemImage: "waveform.path.ecg",
                        description: Text(String(localized: "active.emptyDetail"))
                    )
                } else {
                    List(model.sessions) { session in
                        NavigationLink {
                            SessionDetailView(model: model, session: session)
                        } label: {
                            SessionRow(session: session)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "active.title"))
            .refreshable { await model.refresh() }
        }
    }
}

private struct SessionRow: View {
    let session: CompanionSessionSummary

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(stateColor).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.projectName).font(.headline)
                Text("\(session.agentName) · \(session.state.rawValue)")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !session.summary.isEmpty {
                    Text(session.summary).font(.caption).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var stateColor: Color {
        switch session.state {
        case .failed, .stale, .disconnected: .red
        case .waitingApproval, .waitingInput: .orange
        case .completed: .green
        default: .blue
        }
    }
}

private struct SessionDetailView: View {
    @ObservedObject var model: CompanionAppModel
    let session: CompanionSessionSummary

    var body: some View {
        List {
            Section(String(localized: "session.summary")) {
                LabeledContent(String(localized: "session.agent"), value: session.agentName)
                LabeledContent(String(localized: "session.project"), value: session.projectName)
                LabeledContent(String(localized: "session.state"), value: session.state.rawValue)
                Text(session.summary)
            }
            Section(String(localized: "session.timeline")) {
                LabeledContent(String(localized: "session.started"), value: session.startedAt.formatted())
                LabeledContent(String(localized: "session.updated"), value: session.updatedAt.formatted())
            }
            if !session.state.isTerminal {
                Section {
                    Button {
                        Task { await model.toggleLiveActivity(for: session) }
                    } label: {
                        Label(
                            model.pinnedSessionID == session.id
                                ? String(localized: "liveActivity.unpin")
                                : String(localized: "liveActivity.pin"),
                            systemImage: model.pinnedSessionID == session.id ? "pin.slash" : "pin"
                        )
                    }
                } footer: {
                    Text(String(localized: "liveActivity.help"))
                }
            }
        }
        .navigationTitle(session.projectName)
    }
}

private struct InboxView: View {
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.inbox.isEmpty {
                    ContentUnavailableView(
                        String(localized: "inbox.empty"), systemImage: "tray",
                        description: Text(String(localized: "inbox.emptyDetail"))
                    )
                } else {
                    List(model.inbox) { item in
                        Button { model.selectedInboxID = item.id } label: {
                            InboxRow(item: item, decision: decision(for: item))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(String(localized: "inbox.title"))
            .refreshable { await model.refresh() }
        }
    }

    private func decision(for item: CompanionInboxItem) -> CompanionPendingDecision? {
        model.outbox.first(where: { $0.requestID == item.id })
    }
}

private struct InboxRow: View {
    let item: CompanionInboxItem
    let decision: CompanionPendingDecision?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == .question ? "questionmark.bubble" : "checkmark.shield")
                .foregroundStyle(riskColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(item.risk.rawValue.capitalized)
                        .font(.caption.bold()).foregroundStyle(riskColor)
                }
                Text("\(item.agentName) · \(item.projectName)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(decision?.state.rawValue ?? item.detail)
                    .font(.caption).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .opacity(item.expiresAt <= Date() ? 0.55 : 1)
    }

    private var riskColor: Color {
        switch item.risk {
        case .low: .green
        case .medium: .orange
        case .high, .critical: .red
        }
    }
}

struct InboxDetailView: View {
    @ObservedObject var model: CompanionAppModel
    let item: CompanionInboxItem
    @State private var answer = ""

    var body: some View {
        List {
            Section {
                LabeledContent(String(localized: "detail.agent"), value: item.agentName)
                LabeledContent(String(localized: "detail.project"), value: item.projectName)
                LabeledContent(String(localized: "detail.risk"), value: item.risk.rawValue.capitalized)
                Text(item.detail).textSelection(.enabled)
            } header: {
                Text(item.title)
            }
            if let decision = currentDecision {
                Section(String(localized: "detail.decisionStatus")) {
                    Label(decision.state.rawValue, systemImage: decision.state.isSuccess ? "checkmark.circle.fill" : "clock")
                        .foregroundStyle(decision.state.isSuccess ? .green : .secondary)
                    if decision.state == .awaitingProviderAcknowledgment {
                        Text(String(localized: "detail.awaitingAck"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if availability == .available {
                decisionControls
            } else {
                Section {
                    Label(availabilityText, systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(String(localized: "detail.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "common.close")) { model.selectedInboxID = nil }
            }
        }
    }

    private var decisionControls: some View {
        Section(String(localized: "detail.action")) {
            if item.kind == .question {
                questionControls
            } else if item.risk == .critical {
                Label(String(localized: "detail.openMacRequired"), systemImage: "macbook.and.iphone")
                    .foregroundStyle(.red)
            } else if item.risk == .high {
                HoldToApproveButton {
                    await model.approveHighRisk(item)
                }
            } else {
                Button {
                    Task {
                        await model.decide(
                            item: item, outcome: .approve,
                            evidence: .init(surface: .applicationDetail)
                        )
                    }
                } label: {
                    Label(String(localized: "detail.approve"), systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
            }
            Button(role: .destructive) {
                Task {
                    await model.decide(
                        item: item, outcome: .deny,
                        evidence: .init(surface: .applicationDetail)
                    )
                }
            } label: {
                Label(String(localized: "detail.deny"), systemImage: "xmark.circle")
            }
        }
    }

    @ViewBuilder private var questionControls: some View {
        if item.question?.kind == .secret {
            Label(String(localized: "detail.secretMacOnly"), systemImage: "lock.fill")
        } else if let choices = item.question?.choices, !choices.isEmpty {
            ForEach(choices) { choice in
                Button(choice.label) {
                    Task {
                        await model.decide(
                            item: item, outcome: .answer, answer: choice.id,
                            evidence: .init(surface: .applicationDetail)
                        )
                    }
                }
            }
        } else {
            TextField(String(localized: "detail.answerPlaceholder"), text: $answer, axis: .vertical)
            Button(String(localized: "detail.sendAnswer")) {
                Task {
                    await model.decide(
                        item: item, outcome: .answer, answer: answer,
                        evidence: .init(surface: .applicationDetail)
                    )
                }
            }
            .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var currentDecision: CompanionPendingDecision? {
        model.outbox.first(where: { $0.requestID == item.id })
    }

    private var availability: CompanionRequestAvailability {
        item.availability(at: Date())
    }

    private var availabilityText: String {
        switch availability {
        case .available: String(localized: "detail.available")
        case .expired: String(localized: "detail.expired")
        case .superseded: String(localized: "detail.superseded")
        case .macRequired: String(localized: "detail.openMacRequired")
        }
    }
}

private struct HoldToApproveButton: View {
    let action: @Sendable () async -> Void
    @State private var pressing = false

    var body: some View {
        Label(
            pressing ? String(localized: "detail.keepHolding") : String(localized: "detail.holdToApprove"),
            systemImage: "faceid"
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .foregroundStyle(.white)
        .background(pressing ? Color.orange : Color.red, in: .rect(cornerRadius: 12))
        .contentShape(.rect)
        .onLongPressGesture(minimumDuration: 1.5, maximumDistance: 30) {
            pressing = false
            Task { await action() }
        } onPressingChanged: { value in
            withAnimation(.easeInOut(duration: 0.2)) { pressing = value }
        }
        .accessibilityLabel(String(localized: "detail.holdToApprove"))
        .accessibilityHint(String(localized: "detail.holdHint"))
    }
}

private struct HistoryView: View {
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    ContentUnavailableView(
                        String(localized: "history.empty"), systemImage: "clock",
                        description: Text(String(localized: "history.emptyDetail"))
                    )
                } else {
                    List(model.history) { decision in
                        HStack {
                            Image(systemName: decision.state.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(decision.state.isSuccess ? .green : .orange)
                            VStack(alignment: .leading) {
                                Text(decision.state.rawValue)
                                Text(decision.updatedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "history.title"))
        }
    }
}

private struct CompanionSettingsView: View {
    @ObservedObject var model: CompanionAppModel
    @State private var revokeCandidate: CompanionDeviceRecord?
    @State private var confirmsAccountDeletion = false

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "settings.notifications")) {
                    Picker(String(localized: "settings.preview"), selection: Binding(
                        get: { model.privacy }, set: { model.setPrivacy($0) }
                    )) {
                        Text(String(localized: "privacy.hidden")).tag(CompanionNotificationPrivacy.hidden)
                        Text(String(localized: "privacy.projectOnly")).tag(CompanionNotificationPrivacy.projectOnly)
                        Text(String(localized: "privacy.full")).tag(CompanionNotificationPrivacy.full)
                    }
                }
                Section(String(localized: "settings.devices")) {
                    ForEach(model.devices) { device in
                        CompanionDeviceSettingsRow(device: device) {
                            revokeCandidate = device
                        }
                    }
                }
                Section {
                    Text(String(localized: "settings.e2e"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button(String(localized: "settings.deleteAccount"), role: .destructive) {
                        confirmsAccountDeletion = true
                    }
                } header: {
                    Text(String(localized: "settings.account"))
                } footer: {
                    Text(String(localized: "settings.deleteAccountHelp"))
                }
            }
            .navigationTitle(String(localized: "settings.title"))
            .confirmationDialog(
                String(localized: "settings.revokeConfirm"),
                isPresented: Binding(get: { revokeCandidate != nil }, set: {
                    if !$0 {
                        revokeCandidate = nil
                    }
                }),
                presenting: revokeCandidate
            ) { device in
                Button(String(localized: "settings.revoke"), role: .destructive) {
                    Task { await model.revoke(device) }
                }
            }
            .confirmationDialog(
                String(localized: "settings.deleteAccountConfirm"),
                isPresented: $confirmsAccountDeletion,
                titleVisibility: .visible
            ) {
                Button(String(localized: "settings.deleteAccount"), role: .destructive) {
                    Task { await model.deleteAccount() }
                }
                Button(String(localized: "common.cancel"), role: .cancel) {}
            }
        }
    }
}

private struct CompanionDeviceSettingsRow: View {
    let device: CompanionDeviceRecord
    let revoke: () -> Void

    var body: some View {
        HStack {
            Image(systemName: device.role == .localMac ? "macbook" : "iphone")
            VStack(alignment: .leading) {
                Text(device.displayName)
                Text(device.role.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "settings.revoke"), role: .destructive, action: revoke)
                .font(.caption)
        }
    }
}

private struct PairingCodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            return UIHostingController(rootView: ContentUnavailableView(
                String(localized: "pair.scannerUnavailable"), systemImage: "camera.fill",
                description: Text(String(localized: "pair.useManual"))
            ))
        }
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var delivered = false
        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !delivered else { return }
            for item in addedItems {
                if case let .barcode(barcode) = item, let value = barcode.payloadStringValue {
                    delivered = true
                    onCode(value)
                    return
                }
            }
        }
    }
}
