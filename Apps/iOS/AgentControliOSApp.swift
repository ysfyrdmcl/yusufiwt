import SwiftUI

@main
struct AgentControliOSApp: App {
    var body: some Scene {
        WindowGroup {
            Text(String(localized: "app.name"))
                .accessibilityAddTraits(.isHeader)
        }
    }
}
