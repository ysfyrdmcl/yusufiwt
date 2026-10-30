#if os(macOS)
    import AgentDomain
    import AppKit
    import ApplicationServices
    import Foundation

    public enum SessionStopAvailability: Sendable, Equatable {
        case available
        case contextMissing
        case contextStale
        case exactTargetUnavailable
        case permissionRequired
        case unsupportedTerminal
        case codexConnectionRequired
    }

    public enum SessionStopResult: Sendable, Equatable {
        case signalSent
        case unavailable(SessionStopAvailability)
        case failed
    }

    @MainActor
    public protocol TerminalStopping: AnyObject {
        func availability(for context: TerminalContext?, at date: Date) -> SessionStopAvailability
        func stop(context: TerminalContext?) async -> SessionStopResult
        func handleCallback(_ url: URL)
    }

    public extension TerminalStopping {
        func handleCallback(_: URL) {}
    }

    @MainActor
    public final class TerminalStopCoordinator: TerminalStopping {
        private let maximumContextAge: TimeInterval
        private let openExtensionURL: @MainActor (URL) -> Bool
        private var pendingStops: [String: (String, CheckedContinuation<SessionStopResult, Never>)] = [:]

        public init(
            maximumContextAge: TimeInterval = 30 * 60,
            openExtensionURL: @escaping @MainActor (URL) -> Bool = {
                NSWorkspace.shared.urlForApplication(toOpen: $0) != nil && NSWorkspace.shared.open($0)
            }
        ) {
            self.maximumContextAge = maximumContextAge
            self.openExtensionURL = openExtensionURL
        }

        public func availability(for context: TerminalContext?, at date: Date = Date()) -> SessionStopAvailability {
            guard let context else { return .contextMissing }
            guard date.timeIntervalSince(context.capturedAt) <= maximumContextAge else { return .contextStale }
            switch TerminalApplication(bundleIdentifier: context.applicationBundleID) {
            case .visualStudioCode, .cursor:
                return context.correlationToken.isEmpty ? .exactTargetUnavailable : .available
            case .wezTerm:
                return context.paneIdentifier == nil ? .exactTargetUnavailable : .available
            case .terminal, .iTerm2, .ghostty:
                guard context.paneIdentifier != nil || context.tabIdentifier != nil || context.windowIdentifier != nil else {
                    return .exactTargetUnavailable
                }
                guard AXIsProcessTrusted(),
                      AutomationPermissionController.status(
                          bundleID: context.applicationBundleID, askUserIfNeeded: false
                      ) == .authorized
                else { return .permissionRequired }
                return .available
            case .warp, .unknown:
                return .unsupportedTerminal
            }
        }

        public func stop(context: TerminalContext?) async -> SessionStopResult {
            guard availability(for: context, at: Date()) == .available, let context else {
                return .unavailable(availability(for: context, at: Date()))
            }
            let application = TerminalApplication(bundleIdentifier: context.applicationBundleID)
            switch application {
            case .visualStudioCode, .cursor:
                return await stopInExtension(application: application, token: context.correlationToken)
            case .wezTerm:
                guard let paneID = context.paneIdentifier,
                      let applicationURL = NSWorkspace.shared.urlForApplication(
                          withBundleIdentifier: "com.github.wez.wezterm"
                      )
                else { return .failed }
                let executable = applicationURL.appendingPathComponent("Contents/MacOS/wezterm")
                return await Self.run(
                    executable,
                    arguments: ["cli", "send-text", "--pane-id", paneID, "--no-paste", "\u{3}"]
                ) ? .signalSent : .failed
            case .terminal, .iTerm2, .ghostty:
                guard let target = context.paneIdentifier ?? context.tabIdentifier ?? context.windowIdentifier else {
                    return .unavailable(.exactTargetUnavailable)
                }
                return await Self.run(
                    URL(fileURLWithPath: "/usr/bin/osascript"),
                    arguments: ["-e", interruptScript(for: application), target]
                ) ? .signalSent : .failed
            case .warp, .unknown:
                return .unavailable(.unsupportedTerminal)
            }
        }

        public func handleCallback(_ url: URL) {
            guard ["agentcontrol", "yusufiwt"].contains(url.scheme?.lowercased() ?? ""),
                  url.host == "stop-result",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let request = components.queryItems?.first(where: { $0.name == "request" })?.value,
                  let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
                  let pending = pendingStops[request], pending.0 == token else { return }
            pendingStops.removeValue(forKey: request)
            let sent = components.queryItems?.first(where: { $0.name == "sent" })?.value == "true"
            pending.1.resume(returning: sent ? .signalSent : .unavailable(.exactTargetUnavailable))
        }

        private func stopInExtension(application: TerminalApplication, token: String) async -> SessionStopResult {
            let request = UUID().uuidString
            guard let url = extensionURL(application: application, token: token, request: request) else { return .failed }
            return await withCheckedContinuation { continuation in
                pendingStops[request] = (token, continuation)
                guard openExtensionURL(url) else {
                    pendingStops.removeValue(forKey: request)?.1.resume(returning: .failed)
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    self?.pendingStops.removeValue(forKey: request)?.1.resume(returning: .failed)
                }
            }
        }

        private func extensionURL(application: TerminalApplication, token: String, request: String) -> URL? {
            var components = URLComponents()
            components.scheme = application == .cursor ? "cursor" : "vscode"
            components.host = "yusuf.agentcontrol-navigation"
            components.path = "/interrupt"
            components.queryItems = [URLQueryItem(name: "token", value: token), URLQueryItem(name: "request", value: request)]
            return components.url
        }

        // The inline AppleScripts are kept together so their target-selection behavior stays auditable.
        // swiftlint:disable:next function_body_length
        private func interruptScript(for application: TerminalApplication) -> String {
            let focusScript = switch application {
            case .terminal:
                """
                tell application id "com.apple.Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if (tty of t as text) is targetID then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        set foundTarget to true
                        exit repeat
                      end if
                    end repeat
                    if foundTarget then exit repeat
                  end repeat
                end tell
                """
            case .iTerm2:
                """
                tell application id "com.googlecode.iterm2"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if (unique ID of s as text) is targetID then
                          select t
                          select s
                          activate
                          set foundTarget to true
                          exit repeat
                        end if
                      end repeat
                      if foundTarget then exit repeat
                    end repeat
                    if foundTarget then exit repeat
                  end repeat
                end tell
                """
            case .ghostty:
                """
                tell application id "com.mitchellh.ghostty"
                  repeat with t in terminals
                    if (id of t as text) is targetID then
                      focus t
                      activate
                      set foundTarget to true
                      exit repeat
                    end if
                  end repeat
                end tell
                """
            default: ""
            }
            return """
            on run argv
              set targetID to item 1 of argv
              set foundTarget to false
              \(focusScript)
              if not foundTarget then error "target not found"
              delay 0.05
              tell application "System Events" to keystroke "c" using control down
            end run
            """
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
#endif
