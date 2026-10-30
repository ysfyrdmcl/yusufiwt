import AgentLocalIPC
import AgentMacUI
import AppKit
import ServiceManagement
import SwiftUI
#if canImport(Sparkle)
    import Sparkle
#endif

@main
struct AgentControlMacApp: App {
    @NSApplicationDelegateAdaptor(AgentControlAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                store: appDelegate.store,
                settings: appDelegate.settingsState,
                togglePanel: appDelegate.togglePanel,
                openControlCenter: { appDelegate.openControlCenter() },
                openSettings: appDelegate.openSettings,
                updateNotifications: appDelegate.updateNotifications
            )
            .environment(\.locale, appDelegate.settingsState.application.language.locale)
        } label: {
            MenuBarLabel(store: appDelegate.store)
                .environment(\.locale, appDelegate.settingsState.application.language.locale)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("menu.settings", action: appDelegate.openSettings)
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("menu.checkForUpdates") { appDelegate.checkForUpdates() }
                    .disabled(!appDelegate.canCheckForUpdates)
                Button("menu.openControlCenter") { appDelegate.openControlCenter() }
                    .keyboardShortcut("o", modifiers: [.command])
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
    }
}

@MainActor
final class AgentControlAppDelegate: NSObject, NSApplicationDelegate {
    let notificationPreferences = MacNotificationPreferencesStore()
    let applicationPreferences = MacLocalPreferencesStore()
    let hotKeyPreferences = GlobalHotKeyPreferences()
    lazy var settingsState = MacSettingsState(
        hotKey: hotKeyPreferences.load(),
        notifications: notificationPreferences.load(),
        application: applicationPreferences.value
    )
    lazy var notificationCoordinator = MacNotificationCoordinator(preferences: notificationPreferences.load())
    #if canImport(Sparkle)
        private let updateController = SparkleUpdateController()
    #endif
    lazy var store = AgentControlStore(notificationCoordinator: notificationCoordinator)
    lazy var phase10 = Phase10Coordinator(notificationCoordinator: notificationCoordinator)
    private var panelCoordinator: FloatingPanelCoordinator?
    private var controlCenterWindowController: ControlCenterWindowController?
    private var settingsWindowController: MacSettingsWindowController?
    private var hotKeyController: GlobalHotKeyController?
    private var launchAgentManager: LaunchAgentManager?
    private let codexStartup = CodexDesktopStartup()
    private var hasPendingNotificationReview = false

    func applicationDidFinishLaunching(_: Notification) {
        installNotificationHandlers()
        if phase10.isCompleted {
            Task { await notificationCoordinator.configure() }
        }
        let coordinator = FloatingPanelCoordinator(
            store: store,
            notificationPreferences: settingsState.notifications,
            applicationPreferences: settingsState.application,
            openControlCenter: { [weak self] in self?.openControlCenter() },
            openSettings: { [weak self] in self?.openSettings() },
            notificationPreferencesChanged: { [weak self] value in self?.updateNotifications(value) }
        )
        panelCoordinator = coordinator
        coordinator.start()
        if hasPendingNotificationReview {
            hasPendingNotificationReview = false
            coordinator.presentInbox()
        }
        notificationCoordinator.setUsesNotchSurface(true)
        hotKeyController = GlobalHotKeyController(setting: hotKeyPreferences.load()) { [weak coordinator] in coordinator?.toggle() }
        hotKeyController?.start()
        startServices()
        if phase10.isOnboardingPresented {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.openControlCenter(.integrations)
            }
        }
    }

    private func startServices() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let paths = try AgentControlPaths.userDefault()
                let manager = LaunchAgentManager(paths: paths)
                launchAgentManager = manager
                do {
                    try await Task.sleep(for: .seconds(2))
                    let response = UnixSocketClient(socketURL: paths.socketURL)
                        .sendOrNeutral(.health, timeoutMilliseconds: 1000)
                    if case .neutral(reason: .helperUnavailable) = response {
                        let state = await manager.status()
                        let registered = state == .enabled
                            ? try await manager.repairRegistration()
                            : try await manager.register()
                        if registered == .requiresApproval {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "startup.helper.failed")
                alert.informativeText = String(localized: "startup.helper.permission")
                alert.runModal()
            }
            store.start()
            codexStartup.start(store: store)
        }
    }

    private func installNotificationHandlers() {
        notificationCoordinator.responseHandler = { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await store.handleNotificationResponse(response)
                if response.action == .review {
                    presentNotificationReviewWhenReady()
                }
            }
        }
        notificationCoordinator.reviewHandler = { [weak self] in
            self?.presentNotificationReviewWhenReady()
        }
    }

    func applicationWillTerminate(_: Notification) {
        codexStartup.stop()
        hotKeyController?.stop()
        panelCoordinator?.stop()
        store.stop()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openControlCenter(phase10.isOnboardingPresented ? .integrations : store.selectedSection)
            return false
        }
        return true
    }

    func togglePanel() {
        panelCoordinator?.toggle()
    }

    private func presentNotificationReviewWhenReady() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard let panelCoordinator else {
            hasPendingNotificationReview = true
            return
        }
        panelCoordinator.presentInbox()
    }

    func openControlCenter(_ section: DashboardSection = .integrations) {
        store.selectedSection = section
        let controller = controlCenterWindowController ?? ControlCenterWindowController(
            store: store,
            phase10: phase10,
            settings: settingsState
        )
        controlCenterWindowController = controller
        controller.show()
        Task { await store.refreshSelectedOperations() }
    }

    func application(_: NSApplication, open urls: [URL]) {
        for url in urls {
            store.handleNavigationCallback(url)
        }
    }

    func openSettings() {
        let controller = settingsWindowController ?? MacSettingsWindowController(rootView: MacLocalSettingsView(
            state: settingsState,
            onHotKeyChange: { [weak self] in self?.updateHotKey($0) },
            onNotificationChange: { [weak self] in self?.updateNotifications($0) },
            onApplicationChange: { [weak self] in self?.updateApplicationPreferences($0) },
            openControlCenter: { [weak self] in self?.openControlCenter($0) }
        ))
        settingsWindowController = controller
        panelCoordinator?.setExpanded(false)
        controller.show(locale: settingsState.application.language.locale)
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
        settingsState.hotKey = value
        hotKeyPreferences.save(value)
        hotKeyController?.update(value)
    }

    func updateNotifications(_ value: MacNotificationPreferences) {
        settingsState.notifications = value
        notificationPreferences.save(value)
        Task { await notificationCoordinator.updatePreferences(value) }
        panelCoordinator?.updateNotificationPreferences(value)
    }

    func updateApplicationPreferences(_ value: MacLocalPreferences) {
        settingsState.application = value
        applicationPreferences.save(value)
        panelCoordinator?.updateApplicationPreferences(value)
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
    @Bindable var settings: MacSettingsState
    let togglePanel: () -> Void
    let openControlCenter: () -> Void
    let openSettings: () -> Void
    let updateNotifications: (MacNotificationPreferences) -> Void

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
                    Text(session.adapterID.rawValue)
                        + Text(" · ")
                        + Text(LocalizedStringKey(NotchPanelFormatting.stateTitleKey(session.state)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(Array(store.pendingDecisions.prefix(5)), id: \.requestID) { decision in
                Label(decision.projectName ?? String(localized: "menu.agent"), systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
            }
            Button("menu.togglePanel", action: togglePanel)
                .keyboardShortcut(.space, modifiers: [.control, .option])
                .accessibilityIdentifier("menu.togglePanel")
            Button("menu.openControlCenter", action: openControlCenter)
                .keyboardShortcut("o")
                .accessibilityIdentifier("menu.openControlCenter")
            Button(action: openSettings) {
                Label("menu.settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("menu.openSettings")
            Button(action: toggleSound) {
                Label(
                    settings.notifications.soundEnabled ? "settings.sound.on" : "settings.sound.off",
                    systemImage: settings.notifications.soundEnabled ? "speaker.wave.2" : "speaker.slash"
                )
            }
            .accessibilityIdentifier("menu.toggleSound")
            Divider()
            Button("menu.quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280)
    }

    private func toggleSound() {
        var value = settings.notifications
        value.soundEnabled.toggle()
        settings.notifications = value
        updateNotifications(value)
    }
}
