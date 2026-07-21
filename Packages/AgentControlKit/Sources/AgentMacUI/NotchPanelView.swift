#if os(macOS)
    import AgentDomain
    import AgentPersistence
    import SwiftUI

    public struct FloatingPanelView: View {
        @Bindable var store: AgentControlStore
        let coordinator: FloatingPanelCoordinator
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        public init(store: AgentControlStore, coordinator: FloatingPanelCoordinator) {
            self.store = store
            self.coordinator = coordinator
        }

        private var liveSessions: [SessionListItem] {
            store.liveSessions()
        }

        public var body: some View {
            VStack(spacing: 0) {
                notchHeader

                if coordinator.mode.showsDetails {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                    detailContent
                }
            }
            .foregroundStyle(.white)
            .background(Color.black.opacity(0.97), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.1))
            }
            .environment(\.colorScheme, .dark)
            .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: coordinator.mode)
        }

        private var notchHeader: some View {
            Button(action: coordinator.toggle) {
                HStack(spacing: 10) {
                    compactLeadingStatus
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: max(12, coordinator.notchWidth))

                    compactTrailingStatus
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    Image(systemName: coordinator.mode == .expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.42))
                }
                .padding(.horizontal, 14)
                .frame(height: max(40, coordinator.notchHeight))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(headerAccessibilityLabel)
            .accessibilityIdentifier("notch.toggle")
        }

        @ViewBuilder
        private var compactLeadingStatus: some View {
            if !store.pendingDecisions.isEmpty {
                Label("\(store.pendingDecisions.count)", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            } else if !liveSessions.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green.opacity(0.72))
                        .frame(width: 6, height: 6)
                    Text(liveSessions.count, format: .number)
                        .monospacedDigit()
                }
                .foregroundStyle(Color.white.opacity(0.72))
            } else {
                HStack(spacing: 6) {
                    Image("YusufiwtBrandGlyph")
                        .resizable()
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                    Text("yusufiwt")
                }
                .foregroundStyle(Color.white.opacity(0.62))
            }
        }

        @ViewBuilder
        private var compactTrailingStatus: some View {
            if !store.pendingDecisions.isEmpty {
                Text("notch.actionRequired")
                    .foregroundStyle(.orange)
            } else if !liveSessions.isEmpty {
                HStack(spacing: 7) {
                    QuietAgentGlyph(isAnimating: true)
                    Text("notch.working")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.62))
                }
            } else {
                HStack(spacing: 6) {
                    Circle().fill(Color.white.opacity(0.32)).frame(width: 6, height: 6)
                    Text("notch.ready")
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
        }

        private var headerAccessibilityLabel: Text {
            if !store.pendingDecisions.isEmpty {
                return Text("notch.actionsNeeded") + Text(" \(store.pendingDecisions.count)")
            }
            if !liveSessions.isEmpty {
                return Text("notch.agentsWorking") + Text(" \(liveSessions.count)")
            }
            return Text("notch.ready.accessibility")
        }

        @ViewBuilder
        private var detailContent: some View {
            switch coordinator.mode {
            case .compact:
                EmptyView()
            case .activity:
                activityContent
            case .decision:
                ScrollView {
                    VStack(spacing: AgentControlSpacing.standard) {
                        notificationRouteBanner
                        providerAcknowledgmentBanner
                        if let decision = store.pendingDecisions.first {
                            DecisionRow(store: store, decision: decision)
                        }
                    }
                    .padding(AgentControlSpacing.standard)
                }
            case .expanded:
                expandedContent
            }
        }

        private var expandedContent: some View {
            VStack(spacing: 0) {
                NotchSummaryStrip(store: store, liveSessions: liveSessions)

                ScrollView {
                    LazyVStack(spacing: 10) {
                        notificationRouteBanner
                        providerAcknowledgmentBanner

                        ForEach(store.pendingDecisions.prefix(5), id: \.requestID) { decision in
                            DecisionRow(store: store, decision: decision)
                                .padding(12)
                                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.orange.opacity(0.25))
                                }
                        }

                        ForEach(liveSessions.prefix(8), id: \.id) { session in
                            sessionCard(session)
                        }

                        if liveSessions.isEmpty, store.pendingDecisions.isEmpty {
                            ContentUnavailableView(
                                "notch.empty.title",
                                systemImage: "moon.stars",
                                description: Text("notch.empty.message")
                            )
                            .frame(maxWidth: .infinity, minHeight: 220)
                        }
                    }
                    .padding(14)
                }
                panelActions
            }
        }

        @ViewBuilder
        private var notificationRouteBanner: some View {
            switch store.notificationRouteState {
            case .inactive:
                Label("notification.route.inactive", systemImage: "clock.badge.xmark")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("notification.route.inactive")
            case .helperUnavailable:
                Label("notification.route.helperUnavailable", systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("notification.route.helperUnavailable")
            case .selected, .none:
                EmptyView()
            }
        }

        @ViewBuilder
        private var providerAcknowledgmentBanner: some View {
            if let lifecycle = store.decisionAwaitingProviderAcknowledgment {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("decision.status.sent")
                        if let provider = lifecycle.provider, let project = lifecycle.projectName {
                            Text("\(provider.capitalized) · \(project)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("decision.awaitingProviderAck")
            }
        }

        private var panelActions: some View {
            HStack(spacing: 16) {
                Button(action: coordinator.openControlCenter) {
                    Label("menu.openControlCenter", systemImage: "macwindow")
                }
                .accessibilityIdentifier("notch.openControlCenter")

                SettingsLink {
                    Label("menu.settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("notch.openSettings")

                Spacer()

                Button(action: coordinator.toggleNotificationSound) {
                    Label(
                        coordinator.isNotificationSoundEnabled ? "settings.sound.on" : "settings.sound.off",
                        systemImage: coordinator.isNotificationSoundEnabled ? "speaker.wave.2" : "speaker.slash"
                    )
                }
                .accessibilityIdentifier("notch.toggleSound")
            }
            .font(.caption)
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.035))
        }

        private func sessionCard(_ session: SessionListItem) -> some View {
            NotchSessionCard(session: session) {
                store.selectSession(session.id)
            }
        }

        @ViewBuilder
        private var activityContent: some View {
            if let alert = coordinator.highlightedAlert {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NotchPanelFormatting.alertTitle(alert.kind)).font(.callout.bold())
                        Text("\(Int(alert.observedDurationSeconds / 60)) min")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(AgentControlSpacing.standard)
            } else if let session = coordinator.highlightedSession {
                sessionCard(session)
                    .padding(AgentControlSpacing.standard)
            } else {
                Text("notch.activityUpdated")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(AgentControlSpacing.standard)
            }
        }
    }

#endif
