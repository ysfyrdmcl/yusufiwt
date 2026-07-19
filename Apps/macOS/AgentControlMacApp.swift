import AgentLocalIPC
import AgentMacUI
import AppKit
import SwiftUI
#if canImport(Sparkle)
    import Sparkle
#endif

@main
struct AgentControlMacApp: App {
    @NSApplicationDelegateAdaptor(AgentControlAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(String(localized: "app.name"), id: "dashboard") {
            DashboardView(store: appDelegate.store, phase10: appDelegate.phase10)
                .onOpenURL { appDelegate.store.handleNavigationCallback($0) }
        }
        .defaultSize(width: 1060, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("menu.checkForUpdates") { appDelegate.checkForUpdates() }
                    .disabled(!appDelegate.canCheckForUpdates)
                Button("menu.togglePanel") { appDelegate.togglePanel() }
                    .keyboardShortcut(.space, modifiers: [.control, .option])
            }
            #if DEBUG
                CommandMenu("Developer") {
                    Button("Load Notch UI Demo") { appDelegate.loadNotchDemo() }
                    Button("Resume Live Agent Data") { appDelegate.resumeLiveData() }
                }
            #endif
        }

        MenuBarExtra {
            MenuBarContent(store: appDelegate.store, togglePanel: appDelegate.togglePanel)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacLocalSettingsView(
                preferences: appDelegate.hotKeyPreferences,
                notificationStore: appDelegate.notificationPreferences,
                onHotKeyChange: appDelegate.updateHotKey,
                onNotificationChange: appDelegate.updateNotifications
            )
        }
    }
}

@MainActor
final class AgentControlAppDelegate: NSObject, NSApplicationDelegate {
    let notificationPreferences = MacNotificationPreferencesStore()
    lazy var notificationCoordinator = MacNotificationCoordinator(preferences: notificationPreferences.load())
    #if canImport(Sparkle)
        private let updateController = SparkleUpdateController()
    #endif
    lazy var store = AgentControlStore(notificationCoordinator: notificationCoordinator)
    lazy var phase10 = Phase10Coordinator(notificationCoordinator: notificationCoordinator)
    private var panelCoordinator: FloatingPanelCoordinator?
    private var hotKeyController: GlobalHotKeyController?
    private var launchAgentManager: LaunchAgentManager?
    let hotKeyPreferences = GlobalHotKeyPreferences()

    func applicationDidFinishLaunching(_: Notification) {
        notificationCoordinator.responseHandler = { [weak self] response in
            Task { await self?.store.handleNotificationResponse(response) }
        }
        notificationCoordinator.reviewHandler = { [weak self] in
            self?.panelCoordinator?.presentInbox()
        }
        if phase10.isCompleted {
            Task { await notificationCoordinator.configure() }
        }
        let coordinator = FloatingPanelCoordinator(
            store: store,
            notificationPreferences: notificationPreferences.load()
        )
        panelCoordinator = coordinator
        coordinator.start()
        notificationCoordinator.setUsesNotchSurface(true)
        hotKeyController = GlobalHotKeyController(setting: hotKeyPreferences.load()) { [weak coordinator] in coordinator?.toggle() }
        hotKeyController?.start()
        Task { [weak self] in
            guard let self else { return }
            do {
                let paths = try AgentControlPaths.userDefault()
                let manager = LaunchAgentManager(paths: paths)
                launchAgentManager = manager
                if phase10.isCompleted {
                    try await Task.sleep(for: .seconds(2))
                    let response = UnixSocketClient(socketURL: paths.socketURL)
                        .sendOrNeutral(.health, timeoutMilliseconds: 1000)
                    if case .neutral(reason: .helperUnavailable) = response {
                        let state = await manager.status()
                        _ = state == .enabled
                            ? try await manager.repairRegistration()
                            : try await manager.register()
                    }
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

    #if DEBUG
        func loadNotchDemo() {
            store.loadNotchDemo()
            panelCoordinator?.setExpanded(false)
        }

        func resumeLiveData() {
            store.resumeLiveData()
        }
    #endif

    var canCheckForUpdates: Bool {
        #if canImport(Sparkle)
            updateController.isConfigured
        #else
            false
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
            updateController.checkForUpdates()
        #endif
    }

    func updateHotKey(_ value: GlobalHotKeySetting) {
        hotKeyPreferences.save(value)
        hotKeyController?.update(value)
    }

    func updateNotifications(_ value: MacNotificationPreferences) {
        notificationPreferences.save(value)
        notificationCoordinator.updatePreferences(value)
        panelCoordinator?.updateNotificationPreferences(value)
    }
}

private struct MacLocalSettingsView: View {
    @State private var selection: GlobalHotKeySetting
    @State private var notifications: MacNotificationPreferences
    let onHotKeyChange: (GlobalHotKeySetting) -> Void
    let onNotificationChange: (MacNotificationPreferences) -> Void

    init(
        preferences: GlobalHotKeyPreferences,
        notificationStore: MacNotificationPreferencesStore,
        onHotKeyChange: @escaping (GlobalHotKeySetting) -> Void,
        onNotificationChange: @escaping (MacNotificationPreferences) -> Void
    ) {
        _selection = State(initialValue: preferences.load())
        _notifications = State(initialValue: notificationStore.load())
        self.onHotKeyChange = onHotKeyChange
        self.onNotificationChange = onNotificationChange
    }

    var body: some View {
        Form {
            Picker("settings.hotkey", selection: $selection) {
                Text("settings.hotkey.controlOptionSpace").tag(GlobalHotKeySetting.controlOptionSpace)
                Text("settings.hotkey.commandShiftA").tag(GlobalHotKeySetting.commandShiftA)
            }
            .onChange(of: selection) { _, value in onHotKeyChange(value) }
            Section("Notifications") {
                Toggle("Enabled", isOn: $notifications.enabled)
                Toggle("Sounds", isOn: $notifications.soundEnabled)
                Toggle("Approvals and questions", isOn: $notifications.decisionNotificationsEnabled)
                Toggle("Completed sessions", isOn: $notifications.completedNotificationsEnabled)
                Toggle("Failed sessions", isOn: $notifications.failedNotificationsEnabled)
                Toggle("Long-running and idle", isOn: $notifications.longRunningIdleNotificationsEnabled)
                Picker("Privacy", selection: $notifications.privacyLevel) {
                    Text("Generic").tag(NotificationPrivacyLevel.generic)
                    Text("Project and event").tag(NotificationPrivacyLevel.projectAndEvent)
                }
            }
            .onChange(of: notifications) { _, value in onNotificationChange(value) }
        }
        .padding()
        .frame(width: 420)
    }
}

private struct MenuBarLabel: View {
    let store: AgentControlStore

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image("YusufiwtMenuBarMark")
                .resizable()
                .renderingMode(.template)
                .frame(width: 17, height: 17)
            if !store.pendingDecisions.isEmpty {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
                    .overlay { Circle().stroke(.black.opacity(0.55), lineWidth: 1) }
                    .offset(x: 2, y: -1)
            }
        }
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
                YusufiwtBrandMark(size: 28)
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
            ForEach(Array(store.attentionSessions.prefix(5))) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName).font(.callout.bold())
                    Text("\(session.adapterID.rawValue) · \(session.state.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(Array(store.pendingDecisions.prefix(5)), id: \.requestID) { decision in
                let canResolveInline = DecisionAvailability.evaluate(decision) == .actionable
                    && (decision.kind == .approval || decision.kind == .plan)
                HStack {
                    Text(decision.projectName ?? "Agent")
                    Spacer()
                    if canResolveInline {
                        Button("Approve") { Task { _ = await store.resolve(decision, as: .approve) } }
                        Button("Deny") { Task { _ = await store.resolve(decision, as: .deny) } }
                    }
                }
            }
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
