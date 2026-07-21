#if os(macOS)
    import AgentPersistence
    import SwiftUI

    struct NotchSummaryStrip: View {
        @Bindable var store: AgentControlStore
        let liveSessions: [SessionListItem]

        var body: some View {
            HStack(spacing: 10) {
                metric("notch.live", value: "\(liveSessions.count)", color: .green)
                if let oldest = liveSessions.min(by: { $0.startedAt < $1.startedAt }) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        metric(
                            "notch.running",
                            value: NotchPanelFormatting.elapsed(from: oldest.startedAt, to: context.date),
                            color: .blue
                        )
                    }
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    usageSummary(store.usagePresentation(at: context.date))
                }
                Spacer(minLength: 0)
                connectionBadge
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.025))
        }

        private func metric(_ title: LocalizedStringKey, value: String, color: Color) -> some View {
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

        private func usageSummary(_ presentation: SessionUsagePresentation) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    metric(
                        LocalizedStringKey(presentation.titleKey),
                        value: presentation.value,
                        color: presentation.isAvailable ? .blue : Color.white.opacity(0.38)
                    )
                    if presentation.isStale {
                        Text("usage.stale")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                if let source = presentation.sourceLabel {
                    Text(source)
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.34))
                        .lineLimit(1)
                }
            }
            .help(Text(LocalizedStringKey(presentation.helpKey)))
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

        private var connectionTitle: LocalizedStringKey {
            switch store.connectionState {
            case .online: "notch.connection.live"
            case .loading: "notch.connection.connecting"
            case .offline, .error: "notch.connection.offline"
            }
        }
    }
#endif
