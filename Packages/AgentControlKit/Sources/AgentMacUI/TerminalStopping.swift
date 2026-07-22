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
    }

    @MainActor
    public final class TerminalStopCoordinator: TerminalStopping {
        private let maximumContextAge: TimeInterval

        public init(maximumContextAge: TimeInterval = 30 * 60) {
            self.maximumContextAge = maximumContextAge
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
                guard let url = extensionURL(application: application, token: context.correlationToken),
                      NSWorkspace.shared.urlForApplication(toOpen: url) != nil,
                      NSWorkspace.shared.open(url)
                else { return .failed }
                return .signalSent
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

        private func extensionURL(application: TerminalApplication, token: String) -> URL? {
            var components = URLComponents()
            components.scheme = application == .cursor ? "cursor" : "vscode"
            components.host = "yusuf.agentcontrol-navigation"
            components.path = "/interrupt"
            components.queryItems = [URLQueryItem(name: "token", value: token)]
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
