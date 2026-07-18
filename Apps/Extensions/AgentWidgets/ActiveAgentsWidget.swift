import SwiftUI
import WidgetKit

@main
struct AgentWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ActiveAgentsWidget()
    }
}

private struct ActiveAgentsWidget: Widget {
    let kind = "ActiveAgentsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { _ in
            Text("AgentControl")
        }
        .configurationDisplayName("Active Agents")
        .description("Agent session summary")
    }
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (Entry) -> Void) {
        completion(Entry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}

private struct Entry: TimelineEntry {
    let date: Date
}
