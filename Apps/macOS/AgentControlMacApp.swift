import AgentMacUI
import AppKit
import SwiftUI

@main
struct AgentControlMacApp: App {
    @NSApplicationDelegateAdaptor(AgentControlAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(String(localized: "app.name"), id: "dashboard") {
            DashboardView(store: appDelegate.store)
        }
        .defaultSize(width: 1060, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("menu.togglePanel") { appDelegate.togglePanel() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarContent(store: appDelegate.store, togglePanel: appDelegate.togglePanel)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AgentControlAppDelegate: NSObject, NSApplicationDelegate {
    let notificationCoordinator = MacNotificationCoordinator()
    lazy var store = AgentControlStore(notificationCoordinator: notificationCoordinator)
    private var panelCoordinator: FloatingPanelCoordinator?
    private var hotKeyController: GlobalHotKeyController?

    func applicationDidFinishLaunching(_: Notification) {
        notificationCoordinator.responseHandler = { [weak self] response in
            Task { await self?.store.handleNotificationResponse(response) }
        }
        Task { await notificationCoordinator.configure() }
        let coordinator = FloatingPanelCoordinator(store: store)
        panelCoordinator = coordinator
        hotKeyController = GlobalHotKeyController { [weak coordinator] in coordinator?.toggle() }
        hotKeyController?.start()
        store.start()
    }

    func applicationWillTerminate(_: Notification) {
        hotKeyController?.stop()
        panelCoordinator?.stop()
        store.stop()
    }

    func togglePanel() {
        panelCoordinator?.toggle()
    }
}

private struct MenuBarLabel: View {
    let store: AgentControlStore

    var body: some View {
        Image(systemName: store.pendingDecisions.isEmpty ? "bolt.circle" : "exclamationmark.circle.fill")
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel(store.pendingDecisions.isEmpty ? "menu.status.normal" : "menu.status.attention")
    }
}

private struct MenuBarContent: View {
    let store: AgentControlStore
    let togglePanel: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("app.name").font(.headline)
                Spacer()
                Circle()
                    .fill(store.connectionState == .online ? Color.green : .orange)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(store.connectionState == .online ? "connection.online" : "connection.offline")
            }
            Divider()
            HStack {
                Label {
                    Text("menu.active") + Text(" \(store.activeSessions.count)")
                } icon: {
                    Image(systemName: "bolt.fill")
                }
                Spacer()
                Label {
                    Text("menu.inbox") + Text(" \(store.pendingDecisions.count)")
                } icon: {
                    Image(systemName: "tray.full")
                }
            }
            .font(.callout)
            Button("menu.openDashboard") {
                openWindow(id: "dashboard")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o")
            Button("menu.togglePanel", action: togglePanel)
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("menu.quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280)
    }
}
