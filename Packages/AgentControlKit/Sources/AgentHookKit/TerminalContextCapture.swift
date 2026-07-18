#if os(macOS)
    import AgentDomain
    import AgentProtocol
    import Foundation

    public struct TerminalContextCapture: Sendable {
        public init() {}

        public func capture(
            fields: [String: JSONValue],
            environment: [String: String],
            correlationToken: String,
            now: Date
        ) -> TerminalContext? {
            guard let bundleID = explicitBundleID(fields: fields, environment: environment)
                ?? inferredBundleID(environment: environment)
            else { return nil }

            let workspaceURI = url(
                fields["workspace_uri"]?.stringValue
                    ?? fields["workspaceUri"]?.stringValue
                    ?? environment["AGENTCONTROL_WORKSPACE_URI"]
                    ?? environment["VSCODE_CWD"]
                    ?? fields["cwd"]?.stringValue
                    ?? environment["PWD"]
            )
            return TerminalContext(
                applicationBundleID: bundleID,
                processID: int32(fields["terminal_pid"]?.stringValue ?? environment["AGENTCONTROL_TERMINAL_PID"]),
                windowIdentifier: value("window", fields: fields, environment: environment),
                tabIdentifier: value("tab", fields: fields, environment: environment),
                paneIdentifier: value("pane", fields: fields, environment: environment),
                workspaceURI: workspaceURI,
                correlationToken: environment["AGENTCONTROL_CORRELATION_TOKEN"] ?? correlationToken,
                capturedAt: now
            )
        }

        private func explicitBundleID(fields: [String: JSONValue], environment: [String: String]) -> String? {
            let explicit = fields["terminal_bundle_id"]?.stringValue
                ?? fields["application_bundle_id"]?.stringValue
                ?? environment["AGENTCONTROL_TERMINAL_BUNDLE_ID"]
            if explicit != nil {
                return explicit
            }
            guard let inherited = environment["__CFBundleIdentifier"],
                  TerminalApplication(bundleIdentifier: inherited) != .unknown
            else { return nil }
            return inherited
        }

        private func inferredBundleID(environment: [String: String]) -> String? {
            switch environment["TERM_PROGRAM"]?.lowercased() {
            case "apple_terminal": "com.apple.Terminal"
            case "iterm.app", "iterm2": "com.googlecode.iterm2"
            case "ghostty": "com.mitchellh.ghostty"
            case "warpterminal", "warp": "dev.warp.Warp-Stable"
            case "wezterm": "com.github.wez.wezterm"
            case "vscode": environment["CURSOR_TRACE_ID"] == nil ? "com.microsoft.VSCode" : "com.todesktop.230313mzl4w4u92"
            case "cursor": "com.todesktop.230313mzl4w4u92"
            default: nil
            }
        }

        private func value(
            _ name: String,
            fields: [String: JSONValue],
            environment: [String: String]
        ) -> String? {
            fields["terminal_\(name)_id"]?.stringValue
                ?? fields["\(name)_id"]?.stringValue
                ?? environment["AGENTCONTROL_TERMINAL_\(name.uppercased())_ID"]
        }

        private func int32(_ value: String?) -> Int32? {
            value.flatMap(Int32.init)
        }

        private func url(_ value: String?) -> URL? {
            guard let value, !value.isEmpty else { return nil }
            if let parsed = URL(string: value), parsed.scheme != nil {
                return parsed
            }
            return URL(fileURLWithPath: value, isDirectory: true)
        }
    }
#endif
