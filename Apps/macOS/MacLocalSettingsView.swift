import AgentMacUI
import Observation
import SwiftUI

@MainActor
@Observable
final class MacSettingsState {
    var hotKey: GlobalHotKeySetting
    var notifications: MacNotificationPreferences
    var application: MacLocalPreferences

    init(
        hotKey: GlobalHotKeySetting,
        notifications: MacNotificationPreferences,
        application: MacLocalPreferences
    ) {
        self.hotKey = hotKey
        self.notifications = notifications
        self.application = application
    }
}

struct MacLocalSettingsView: View {
    @Bindable var state: MacSettingsState
    let onHotKeyChange: (GlobalHotKeySetting) -> Void
    let onNotificationChange: (MacNotificationPreferences) -> Void
    let onApplicationChange: (MacLocalPreferences) -> Void
    let openControlCenter: (DashboardSection) -> Void

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("settings.general", systemImage: "gear") }
            languageSettings
                .tabItem { Label("settings.language", systemImage: "character.bubble") }
            notificationSettings
                .tabItem { Label("settings.notifications", systemImage: "bell") }
            appearanceSettings
                .tabItem { Label("settings.panel", systemImage: "macwindow") }
            advancedSettings
                .tabItem { Label("settings.advanced", systemImage: "wrench.and.screwdriver") }
        }
        .environment(\.locale, state.application.language.locale)
        .padding(16)
        .frame(width: 600, height: 470)
    }

    private var generalSettings: some View {
        Form {
            Section("settings.general.startup") {
                LabeledContent("settings.general.helperLifecycle") {
                    Label("settings.general.managedAutomatically", systemImage: "checkmark.shield")
                        .foregroundStyle(.secondary)
                }
                Text("settings.general.helperExplanation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.general.shortcuts") {
                Picker("settings.hotkey", selection: $state.hotKey) {
                    Text("settings.hotkey.controlOptionSpace").tag(GlobalHotKeySetting.controlOptionSpace)
                    Text("settings.hotkey.commandShiftA").tag(GlobalHotKeySetting.commandShiftA)
                }
                .onChange(of: state.hotKey) { _, value in onHotKeyChange(value) }
            }

            Section("settings.general.attention") {
                Toggle("settings.general.showForAttention", isOn: applicationBinding(\.showPanelForAttention))
                Toggle("settings.general.closeAfterDecision", isOn: applicationBinding(\.closePanelAfterDecision))
            }

            Button("menu.openControlCenter") { openControlCenter(.integrations) }
                .accessibilityIdentifier("settings.openControlCenter")
        }
        .formStyle(.grouped)
    }

    private var languageSettings: some View {
        Form {
            Section("settings.language.selection") {
                Picker("settings.language", selection: applicationBinding(\.language)) {
                    Text("settings.language.system").tag(MacLocalLanguage.system)
                    Text("settings.language.turkish").tag(MacLocalLanguage.turkish)
                    Text("settings.language.english").tag(MacLocalLanguage.english)
                }
                .pickerStyle(.radioGroup)
                Text("settings.language.relaunchNote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var notificationSettings: some View {
        Form {
            Section("settings.notifications.delivery") {
                Toggle("settings.notifications.enabled", isOn: notificationBinding(\.enabled))
                Toggle("settings.notifications.sound", isOn: notificationBinding(\.soundEnabled))
            }

            Section("settings.notifications.events") {
                Toggle("settings.notifications.approvals", isOn: notificationBinding(\.approvalNotificationsEnabled))
                Toggle("settings.notifications.questionsPlans", isOn: notificationBinding(\.questionPlanNotificationsEnabled))
                Toggle("settings.notifications.completed", isOn: notificationBinding(\.completedNotificationsEnabled))
                Toggle("settings.notifications.errors", isOn: notificationBinding(\.failedNotificationsEnabled))
                Toggle("settings.notifications.idle", isOn: notificationBinding(\.longRunningIdleNotificationsEnabled))
            }

            Section("settings.notifications.privacy") {
                Toggle("settings.notifications.sensitivePreview", isOn: Binding(
                    get: { state.notifications.privacyLevel == .projectAndEvent },
                    set: { enabled in
                        updateNotifications { $0.privacyLevel = enabled ? .projectAndEvent : .generic }
                    }
                ))
                Text("settings.notifications.sensitivePreviewHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.general.attention") {
                Toggle("settings.general.showForAttention", isOn: applicationBinding(\.showPanelForAttention))
            }
        }
        .formStyle(.grouped)
    }

    private var appearanceSettings: some View {
        Form {
            Section("settings.panel.behavior") {
                Toggle("settings.panel.autoHide", isOn: applicationBinding(\.autoHideActivity))
                LabeledContent("settings.panel.display") {
                    Text("settings.panel.automaticDisplay")
                        .foregroundStyle(.secondary)
                }
            }
            Section("settings.panel.accessibility") {
                LabeledContent("settings.panel.motion") {
                    Text("settings.panel.systemMotion")
                        .foregroundStyle(.secondary)
                }
                Text("settings.panel.motionHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var advancedSettings: some View {
        Form {
            Section("settings.advanced.health") {
                Button("settings.advanced.openDiagnostics") { openControlCenter(.diagnostics) }
                Button("settings.advanced.openIntegrations") { openControlCenter(.integrations) }
            }
            Section("settings.advanced.data") {
                Text("settings.advanced.dataHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("settings.advanced.openPrivacy") { openControlCenter(.privacy) }
            }
        }
        .formStyle(.grouped)
    }

    private func applicationBinding<Value>(_ keyPath: WritableKeyPath<MacLocalPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { state.application[keyPath: keyPath] },
            set: { newValue in
                var value = state.application
                value[keyPath: keyPath] = newValue
                state.application = value
                onApplicationChange(value)
            }
        )
    }

    private func notificationBinding(_ keyPath: WritableKeyPath<MacNotificationPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { state.notifications[keyPath: keyPath] },
            set: { newValue in updateNotifications { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func updateNotifications(_ change: (inout MacNotificationPreferences) -> Void) {
        var value = state.notifications
        change(&value)
        state.notifications = value
        onNotificationChange(value)
    }
}
