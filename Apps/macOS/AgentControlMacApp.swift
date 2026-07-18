import AgentLocalIPC
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
                    .keyboardShortcut(.space, modifiers: [.control, .option])
            }
        }

        MenuBarExtra {
            MenuBarContent(store: appDelegate.store, togglePanel: appDelegate.togglePanel)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            HotKeySettingsView(
                preferences: appDelegate.hotKeyPreferences,
                onChange: appDelegate.updateHotKey
            )
        }
    }
}

@MainActor
final class AgentControlAppDelegate: NSObject, NSApplicationDelegate {
    let notificationCoordinator = MacNotificationCoordinator()
    lazy var store = AgentControlStore(notificationCoordinator: notificationCoordinator)
    private var panelCoordinator: FloatingPanelCoordinator?
    private var hotKeyController: GlobalHotKeyController?
    private var launchAgentManager: LaunchAgentManager?
    let hotKeyPreferences = GlobalHotKeyPreferences()

    func applicationDidFinishLaunching(_: Notification) {
        notificationCoordinator.responseHandler = { [weak self] response in
            Task { await self?.store.handleNotificationResponse(response) }
        }
        Task { await notificationCoordinator.configure() }
        let coordinator = FloatingPanelCoordinator(store: store)
        panelCoordinator = coordinator
        hotKeyController = GlobalHotKeyController(setting: hotKeyPreferences.load()) { [weak coordinator] in coordinator?.toggle() }
        hotKeyController?.start()
        Task { [weak self] in
            guard let self else { return }
            do {
                let paths = try AgentControlPaths.userDefault()
                let manager = LaunchAgentManager(paths: paths)
                launchAgentManager = manager
                if await manager.status() != .enabled {
                    _ = try await manager.register()
                }
            } catch {
                // The store exposes the helper as offline and keeps retrying;
                // registration approval can be completed in System Settings.
            }
            store.start()
        }
    }

    func applicationWillTerminate(_: Notification) {
        hotKeyController?.stop()
        panelCoordinator?.stop()
        store.stop()
    }

    func togglePanel() {
        panelCoordinator?.toggle()
    }

    func updateHotKey(_ value: GlobalHotKeySetting) {
        hotKeyPreferences.save(value)
        hotKeyController?.update(value)
    }
}

private struct HotKeySettingsView: View {
    @State private var selection: GlobalHotKeySetting
    let onChange: (GlobalHotKeySetting) -> Void

    init(preferences: GlobalHotKeyPreferences, onChange: @escaping (GlobalHotKeySetting) -> Void) {
        _selection = State(initialValue: preferences.load())
        self.onChange = onChange
    }

    var body: some View {
        Form {
            Picker("settings.hotkey", selection: $selection) {
                Text("settings.hotkey.controlOptionSpace").tag(GlobalHotKeySetting.controlOptionSpace)
                Text("settings.hotkey.commandShiftA").tag(GlobalHotKeySetting.commandShiftA)
            }
            .onChange(of: selection) { _, value in onChange(value) }
        }
        .padding()
        .frame(width: 420)
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
                .keyboardShortcut(.space, modifiers: [.control, .option])
            Divider()
            Button("menu.quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280)
    }
}
