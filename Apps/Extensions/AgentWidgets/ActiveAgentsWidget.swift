import AgentCompanion
import SwiftUI
import WidgetKit

@main
struct AgentWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ActiveAgentsWidget()
        PendingApprovalsWidget()
    }
}

private struct SurfaceEntry: TimelineEntry {
    let date: Date
    let snapshot: CompanionWidgetSnapshot
}

private struct SurfaceProvider: TimelineProvider {
    func placeholder(in context: Context) -> SurfaceEntry {
        .init(
            date: .now,
            snapshot: .init(activeAgentCount: 2, pendingApprovalCount: 1, lastCompletedTask: "Tests passed", generatedAt: .now)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (SurfaceEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<SurfaceEntry>) -> Void) {
        let value = entry()
        completion(Timeline(entries: [value], policy: .after(value.date.addingTimeInterval(15 * 60))))
    }

    private func entry() -> SurfaceEntry {
        let fallback = CompanionWidgetSnapshot(
            activeAgentCount: 0, pendingApprovalCount: 0,
            lastCompletedTask: nil, generatedAt: .now
        )
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: CompanionSurfaceSnapshot.storageKey),
              let snapshot = try? CompanionSurfaceSnapshot.decode(data)
        else { return .init(date: .now, snapshot: fallback) }
        return .init(date: .now, snapshot: snapshot.widget)
    }

    private var appGroupID: String {
        Bundle.main.object(forInfoDictionaryKey: "AgentControlAppGroup") as? String
            ?? "group.com.yusuf.agentcontrol"
    }
}

private struct ActiveAgentsWidget: Widget {
    let kind = "ActiveAgentsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SurfaceProvider()) { entry in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    YusufiwtBrandGlyph(size: 18)
                    Text(String(localized: "Active agents"))
                }
                .font(.headline).foregroundStyle(.tint)
                Text(entry.snapshot.activeAgentCount, format: .number)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                if let completed = entry.snapshot.lastCompletedTask {
                    Label(completed, systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(String(localized: "No recent completion"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(URL(string: "agentcontrol://session"))
        }
        .configurationDisplayName(String(localized: "Active Agents"))
        .description(String(localized: "See active agent sessions and the latest completion."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct PendingApprovalsWidget: Widget {
    let kind = "PendingApprovalsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SurfaceProvider()) { entry in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    YusufiwtBrandGlyph(size: 18)
                    Text(String(localized: "Pending approvals"))
                }
                .font(.headline).foregroundStyle(.orange)
                Text(entry.snapshot.pendingApprovalCount, format: .number)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text(String(localized: "Open yusufiwt to review"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(URL(string: "agentcontrol://inbox"))
        }
        .configurationDisplayName(String(localized: "Pending Approvals"))
        .description(String(localized: "See how many agent approvals need attention."))
        .supportedFamilies([.systemSmall])
    }
}
