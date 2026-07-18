import ActivityKit
import AgentCompanion
import AgentDomain
import SwiftUI
import WidgetKit

@main
struct AgentLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        AgentSessionLiveActivity()
    }
}

private struct AgentSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenActivityView(context: context)
                .activityBackgroundTint(.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(deepLink(context.attributes.sessionID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.agentName, systemImage: stateSymbol(context.state.state))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedText(since: context.attributes.startedAt)
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.attributes.projectName).lineLimit(1)
                        Spacer()
                        Text(stateTitle(context.state.state)).foregroundStyle(stateColor(context.state.state))
                    }
                    .font(.caption)
                }
            } compactLeading: {
                Image(systemName: stateSymbol(context.state.state))
                    .foregroundStyle(stateColor(context.state.state))
            } compactTrailing: {
                elapsedText(since: context.attributes.startedAt)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 42)
            } minimal: {
                Image(systemName: stateSymbol(context.state.state))
                    .foregroundStyle(stateColor(context.state.state))
            }
            .widgetURL(deepLink(context.attributes.sessionID))
            .keylineTint(stateColor(context.state.state))
        }
    }
}

private struct LockScreenActivityView: View {
    let context: ActivityViewContext<AgentActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: stateSymbol(context.state.state))
                .font(.title2)
                .foregroundStyle(stateColor(context.state.state))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.projectName).font(.headline).lineLimit(1)
                Text("\(context.attributes.agentName) · \(stateTitle(context.state.state))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            elapsedText(since: context.attributes.startedAt)
                .font(.caption.monospacedDigit())
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}

private func elapsedText(since date: Date) -> some View {
    Text(timerInterval: date ... .distantFuture, countsDown: false)
        .lineLimit(1)
}

private func deepLink(_ sessionID: UUID) -> URL? {
    URL(string: "agentcontrol://session/\(sessionID.uuidString.lowercased())")
}

private func stateTitle(_ state: SessionState) -> String {
    switch state {
    case .waitingApproval: String(localized: "Waiting approval")
    case .waitingInput: String(localized: "Waiting input")
    case .completed: String(localized: "Completed")
    case .failed: String(localized: "Failed")
    case .cancelled: String(localized: "Cancelled")
    default: String(localized: "Working")
    }
}

private func stateSymbol(_ state: SessionState) -> String {
    switch state {
    case .waitingApproval, .waitingInput: "exclamationmark.bubble.fill"
    case .completed: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    case .cancelled: "stop.circle.fill"
    default: "waveform.path.ecg"
    }
}

private func stateColor(_ state: SessionState) -> Color {
    switch state {
    case .waitingApproval, .waitingInput: .orange
    case .completed: .green
    case .failed, .cancelled: .red
    default: .cyan
    }
}
