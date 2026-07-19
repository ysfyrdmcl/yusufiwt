#if os(macOS)
    import AgentDomain
    import AgentPersistence
    import SwiftUI

    public enum NotchPanelFormatting {
        public static func elapsed(from start: Date, to end: Date) -> String {
            let seconds = max(0, Int(end.timeIntervalSince(start)))
            if seconds < 60 { return "<1m" }
            let minutes = seconds / 60
            if minutes < 60 { return "\(minutes)m" }
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            if hours < 24 { return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m" }
            let days = hours / 24
            let remainingHours = hours % 24
            return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
        }

        public static func stateTitle(_ state: SessionState) -> String {
            switch state {
            case .discovered, .starting: "Starting"
            case .thinking: "Thinking"
            case .executing, .running: "Working"
            case .waitingApproval: "Approval needed"
            case .waitingInput: "Input needed"
            case .paused: "Paused"
            case .completed: "Completed"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            case .disconnected: "Disconnected"
            case .stale: "Stale"
            }
        }
    }

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
            .onTapGesture { coordinator.toggle() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(headerAccessibilityLabel)
            .accessibilityAddTraits(.isButton)
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
                    Text("Working…")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.62))
                }
            } else {
                HStack(spacing: 6) {
                    Circle().fill(Color.white.opacity(0.32)).frame(width: 6, height: 6)
                    Text("Ready")
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
        }

        private var headerAccessibilityLabel: String {
            if !store.pendingDecisions.isEmpty { return "\(store.pendingDecisions.count) actions needed" }
            if !liveSessions.isEmpty { return "\(liveSessions.count) agents working" }
            return String(localized: "notch.ready.accessibility")
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
                    if let decision = store.pendingDecisions.first {
                        DecisionRow(store: store, decision: decision)
                            .padding(AgentControlSpacing.standard)
                    }
                }
            case .expanded:
                expandedContent
            }
        }

        private var expandedContent: some View {
            VStack(spacing: 0) {
                summaryStrip

                ScrollView {
                    LazyVStack(spacing: 10) {
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
                                "No active agents",
                                systemImage: "moon.stars",
                                description: Text("Start a Codex task to see live activity here.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 220)
                        }
                    }
                    .padding(14)
                }
            }
        }

        private var summaryStrip: some View {
            HStack(spacing: 10) {
                metric("Live", value: "\(liveSessions.count)", color: .green)
                if let oldest = liveSessions.min(by: { $0.startedAt < $1.startedAt }) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        metric(
                            "Running",
                            value: NotchPanelFormatting.elapsed(from: oldest.startedAt, to: context.date),
                            color: .blue
                        )
                    }
                }
                metric("Tokens", value: "—", color: Color.white.opacity(0.38))
                    .help("The current Codex hook does not provide token usage telemetry.")
                Spacer(minLength: 0)
                connectionBadge
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.025))
        }

        private func metric(_ title: String, value: String, color: Color) -> some View {
            HStack(spacing: 5) {
                Text(title)
                    .foregroundStyle(Color.white.opacity(0.48))
                Text(value)
                    .foregroundStyle(color)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.caption)
        }

        private var connectionBadge: some View {
            HStack(spacing: 5) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 6, height: 6)
                Text(connectionTitle)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.white.opacity(0.58))
        }

        private var connectionColor: Color {
            switch store.connectionState {
            case .online: .green
            case .loading: .blue
            case .offline, .error: .orange
            }
        }

        private var connectionTitle: String {
            switch store.connectionState {
            case .online: "Live"
            case .loading: "Connecting"
            case .offline, .error: "Offline"
            }
        }

        private func sessionCard(_ session: SessionListItem) -> some View {
            HStack(alignment: .top, spacing: 12) {
                QuietAgentGlyph(isAnimating: !session.state.isTerminal)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(session.projectName)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        providerBadge(session.adapterID.rawValue)
                        stateBadge(session.state)
                    }

                    HStack(spacing: 6) {
                        Text("You:")
                            .foregroundStyle(Color.white.opacity(0.34))
                        Text("Agent task in progress")
                            .foregroundStyle(Color.white.opacity(0.57))
                            .lineLimit(1)
                    }
                    .font(.caption)

                    HStack(spacing: 14) {
                        Label {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(NotchPanelFormatting.elapsed(from: session.startedAt, to: context.date))
                                    .monospacedDigit()
                            }
                        } icon: {
                            Image(systemName: "clock")
                        }
                        Label {
                            Text(session.lastMeaningfulEventAt, style: .relative)
                        } icon: {
                            Image(systemName: "waveform.path.ecg")
                        }
                        Label("Tokens unavailable", systemImage: "gauge.with.dots.needle.0percent")
                            .help("Token usage is not included in current provider hook events.")
                    }
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.4))
                }
            }
            .padding(13)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.white.opacity(0.075))
            }
            .contentShape(Rectangle())
            .onTapGesture { store.selectSession(session.id) }
            .accessibilityElement(children: .combine)
        }

        private func providerBadge(_ provider: String) -> some View {
            Text(provider.capitalized)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.13), in: Capsule())
        }

        private func stateBadge(_ state: SessionState) -> some View {
            Text(NotchPanelFormatting.stateTitle(state))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(stateColor(state))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(stateColor(state).opacity(0.12), in: Capsule())
        }

        private func stateColor(_ state: SessionState) -> Color {
            switch state {
            case .waitingApproval, .waitingInput: .orange
            case .failed: .red
            case .completed: .green
            case .paused, .cancelled, .disconnected, .stale: Color.white.opacity(0.5)
            default: .blue
            }
        }

        @ViewBuilder
        private var activityContent: some View {
            if let alert = coordinator.highlightedAlert {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.kind.rawValue).font(.callout.bold())
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
                Text("Agent activity updated")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(AgentControlSpacing.standard)
            }
        }
    }

    /// A deliberately quiet always-on indicator: it only blinks briefly every four seconds.
    private struct QuietAgentGlyph: View {
        let isAnimating: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            TimelineView(.animation(minimumInterval: 0.25, paused: !isAnimating || reduceMotion)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 4)
                let isBlinking = isAnimating && !reduceMotion && phase < 0.25

                Image("YusufiwtBrandGlyph")
                    .resizable()
                    .frame(width: 16, height: 16)
                    .opacity(isBlinking ? 0.58 : 0.92)
            }
            .frame(width: 18, height: 18)
            .opacity(isAnimating ? 1 : 0.55)
            .accessibilityHidden(true)
        }
    }
#endif
