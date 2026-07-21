import AgentMacUI
import AppKit
import SwiftUI

private struct ControlCenterRootView: View {
    let store: AgentControlStore
    let phase10: Phase10Coordinator
    @Bindable var settings: MacSettingsState

    var body: some View {
        DashboardView(store: store, phase10: phase10)
            .environment(\.locale, settings.application.language.locale)
    }
}

@MainActor
final class ControlCenterWindowController: NSWindowController, NSWindowDelegate {
    private let settings: MacSettingsState

    init(store: AgentControlStore, phase10: Phase10Coordinator, settings: MacSettingsState) {
        self.settings = settings
        let rootView = ControlCenterRootView(store: store, phase10: phase10, settings: settings)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1060, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "controlCenter.title", locale: settings.application.language.locale)
        window.contentView = NSHostingView(rootView: rootView)
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 860, height: 560)
        window.setFrameAutosaveName("AgentControlControlCenter")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func show() {
        window?.title = String(localized: "controlCenter.title", locale: settings.application.language.locale)
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
