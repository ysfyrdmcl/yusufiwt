#if os(macOS)
    import AgentDomain
    import AppKit
    import ApplicationServices
    import Foundation

    public struct NavigationPermissionSnapshot: Sendable, Equatable {
        public let accessibilityEnabled: Bool
        public let automationAuthorizedBundleIDs: Set<String>

        public init(accessibilityEnabled: Bool, automationAuthorizedBundleIDs: Set<String> = []) {
            self.accessibilityEnabled = accessibilityEnabled
            self.automationAuthorizedBundleIDs = automationAuthorizedBundleIDs
        }
    }

    public enum NavigationAttempt: Sendable, Equatable {
        case extensionURL(URL, NavigationResultLevel)
        case wezTermCLI(paneID: String)
        case appleScript(bundleID: String, source: String, arguments: [String], level: NavigationResultLevel)
        case accessibility(bundleID: String, identifier: String, level: NavigationResultLevel)
        case activate(bundleID: String)
        case projectFolder(URL)

        var level: NavigationResultLevel {
            switch self {
            case let .extensionURL(_, level), let .appleScript(_, _, _, level), let .accessibility(_, _, level): level
            case .wezTermCLI: .exactPane
            case .activate: .application
            case .projectFolder: .projectFolder
            }
        }

        var mechanism: String {
            switch self {
            case .extensionURL: "extension-url"
            case .wezTermCLI: "wezterm-cli"
            case .appleScript: "apple-script"
            case .accessibility: "accessibility"
            case .activate: "application-activation"
            case .projectFolder: "project-folder"
            }
        }
    }

    public struct TerminalNavigationPlan: Sendable, Equatable {
        public let bundleID: String?
        public let attempts: [NavigationAttempt]
        public let fallbackReason: NavigationFailureReason?

        public init(bundleID: String?, attempts: [NavigationAttempt], fallbackReason: NavigationFailureReason?) {
            self.bundleID = bundleID
            self.attempts = attempts
            self.fallbackReason = fallbackReason
        }
    }

    public struct TerminalNavigationPlanner: Sendable {
        public init() {}

        // swiftlint:disable:next function_body_length
        public func plan(
            context: TerminalContext?,
            projectURL: URL?,
            permissions: NavigationPermissionSnapshot
        ) -> TerminalNavigationPlan {
            guard let context else {
                return TerminalNavigationPlan(
                    bundleID: nil,
                    attempts: projectURL.map { [.projectFolder($0)] } ?? [],
                    fallbackReason: .contextMissing
                )
            }
            let application = TerminalApplication(bundleIdentifier: context.applicationBundleID)
            var attempts: [NavigationAttempt] = []
            var missingPermission: NavigationFailureReason?

            if let url = extensionURL(application: application, context: context) {
                attempts.append(.extensionURL(url, .exactPane))
            }
            if application == .warp, let url = warpURL(context.workspaceURI ?? projectURL) {
                attempts.append(.extensionURL(url, .projectFolder))
            }
            if application == .wezTerm, let paneID = context.paneIdentifier, safeIdentifier(paneID) {
                attempts.append(.wezTermCLI(paneID: paneID))
            }
            if [.terminal, .iTerm2, .ghostty].contains(application), let target = exactTarget(context) {
                if permissions.automationAuthorizedBundleIDs.contains(context.applicationBundleID) {
                    attempts.append(.appleScript(
                        bundleID: context.applicationBundleID,
                        source: script(for: application),
                        arguments: [target],
                        level: context.paneIdentifier == nil ? .window : .exactPane
                    ))
                } else {
                    missingPermission = .automationNotGranted
                }
            }
            if let target = exactTarget(context) {
                if permissions.accessibilityEnabled {
                    attempts.append(.accessibility(
                        bundleID: context.applicationBundleID,
                        identifier: target,
                        level: context.paneIdentifier == nil ? .window : .exactPane
                    ))
                } else if missingPermission == nil {
                    missingPermission = .accessibilityNotGranted
                }
            }
            attempts.append(.activate(bundleID: context.applicationBundleID))
            if let projectURL {
                attempts.append(.projectFolder(projectURL))
            }
            return TerminalNavigationPlan(
                bundleID: context.applicationBundleID,
                attempts: attempts,
                fallbackReason: missingPermission ?? (exactTarget(context) == nil ? .exactTargetUnavailable : nil)
            )
        }

        private func exactTarget(_ context: TerminalContext) -> String? {
            context.paneIdentifier ?? context.tabIdentifier ?? context.windowIdentifier
        }

        private func extensionURL(application: TerminalApplication, context: TerminalContext) -> URL? {
            let scheme: String
            switch application {
            case .visualStudioCode: scheme = "vscode"
            case .cursor: scheme = "cursor"
            default: return nil
            }
            var components = URLComponents()
            components.scheme = scheme
            components.host = "yusuf.agentcontrol-navigation"
            components.path = "/reveal"
            components.queryItems = [
                URLQueryItem(name: "token", value: context.correlationToken),
                context.workspaceURI.map { URLQueryItem(name: "workspace", value: $0.absoluteString) }
            ].compactMap(\.self)
            return components.url
        }

        private func warpURL(_ workspaceURL: URL?) -> URL? {
            guard let workspaceURL, workspaceURL.isFileURL else { return nil }
            var components = URLComponents()
            components.scheme = "warp"
            components.host = "action"
            components.path = "/new_tab"
            components.queryItems = [URLQueryItem(name: "path", value: workspaceURL.path)]
            return components.url
        }

        private func safeIdentifier(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 512 && !value.contains("\0")
        }

        // The scripts stay next to their adapter so their permission and argument boundary is auditable.
        // swiftlint:disable:next function_body_length
        private func script(for application: TerminalApplication) -> String {
            switch application {
            case .terminal:
                """
                on run argv
                  set targetID to item 1 of argv
                  tell application id "com.apple.Terminal"
                    repeat with w in windows
                      repeat with t in tabs of w
                        if (tty of t as text) is targetID then
                          set selected tab of w to t
                          set index of w to 1
                          activate
                          return
                        end if
                      end repeat
                    end repeat
                    error "target not found"
                  end tell
                end run
                """
            case .iTerm2:
                """
                on run argv
                  set targetID to item 1 of argv
                  tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                      repeat with t in tabs of w
                        repeat with s in sessions of t
                          if (unique ID of s as text) is targetID then
                            select t
                            select s
                            activate
                            return
                          end if
                        end repeat
                      end repeat
                    end repeat
                    error "target not found"
                  end tell
                end run
                """
            case .ghostty:
                """
                on run argv
                  set targetID to item 1 of argv
                  tell application id "com.mitchellh.ghostty"
                    repeat with t in terminals
                      if (id of t as text) is targetID then
                        focus t
                        activate
                        return
                      end if
                    end repeat
                    error "target not found"
                  end tell
                end run
                """
            default: "error \"unsupported application\""
            }
        }
    }

    @MainActor
    public protocol TerminalNavigating: AnyObject {
        func navigate(context: TerminalContext?, projectURL: URL?) async -> NavigationResult
        func navigateExact(context: TerminalContext?) async -> NavigationResult
    }

    public extension TerminalNavigating {
        func navigateExact(context: TerminalContext?) async -> NavigationResult {
            await navigate(context: context, projectURL: nil)
        }
    }

    @MainActor
    public final class TerminalNavigationCoordinator: TerminalNavigating {
        private let planner: TerminalNavigationPlanner
        private let preferences: NavigationPreferences

        public init(
            planner: TerminalNavigationPlanner = TerminalNavigationPlanner(),
            preferences: NavigationPreferences = NavigationPreferences()
        ) {
            self.planner = planner
            self.preferences = preferences
        }

        public func navigate(context: TerminalContext?, projectURL: URL?) async -> NavigationResult {
            await navigate(context: context, projectURL: projectURL, exactOnly: false)
        }

        public func navigateExact(context: TerminalContext?) async -> NavigationResult {
            await navigate(context: context, projectURL: nil, exactOnly: true)
        }

        private func navigate(
            context: TerminalContext?,
            projectURL: URL?,
            exactOnly: Bool
        ) async -> NavigationResult {
            let automation = Set([TerminalApplication.terminal, .iTerm2, .ghostty].flatMap(\.bundleIdentifiers).filter {
                AutomationPermissionController.status(bundleID: $0, askUserIfNeeded: false) == .authorized
            })
            let permissions = NavigationPermissionSnapshot(
                accessibilityEnabled: preferences.accessibilityNavigationEnabled && AXIsProcessTrusted(),
                automationAuthorizedBundleIDs: automation
            )
            let plan = planner.plan(context: context, projectURL: projectURL, permissions: permissions)
            for attempt in plan.attempts {
                guard !exactOnly || attempt.level == .exactPane else { continue }
                guard await execute(attempt) else { continue }
                if case .extensionURL = attempt, attempt.level == .exactPane {
                    return NavigationResult(
                        level: .application,
                        applicationBundleID: plan.bundleID,
                        mechanism: "extension-dispatched",
                        reason: .exactTargetUnavailable
                    )
                }
                return NavigationResult(
                    level: attempt.level,
                    applicationBundleID: plan.bundleID,
                    mechanism: attempt.mechanism,
                    reason: attempt.level < .window ? plan.fallbackReason : nil
                )
            }
            return NavigationResult(
                level: .unsupported,
                applicationBundleID: plan.bundleID,
                mechanism: "none",
                reason: plan.attempts.isEmpty ? plan.fallbackReason ?? .contextMissing
                    : exactOnly ? .exactTargetUnavailable : .openFailed
            )
        }

        private func execute(_ attempt: NavigationAttempt) async -> Bool {
            switch attempt {
            case let .extensionURL(url, _):
                guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return false }
                return NSWorkspace.shared.open(url)
            case let .wezTermCLI(paneID):
                guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.github.wez.wezterm") else {
                    return false
                }
                let executable = applicationURL.appendingPathComponent("Contents/MacOS/wezterm")
                return await Self.run(executable, arguments: ["cli", "activate-pane", "--pane-id", paneID])
            case let .appleScript(_, source, arguments, _):
                return await Self.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", source] + arguments)
            case let .accessibility(bundleID, identifier, _):
                return AccessibilityNavigator.raise(bundleID: bundleID, identifier: identifier)
            case let .activate(bundleID):
                if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    return running.activate(options: [.activateAllWindows])
                }
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
                return await withCheckedContinuation { continuation in
                    NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                        continuation.resume(returning: error == nil)
                    }
                }
            case let .projectFolder(url):
                return NSWorkspace.shared.open(url)
            }
        }

        private nonisolated static func run(_ executable: URL, arguments: [String]) async -> Bool {
            await Task.detached {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus == 0
                } catch {
                    return false
                }
            }.value
        }
    }

    public struct NavigationPreferences {
        private let defaults: UserDefaults
        private let key = "navigation.accessibility.enabled"

        public init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        public var accessibilityNavigationEnabled: Bool {
            defaults.bool(forKey: key)
        }

        public func setAccessibilityNavigationEnabled(_ enabled: Bool) {
            defaults.set(enabled, forKey: key)
        }
    }

    public enum AutomationPermissionStatus: String, Sendable {
        case authorized
        case denied
        case notDetermined
        case applicationUnavailable
    }

    public enum AutomationPermissionController {
        public static func status(bundleID: String, askUserIfNeeded: Bool) -> AutomationPermissionStatus {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
                return .applicationUnavailable
            }
            let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            guard let address = descriptor.aeDesc else { return .applicationUnavailable }
            let result = AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, askUserIfNeeded)
            switch result {
            case noErr: return .authorized
            case OSStatus(errAEEventNotPermitted): return askUserIfNeeded ? .denied : .notDetermined
            default: return .denied
            }
        }
    }

    private enum AccessibilityNavigator {
        static func raise(bundleID: String, identifier: String) -> Bool {
            guard AXIsProcessTrusted(),
                  let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            else { return false }
            let root = AXUIElementCreateApplication(application.processIdentifier)
            guard let target = find(identifier: identifier, in: root, remainingDepth: 8) else { return false }
            return AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
                || AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
        }

        private static func find(identifier: String, in element: AXUIElement, remainingDepth: Int) -> AXUIElement? {
            guard remainingDepth > 0 else { return nil }
            for attribute in [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                guard status == .success, let text = value as? String else { continue }
                if text == identifier {
                    return element
                }
            }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
                  let children = value as? [AXUIElement]
            else { return nil }
            for child in children {
                if let match = find(identifier: identifier, in: child, remainingDepth: remainingDepth - 1) {
                    return match
                }
            }
            return nil
        }
    }
#endif
