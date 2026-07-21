#if os(macOS)
    import AgentDomain
    import AgentPersistence
    import AppKit
    import Observation
    import SwiftUI

    @MainActor
    @Observable
    // The coordinator keeps AppKit window lifecycle and the observation transition loop on the main actor.
    // swiftlint:disable:next type_body_length
    public final class FloatingPanelCoordinator {
        public private(set) var mode: NotchPanelMode = .compact
        public private(set) var notchWidth: CGFloat = 0
        public private(set) var notchHeight: CGFloat = 0
        public private(set) var applicationPreferences: MacLocalPreferences
        public private(set) var isNotificationSoundEnabled: Bool

        @ObservationIgnored
        private let store: AgentControlStore
        @ObservationIgnored
        private var notificationPreferences: MacNotificationPreferences
        @ObservationIgnored
        private let openControlCenterHandler: @MainActor () -> Void
        @ObservationIgnored
        private let notificationPreferencesHandler: @MainActor (MacNotificationPreferences) -> Void
        @ObservationIgnored
        private var panel: AgentControlPanel?
        @ObservationIgnored
        private var observers: [NSObjectProtocol] = []
        @ObservationIgnored
        private var collapseTask: Task<Void, Never>?
        @ObservationIgnored
        private var knownDecisionKeys: Set<String> = []
        @ObservationIgnored
        private var knownSessionFingerprints: [SessionID: String] = [:]
        @ObservationIgnored
        private var highlightedSessionID: SessionID?
        @ObservationIgnored
        private var knownAlertIDs: Set<String> = []
        @ObservationIgnored
        private var highlightedAlertID: String?
        @ObservationIgnored
        private var isObservingStore = false

        public init(
            store: AgentControlStore,
            notificationPreferences: MacNotificationPreferences = .init(),
            applicationPreferences: MacLocalPreferences = .init(),
            openControlCenter: @escaping @MainActor () -> Void = {},
            notificationPreferencesChanged: @escaping @MainActor (MacNotificationPreferences) -> Void = { _ in }
        ) {
            self.store = store
            self.notificationPreferences = notificationPreferences
            self.applicationPreferences = applicationPreferences
            isNotificationSoundEnabled = notificationPreferences.soundEnabled
            openControlCenterHandler = openControlCenter
            notificationPreferencesHandler = notificationPreferencesChanged
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

        public func start() {
            guard !isObservingStore else { return }
            isObservingStore = true
            let panel = panel ?? makePanel()
            self.panel = panel
            captureCurrentStoreState()
            mode = store.pendingDecisions.isEmpty || !shouldAutoPresentDecisions ? .compact : .decision
            store.isPanelExpanded = mode.showsDetails
            updateSize(animated: false)
            panel.orderFrontRegardless()
            observeStore()
        }

        public func stop() {
            collapseTask?.cancel()
            collapseTask = nil
            isObservingStore = false
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
            switch mode {
            case .expanded:
                setExpanded(false)
            case .decision:
                setMode(.expanded, animated: true, makeKey: true)
            case .compact, .activity:
                setMode(.expanded, animated: true, makeKey: true)
            }
        }

        public func show() {
            let panel = panel ?? makePanel()
            self.panel = panel
            setMode(.expanded, animated: false, makeKey: true)
        }

        public func hide() {
            setExpanded(false)
        }

        public func setExpanded(_ expanded: Bool) {
            let collapsedMode: NotchPanelMode = store.pendingDecisions.isEmpty ? .compact : .decision
            setMode(expanded ? .expanded : collapsedMode, animated: true, makeKey: expanded)
        }

        public func presentInbox() {
            setMode(.expanded, animated: true, makeKey: true)
        }

        public func openControlCenter() {
            openControlCenterHandler()
        }

        public func toggleNotificationSound() {
            notificationPreferences.soundEnabled.toggle()
            isNotificationSoundEnabled = notificationPreferences.soundEnabled
            notificationPreferencesHandler(notificationPreferences)
        }

        public func updateNotificationPreferences(_ value: MacNotificationPreferences) {
            notificationPreferences = value
            isNotificationSoundEnabled = value.soundEnabled
            if !value.enabled, store.pendingDecisions.isEmpty, mode != .expanded {
                setMode(.compact, animated: true)
            }
        }

        public func updateApplicationPreferences(_ value: MacLocalPreferences) {
            applicationPreferences = value
            if !value.showPanelForAttention, mode == .decision {
                setMode(.compact, animated: true)
            }
        }

        public func reposition() {
            guard panel != nil else { return }
            updateSize(animated: false)
        }

        private func makePanel() -> AgentControlPanel {
            let panel = AgentControlPanel(
                contentRect: CGRect(x: 0, y: 0, width: 280, height: 38),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isMovableByWindowBackground = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            // The expanded panel must become key so Escape reaches cancelOperation.
            // NSPanel's default "only if needed" behavior skips key status when the
            // current SwiftUI content has no text control, leaving Escape ineffective.
            panel.becomesKeyOnlyIfNeeded = false
            panel.cancelHandler = { [weak self] in self?.setExpanded(false) }
            panel.contentView = NSHostingView(rootView: FloatingPanelView(store: store, coordinator: self))
            return panel
        }

        private func updateSize(animated: Bool) {
            guard let panel else { return }
            let displays = NSScreen.screens.map(DisplayGeometry.init)
            guard let display = displays.first(where: { $0.notchFrame != nil })
                ?? displays.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? displays.first
            else { return }
            notchWidth = display.notchFrame?.width ?? 0
            notchHeight = display.notchFrame?.height ?? 0
            let size = panelSize(for: mode, notchWidth: notchWidth, notchHeight: notchHeight)
            let frame = FloatingPanelPlacement.frame(panelSize: size, display: display)
            if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
        }

        private func panelSize(for mode: NotchPanelMode, notchWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
            let compactWidth = max(430, notchWidth + 280)
            let headerHeight = max(40, notchHeight)
            let visibleRows = min(4, store.liveSessions().count + store.pendingDecisions.count)
            let expandedDetailHeight = min(440, max(250, 78 + CGFloat(visibleRows) * 96))
            return switch mode {
            case .compact:
                CGSize(width: compactWidth, height: headerHeight)
            case .activity:
                CGSize(width: max(520, compactWidth), height: headerHeight + 110)
            case .decision:
                CGSize(width: max(520, compactWidth), height: headerHeight + 260)
            case .expanded:
                CGSize(width: max(620, compactWidth), height: headerHeight + expandedDetailHeight)
            }
        }

        private func setMode(_ newMode: NotchPanelMode, animated: Bool, makeKey: Bool = false) {
            collapseTask?.cancel()
            collapseTask = nil
            mode = newMode
            store.isPanelExpanded = newMode.showsDetails
            let panel = panel ?? makePanel()
            self.panel = panel
            updateSize(animated: animated)
            panel.orderFrontRegardless()
            if makeKey {
                panel.makeKey()
            }
        }

        private func observeStore() {
            guard isObservingStore else { return }
            withObservationTracking {
                _ = store.pendingDecisions.map { "\($0.requestID.uuidString):\($0.revision)" }
                _ = store.sessions.map { "\($0.id.description):\($0.state.rawValue):\($0.snapshotRevision)" }
                _ = store.activeAlerts.map(\.id)
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self, self.isObservingStore else { return }
                    self.handleStoreMutation()
                    self.observeStore()
                }
            }
        }

        private func handleStoreMutation() {
            let decisionKeys = Set(store.pendingDecisions.map { "\($0.requestID.uuidString):\($0.revision)" })
            let hasNewDecision = !decisionKeys.subtracting(knownDecisionKeys).isEmpty
            let removedDecision = !knownDecisionKeys.subtracting(decisionKeys).isEmpty
            knownDecisionKeys = decisionKeys

            let fingerprints = Dictionary(uniqueKeysWithValues: store.sessions.map {
                ($0.id, "\($0.state.rawValue):\($0.snapshotRevision)")
            })
            let changedSession = store.sessions
                .filter { knownSessionFingerprints[$0.id] != fingerprints[$0.id] }
                .max { lhs, rhs in lhs.state.attentionPriority < rhs.state.attentionPriority }
            knownSessionFingerprints = fingerprints

            if mode == .expanded {
                updateSize(animated: true)
            }

            if !store.pendingDecisions.isEmpty {
                if shouldAutoPresentDecisions, mode != .expanded, hasNewDecision || mode == .decision {
                    setMode(.decision, animated: true)
                }
                return
            }

            if removedDecision {
                if applicationPreferences.closePanelAfterDecision {
                    highlightedSessionID = changedSession?.id
                    setMode(.activity, animated: true)
                    scheduleCompact(after: .seconds(2))
                } else if mode != .expanded {
                    setMode(.expanded, animated: true, makeKey: true)
                }
                return
            }

            let alertIDs = Set(store.activeAlerts.map(\.id))
            let newAlertID = alertIDs.subtracting(knownAlertIDs).first
            knownAlertIDs = alertIDs
            if let newAlertID, shouldPresentLongRunningAlerts {
                highlightedAlertID = newAlertID
                highlightedSessionID = nil
                setMode(.activity, animated: true)
                scheduleCompact(after: .seconds(5))
                return
            }

            if let changedSession, shouldPresent(state: changedSession.state) {
                highlightedSessionID = changedSession.id
                highlightedAlertID = nil
                setMode(.activity, animated: true)
                scheduleCompact(after: .seconds(5))
            }
        }

        private func captureCurrentStoreState() {
            knownDecisionKeys = Set(store.pendingDecisions.map { "\($0.requestID.uuidString):\($0.revision)" })
            knownSessionFingerprints = Dictionary(uniqueKeysWithValues: store.sessions.map {
                ($0.id, "\($0.state.rawValue):\($0.snapshotRevision)")
            })
            knownAlertIDs = Set(store.activeAlerts.map(\.id))
        }

        private func scheduleCompact(after duration: Duration) {
            guard applicationPreferences.autoHideActivity else { return }
            collapseTask?.cancel()
            collapseTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return
                }
                guard let self, mode == .activity, store.pendingDecisions.isEmpty else { return }
                setMode(.compact, animated: true)
            }
        }

        var highlightedSession: SessionListItem? {
            guard let highlightedSessionID else { return nil }
            return store.sessions.first(where: { $0.id == highlightedSessionID })
        }

        var highlightedAlert: SessionAlert? {
            guard let highlightedAlertID else { return nil }
            return store.activeAlerts.first(where: { $0.id == highlightedAlertID })
        }

        private var shouldAutoPresentDecisions: Bool {
            // Pending decisions remain visible in the compact status even when automatic
            // expansion is disabled. This switch controls presentation, not authority.
            applicationPreferences.showPanelForAttention
        }

        private var shouldPresentLongRunningAlerts: Bool {
            notificationPreferences.enabled && notificationPreferences.longRunningIdleNotificationsEnabled
        }

        private func shouldPresent(state: SessionState) -> Bool {
            guard notificationPreferences.enabled else { return false }
            return switch state {
            case .completed:
                notificationPreferences.completedNotificationsEnabled
            case .failed:
                notificationPreferences.failedNotificationsEnabled
            case .waitingApproval, .waitingInput:
                notificationPreferences.decisionNotificationsEnabled
            default:
                false
            }
        }
    }

    public final class AgentControlPanel: NSPanel {
        fileprivate var cancelHandler: (() -> Void)?

        override public var canBecomeKey: Bool {
            true
        }

        override public var canBecomeMain: Bool {
            false
        }

        override public func cancelOperation(_: Any?) {
            cancelHandler?()
        }
    }

#endif
