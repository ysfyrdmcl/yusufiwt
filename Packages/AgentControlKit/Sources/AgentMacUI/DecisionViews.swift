#if os(macOS)
    import AgentDomain
    import AgentLocalIPC
    import AgentPersistence
    import SwiftUI

    // DecisionRow keeps every decision kind in one accessibility container.
    // swiftlint:disable:next type_body_length
    public struct DecisionRow: View {
        let store: AgentControlStore
        let decision: PendingHookDecision
        @State private var answer = ""
        @State private var selectedChoiceIDs: Set<String> = []

        public init(store: AgentControlStore, decision: PendingHookDecision) {
            self.store = store
            self.decision = decision
        }

        public var body: some View {
            let presentation = DecisionPresentation(decision: decision)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let availability = DecisionAvailability.evaluate(decision, now: context.date)
                VStack(alignment: .leading, spacing: AgentControlSpacing.standard) {
                    HStack {
                        Label(decision.kind.titleKey, systemImage: decision.kind.symbol)
                            .font(.headline)
                        Spacer()
                        if let risk = presentation.risk {
                            RiskBadge(risk: risk.level)
                        }
                    }
                    if let provider = presentation.provider, let project = presentation.project {
                        Text("\(provider.capitalized) · \(project)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let header = decision.question?.header, !header.isEmpty {
                        Text(header)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    Text(presentation.title).font(.body).textSelection(.enabled)
                    if !presentation.detailLines.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(presentation.detailLines, id: \.self) { line in
                                Text(line).font(.callout.monospaced()).textSelection(.enabled)
                            }
                        }
                        .padding(AgentControlSpacing.compact)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !presentation.riskReasons.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("decision.riskReasons").font(.caption.bold())
                            ForEach(presentation.riskReasons, id: \.self) { reason in
                                Label(RiskReasonCopy.title(reason), systemImage: "exclamationmark.circle")
                                    .font(.caption)
                            }
                        }
                    }
                    if !presentation.expectedEffects.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("decision.expectedEffects").font(.caption.bold())
                            ForEach(presentation.expectedEffects, id: \.self) { effect in
                                Label(effect, systemImage: "internaldrive")
                                    .font(.caption)
                            }
                        }
                    }
                    if let command = presentation.redactedCommand {
                        DisclosureGroup("decision.commandDetails") {
                            Text(command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                    }
                    expiryLabel(availability: availability)
                    decisionControls(availability: availability)
                    if let status = store.acknowledgmentStatuses[decision.requestID] {
                        AcknowledgmentLabel(status: status)
                    }
                }
                .padding(.vertical, AgentControlSpacing.compact)
                .contentShape(Rectangle())
                .onTapGesture { store.selectDecision(decision.requestID) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("decision.row.\(decision.requestID.uuidString.lowercased())")
            }
        }

        @ViewBuilder
        private func decisionControls(availability: DecisionAvailability) -> some View {
            switch availability {
            case .expired:
                Label("decision.expired", systemImage: "clock.badge.xmark")
                    .foregroundStyle(.secondary)
            case .secretRequiresTerminal:
                Label("decision.secretFallback", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                Button("action.openTerminal") { store.openTerminal(for: decision) }
            case .actionable:
                if decision.kind == .question {
                    questionControls
                } else if decision.kind == .plan {
                    planControls
                } else {
                    approvalControls
                }
            }
        }

        private var approvalControls: some View {
            HStack {
                Button("action.deny", role: .destructive) {
                    Task { _ = await store.resolve(decision, as: .deny) }
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("decision.deny")
                Button("action.openTerminal") { store.openTerminal(for: decision) }
                    .accessibilityIdentifier("decision.openTerminal")
                Spacer()
                Button("action.approve") {
                    Task { _ = await store.resolve(decision, as: .approve) }
                }
                .accessibilityIdentifier("decision.approveOnce")
            }
            .disabled(isResolving)
        }

        @ViewBuilder
        private var questionControls: some View {
            switch decision.question?.kind {
            case .singleChoice:
                VStack(alignment: .leading, spacing: AgentControlSpacing.compact) {
                    ForEach(decision.choices, id: \.self) { choice in
                        Button {
                            Task { _ = await store.resolve(decision, as: .answerChoice(id: choice.id)) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.label).fontWeight(.semibold)
                                if let description = choice.description, !description.isEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                    if decision.question?.isOther == true {
                        otherAnswerControls
                    }
                    HStack {
                        Spacer()
                        Button("action.openTerminal") { store.openTerminal(for: decision) }
                    }
                }
            case .multiChoice:
                VStack(alignment: .leading) {
                    ForEach(decision.choices) { choice in
                        Toggle(isOn: Binding(
                            get: { selectedChoiceIDs.contains(choice.id) },
                            set: { selected in
                                if selected {
                                    selectedChoiceIDs.insert(choice.id)
                                } else {
                                    selectedChoiceIDs.remove(choice.id)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.label)
                                if let description = choice.description, !description.isEmpty {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Button("action.sendAnswer") {
                        Task { _ = await store.resolve(decision, as: .answerChoices(ids: selectedChoiceIDs.sorted())) }
                    }
                    .disabled(selectedChoiceIDs.isEmpty)
                }
            case .confirmation:
                HStack {
                    Button("action.deny", role: .destructive) {
                        Task { _ = await store.resolve(decision, as: .confirm(false)) }
                    }
                    Button("action.confirm") {
                        Task { _ = await store.resolve(decision, as: .confirm(true)) }
                    }
                }
            case .freeText, .none:
                HStack {
                    TextField("decision.answerPlaceholder", text: $answer)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitAnswer() }
                    Button("action.sendAnswer") { submitAnswer() }
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                    Button("action.openTerminal") { store.openTerminal(for: decision) }
                }
            case .secret:
                EmptyView()
            }
        }

        private var otherAnswerControls: some View {
            HStack {
                TextField("decision.answerPlaceholder", text: $answer)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitAnswer() }
                Button("action.sendAnswer") { submitAnswer() }
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }

        private var planControls: some View {
            VStack(alignment: .trailing) {
                if decision.planChangesSupported == true {
                    TextField("decision.requestChangesPlaceholder", text: $answer)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("action.deny", role: .destructive) {
                        Task { _ = await store.resolve(decision, as: .deny) }
                    }
                    Spacer()
                    if decision.planChangesSupported == true {
                        Button("action.requestChanges") {
                            let value = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { _ = await store.resolve(decision, as: .requestPlanChanges(value)) }
                        }
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Button("action.acceptPlan") {
                        Task { _ = await store.resolve(decision, as: .approve) }
                    }
                }
            }
            .disabled(isResolving)
        }

        private var isResolving: Bool {
            switch store.acknowledgmentStatuses[decision.requestID] {
            case .sending, .sentToProvider, .automaticallySentToProvider, .providerAcknowledged:
                true
            default:
                false
            }
        }

        @ViewBuilder
        private func expiryLabel(availability: DecisionAvailability) -> some View {
            if let expiresAt = decision.expiresAt, availability != .expired {
                Label {
                    Text("decision.expires") + Text(" ") + Text(expiresAt, style: .relative)
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }

        private func submitAnswer() {
            let value = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            guard value.count <= (decision.maximumAnswerLength ?? 4000) else { return }
            Task { _ = await store.resolve(decision, as: .answerText(value)) }
        }
    }

    private struct RiskBadge: View {
        let risk: RiskLevel

        var body: some View {
            let token = RiskVisualToken.token(for: risk)
            Label(token.titleKey, systemImage: token.symbol)
                .font(.caption.bold())
                .foregroundStyle(token.color)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(token.color.opacity(0.12), in: Capsule())
        }
    }

    private enum RiskReasonCopy {
        private static let titleKeys: [String: String.LocalizationValue] = [
            "privilegeEscalation": "decision.risk.privilegeEscalation",
            "recursiveDelete": "decision.risk.recursiveDelete",
            "shellComposition": "decision.risk.shellComposition",
            "outsideWorkspace": "decision.risk.outsideWorkspace",
            "outsideWorkspaceWrite": "decision.risk.outsideWorkspace",
            "secretPath": "decision.risk.secretPath",
            "fileDeletion": "decision.risk.fileDeletion",
            "networkAccess": "decision.risk.networkAccess",
            "networkTool": "decision.risk.networkAccess",
            "pipeline": "decision.risk.pipeline",
            "redirection": "decision.risk.redirection",
            "subshell": "decision.risk.subshell",
            "workspace-write": "decision.risk.workspaceWrite"
        ]

        static func title(_ reason: String) -> String {
            let key = titleKeys[reason]
            guard let key else { return RedactedDiagnosticExporter.sanitize(reason) }
            return String(localized: key)
        }
    }

    private struct AcknowledgmentLabel: View {
        let status: LocalAcknowledgmentStatus

        var body: some View {
            Label(status.titleKey, systemImage: status.symbol)
                .font(.caption)
                .foregroundStyle(status == .sentToProvider || status == .automaticallySentToProvider
                    || status == .providerAcknowledged ? Color.secondary : Color.orange)
        }
    }

    private extension HookDecisionKind {
        var titleKey: LocalizedStringKey {
            switch self {
            case .approval: "decision.approval"
            case .question: "decision.question"
            case .plan: "decision.plan"
            }
        }

        var symbol: String {
            switch self {
            case .approval: "checkmark.shield"
            case .question: "questionmark.bubble"
            case .plan: "list.bullet.clipboard"
            }
        }
    }

    private extension LocalAcknowledgmentStatus {
        var titleKey: LocalizedStringKey {
            switch self {
            case .sending: "decision.status.sending"
            case .sentToProvider: "decision.status.sent"
            case .automaticallySentToProvider: "decision.status.sent"
            case .providerAcknowledged: "decision.status.sent"
            case .applied: "decision.status.applied"
            case .deniedApplied: "decision.status.deniedApplied"
            case .expired: "decision.status.expired"
            case .cancelled: "decision.status.cancelled"
            case .superseded: "decision.status.superseded"
            case .rejected: "decision.status.rejected"
            case .failed: "decision.status.failed"
            }
        }

        var symbol: String {
            switch self {
            case .sending: "arrow.up.circle"
            case .sentToProvider: "paperplane"
            case .automaticallySentToProvider: "bolt.badge.checkmark"
            case .providerAcknowledged: "checkmark.circle"
            case .applied: "checkmark.seal"
            case .deniedApplied: "hand.raised.fill"
            case .expired: "clock.badge.xmark"
            case .cancelled: "xmark.circle"
            case .superseded: "arrow.triangle.2.circlepath"
            case .rejected: "hand.raised"
            case .failed: "exclamationmark.triangle"
            }
        }
    }
#endif
