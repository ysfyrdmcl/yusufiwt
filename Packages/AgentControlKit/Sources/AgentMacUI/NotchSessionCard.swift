#if os(macOS)
    import AgentDomain
    import AgentPersistence
    import SwiftUI

    struct NotchSessionCard: View {
        let session: SessionListItem
        let select: () -> Void

        var body: some View {
            Button(action: select) {
                HStack(alignment: .top, spacing: 12) {
                    QuietAgentGlyph(isAnimating: !session.state.isTerminal)
                        .padding(.top, 3)
                    sessionSummary
                }
                .padding(13)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.white.opacity(0.075))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("notch.session.\(session.id.description)")
        }

        private var sessionSummary: some View {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(session.projectName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    providerBadge
                    stateBadge
                }

                HStack(spacing: 6) {
                    Text("notch.you")
                        .foregroundStyle(Color.white.opacity(0.34))
                    Text("notch.taskInProgress")
                        .foregroundStyle(Color.white.opacity(0.57))
                        .lineLimit(1)
                }
                .font(.caption)

                HStack(spacing: 14) {
                    elapsedLabel
                    Label {
                        Text(session.lastMeaningfulEventAt, style: .relative)
                    } icon: {
                        Image(systemName: "waveform.path.ecg")
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        usageLabel(at: context.date)
                    }
                }
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.4))
            }
        }

        private var elapsedLabel: some View {
            Label {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(NotchPanelFormatting.elapsed(from: session.startedAt, to: context.date))
                        .monospacedDigit()
                }
            } icon: {
                Image(systemName: "clock")
            }
        }

        private func usageLabel(at date: Date) -> some View {
            let presentation = SessionUsagePresentation(session: session, at: date)
            return Label {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(presentation.titleKey))
                    Text(presentation.value).monospacedDigit()
                    if presentation.isStale {
                        Text("usage.stale").foregroundStyle(.orange)
                    }
                }
            } icon: {
                Image(systemName: presentation.isAvailable
                    ? "gauge.with.dots.needle.50percent"
                    : "gauge.with.dots.needle.0percent")
            }
            .help(Text(LocalizedStringKey(presentation.helpKey)))
        }

        private var providerBadge: some View {
            Text(session.adapterID.rawValue.capitalized)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.13), in: Capsule())
        }

        private var stateBadge: some View {
            Text(SessionStatusToken.token(for: session.state).titleKey)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(stateColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(stateColor.opacity(0.12), in: Capsule())
        }

        private var stateColor: Color {
            switch session.state {
            case .waitingApproval, .waitingInput: .orange
            case .failed: .red
            case .completed: .green
            case .paused, .cancelled, .disconnected, .stale: Color.white.opacity(0.5)
            default: .blue
            }
        }
    }

    /// A deliberately quiet always-on indicator: it only blinks briefly every four seconds.
    struct QuietAgentGlyph: View {
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
