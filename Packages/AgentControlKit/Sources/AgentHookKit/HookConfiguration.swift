#if os(macOS)
    import AgentLocalIPC
    import Foundation

    public struct HookConfiguration: Sendable {
        public let socketURL: URL
        public let spoolDirectory: URL
        public let decisionTimeoutMilliseconds: Int32
        public let statusTimeoutMilliseconds: Int32
        public let maximumInputBytes: Int
        public let nativeFallbackEnabled: Bool

        public init(
            socketURL: URL,
            spoolDirectory: URL,
            decisionTimeoutMilliseconds: Int32 = 65000,
            statusTimeoutMilliseconds: Int32 = 250,
            maximumInputBytes: Int = 1_048_576,
            nativeFallbackEnabled: Bool = true
        ) {
            self.socketURL = socketURL
            self.spoolDirectory = spoolDirectory
            self.decisionTimeoutMilliseconds = decisionTimeoutMilliseconds
            self.statusTimeoutMilliseconds = statusTimeoutMilliseconds
            self.maximumInputBytes = maximumInputBytes
            self.nativeFallbackEnabled = nativeFallbackEnabled
        }

        public static func environment(
            _ environment: [String: String] = ProcessInfo.processInfo.environment
        ) throws -> HookConfiguration {
            let defaults = try AgentControlPaths.userDefault()
            let socketURL = environment["AGENTCONTROL_SOCKET"].map(URL.init(fileURLWithPath:)) ?? defaults.socketURL
            let spoolDirectory = environment["AGENTCONTROL_SPOOL_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? defaults.spoolDirectory
            return HookConfiguration(
                socketURL: socketURL,
                spoolDirectory: spoolDirectory,
                decisionTimeoutMilliseconds: Self.int32(environment["AGENTCONTROL_HOOK_TIMEOUT_MS"], default: 65000),
                statusTimeoutMilliseconds: Self.int32(environment["AGENTCONTROL_STATUS_TIMEOUT_MS"], default: 250),
                maximumInputBytes: Self.int(environment["AGENTCONTROL_MAX_INPUT_BYTES"], default: 1_048_576),
                nativeFallbackEnabled: environment["AGENTCONTROL_NATIVE_FALLBACK"] != "0"
            )
        }

        private static func int32(_ value: String?, default fallback: Int32) -> Int32 {
            guard let value, let parsed = Int32(value), parsed > 0 else { return fallback }
            return parsed
        }

        private static func int(_ value: String?, default fallback: Int) -> Int {
            guard let value, let parsed = Int(value), parsed > 0 else { return fallback }
            return min(parsed, LocalIPCContract.maximumFrameSize)
        }
    }
#endif
