#if os(macOS)
    import AppKit
    import SwiftUI

    public struct DisplayGeometry: Sendable, Equatable {
        public let identifier: String
        public let frame: CGRect
        public let visibleFrame: CGRect

        public init(identifier: String, frame: CGRect, visibleFrame: CGRect) {
            self.identifier = identifier
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    public enum FloatingPanelPlacement {
        public static func frame(
            panelSize: CGSize,
            displays: [DisplayGeometry],
            cursorLocation: CGPoint,
            preferredDisplayID: String? = nil,
            topPadding: CGFloat = 12
        ) -> CGRect? {
            guard !displays.isEmpty else { return nil }
            let display = preferredDisplayID.flatMap { id in displays.first(where: { $0.identifier == id }) }
                ?? displays.first(where: { $0.frame.contains(cursorLocation) })
                ?? displays.first
            guard let display else { return nil }
            let visible = display.visibleFrame
            let width = min(panelSize.width, visible.width)
            let height = min(panelSize.height, visible.height)
            let horizontalOrigin = min(max(visible.minX, visible.midX - width / 2), visible.maxX - width)
            let verticalOrigin = max(visible.minY, visible.maxY - height - topPadding)
            return CGRect(x: horizontalOrigin, y: verticalOrigin, width: width, height: height)
        }
    }

    @MainActor
    public final class FloatingPanelCoordinator {
        private let store: AgentControlStore
        private var panel: AgentControlPanel?
        private var observers: [NSObjectProtocol] = []

        public init(store: AgentControlStore) {
            self.store = store
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            })
        }

        public func stop() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            observers.removeAll()
            panel?.orderOut(nil)
        }

        public var isVisible: Bool {
            panel?.isVisible == true
        }

        public func toggle() {
            if isVisible {
                hide()
            } else {
                show()
            }
        }

        public func show() {
            let panel = panel ?? makePanel()
            self.panel = panel
            updateSize(animated: false)
            panel.orderFrontRegardless()
            panel.makeKey()
        }

        public func hide() {
            panel?.orderOut(nil)
        }

        public func setExpanded(_ expanded: Bool) {
            store.isPanelExpanded = expanded
            updateSize(animated: true)
        }

        public func reposition() {
            guard let panel else { return }
            let displays = NSScreen.screens.map(DisplayGeometry.init)
            guard let target = FloatingPanelPlacement.frame(
                panelSize: panel.frame.size,
                displays: displays,
                cursorLocation: NSEvent.mouseLocation
            ) else { return }
            panel.setFrameOrigin(target.origin)
        }

        private func makePanel() -> AgentControlPanel {
            let panel = AgentControlPanel(
                contentRect: .zero,
                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.contentView = NSHostingView(rootView: FloatingPanelView(store: store, coordinator: self))
            return panel
        }

        private func updateSize(animated: Bool) {
            guard let panel else { return }
            let size = store.isPanelExpanded ? CGSize(width: 480, height: 430) : CGSize(width: 360, height: 54)
            let displays = NSScreen.screens.map(DisplayGeometry.init)
            guard let frame = FloatingPanelPlacement.frame(
                panelSize: size,
                displays: displays,
                cursorLocation: NSEvent.mouseLocation
            ) else { return }
            if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
        }
    }

    public final class AgentControlPanel: NSPanel {
        override public var canBecomeKey: Bool {
            true
        }

        override public var canBecomeMain: Bool {
            false
        }
    }

    public struct FloatingPanelView: View {
        @Bindable var store: AgentControlStore
        let coordinator: FloatingPanelCoordinator
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        public init(store: AgentControlStore, coordinator: FloatingPanelCoordinator) {
            self.store = store
            self.coordinator = coordinator
        }

        public var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: AgentControlSpacing.standard) {
                    Image(systemName: store.pendingDecisions.isEmpty ? "bolt.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(store.pendingDecisions.isEmpty ? Color.accentColor : .orange)
                    HStack(spacing: 4) {
                        Text(store.activeSessions.count, format: .number)
                        Text("panel.active")
                    }
                    .font(.headline)
                    if !store.pendingDecisions.isEmpty {
                        HStack(spacing: 4) {
                            Text(store.pendingDecisions.count, format: .number)
                            Text("panel.inbox")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button {
                        coordinator.setExpanded(!store.isPanelExpanded)
                    } label: {
                        Image(systemName: store.isPanelExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(store.isPanelExpanded ? "panel.collapse" : "panel.expand")
                }
                .padding(.horizontal, AgentControlSpacing.standard)
                .frame(height: 54)

                if store.isPanelExpanded {
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: AgentControlSpacing.compact) {
                            if let decision = store.pendingDecisions.first {
                                DecisionRow(store: store, decision: decision)
                                    .agentCard()
                            }
                            ForEach(store.activeSessions.prefix(8), id: \.id) { session in
                                SessionRow(item: session).agentCard()
                            }
                            if store.activeSessions.isEmpty, store.pendingDecisions.isEmpty {
                                ContentUnavailableView("empty.active.title", systemImage: "moon.stars", description: Text("empty.active.message"))
                            }
                        }
                        .padding(AgentControlSpacing.standard)
                    }
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.quaternary)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.isPanelExpanded)
        }
    }

    @MainActor
    public struct GlobalHotKeySetting: Codable, Hashable {
        public static let currentVersion = 1
        public static let controlOptionSpace = GlobalHotKeySetting(
            version: currentVersion,
            keyCode: 49,
            modifierRawValue: NSEvent.ModifierFlags([.control, .option]).rawValue
        )
        public static let commandShiftA = GlobalHotKeySetting(
            version: currentVersion,
            keyCode: 0,
            modifierRawValue: NSEvent.ModifierFlags([.command, .shift]).rawValue
        )

        public let version: Int
        public let keyCode: UInt16
        public let modifierRawValue: UInt

        public init(version: Int = currentVersion, keyCode: UInt16, modifierRawValue: UInt) {
            self.version = version
            self.keyCode = keyCode
            self.modifierRawValue = modifierRawValue
        }

        fileprivate var modifiers: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifierRawValue)
                .intersection(.deviceIndependentFlagsMask)
        }
    }

    @MainActor
    public final class GlobalHotKeyPreferences {
        public static let storageKey = "globalHotKey.v1"
        private let defaults: UserDefaults

        public init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        public func load() -> GlobalHotKeySetting {
            guard let data = defaults.data(forKey: Self.storageKey),
                  let value = try? JSONDecoder().decode(GlobalHotKeySetting.self, from: data),
                  value.version == GlobalHotKeySetting.currentVersion
            else { return .controlOptionSpace }
            return value
        }

        public func save(_ value: GlobalHotKeySetting) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    @MainActor
    public final class GlobalHotKeyController {
        private var globalMonitor: Any?
        private var localMonitor: Any?
        private let action: @MainActor () -> Void
        private var setting: GlobalHotKeySetting

        public init(
            setting: GlobalHotKeySetting = .controlOptionSpace,
            action: @escaping @MainActor () -> Void
        ) {
            self.setting = setting
            self.action = action
        }

        public func update(_ value: GlobalHotKeySetting) {
            let wasRunning = globalMonitor != nil || localMonitor != nil
            stop()
            setting = value
            if wasRunning {
                start()
            }
        }

        public func start() {
            guard globalMonitor == nil, localMonitor == nil else { return }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard self?.matches(event) == true else { return }
                Task { @MainActor in self?.action() }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard self?.matches(event) == true else { return event }
                self?.action()
                return nil
            }
        }

        public func stop() {
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
            }
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
            }
            globalMonitor = nil
            localMonitor = nil
        }

        private func matches(_ event: NSEvent) -> Bool {
            event.keyCode == setting.keyCode
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == setting.modifiers
        }
    }

    private extension DisplayGeometry {
        init(screen: NSScreen) {
            let identifier = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
                ?? String(describing: screen)
            self.init(identifier: identifier, frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }
#endif
