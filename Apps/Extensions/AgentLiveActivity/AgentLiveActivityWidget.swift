import SwiftUI
import WidgetKit

@main
struct AgentLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        AgentSessionStatusWidget()
    }
}

private struct AgentSessionStatusWidget: Widget {
    let kind = "AgentSessionStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { _ in
            Text("AgentControl")
        }
        .configurationDisplayName("AgentControl")
        .description("Agent session status")
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
