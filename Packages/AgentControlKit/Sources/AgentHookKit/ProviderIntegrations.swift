#if os(macOS)
    import AgentDomain
    import Foundation

    public enum HookProvider: String, Codable, CaseIterable, Sendable {
        case codex
        case claude
        case gemini
        case cursor
        case generic

        public var adapterID: AdapterID {
            AdapterID(rawValue)
        }
    }

    public struct ProviderVersion: Codable, Comparable, Hashable, Sendable, CustomStringConvertible {
        private struct ParsedComponents {
            let major: Int
            let minor: Int
            let patch: Int
            let suffix: String?
        }

        public let major: Int
        public let minor: Int
        public let patch: Int
        public let suffix: String?

        public init(major: Int, minor: Int, patch: Int, suffix: String? = nil) {
            self.major = major
            self.minor = minor
            self.patch = patch
            self.suffix = suffix
        }

        public init?(_ output: String) {
            let candidates = output.split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == "v" })
            let parsed = candidates.lazy.compactMap { token -> ParsedComponents? in
                guard token.first?.isNumber == true, token.contains(".") else { return nil }
                let pieces = token.split(separator: "-", maxSplits: 1)
                let numbers = pieces[0].split(separator: ".")
                guard numbers.count >= 2,
                      let major = Int(numbers[0]),
                      let minor = Int(numbers[1])
                else { return nil }
                let patch = numbers.count > 2 ? Int(numbers[2].prefix(while: \.isNumber)) ?? 0 : 0
                return ParsedComponents(
                    major: major,
                    minor: minor,
                    patch: patch,
                    suffix: pieces.count > 1 ? String(pieces[1]) : nil
                )
            }.first
            guard let parsed else { return nil }
            major = parsed.major
            minor = parsed.minor
            patch = parsed.patch
            suffix = parsed.suffix
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            [lhs.major, lhs.minor, lhs.patch].lexicographicallyPrecedes([rhs.major, rhs.minor, rhs.patch])
        }

        public var description: String {
            let base = "\(major).\(minor).\(patch)"
            return suffix.map { "\(base)-\($0)" } ?? base
        }
    }

    public struct ProviderCompatibilityPolicy: Sendable {
        public let knownMajorVersions: [HookProvider: Set<Int>]

        public init(knownMajorVersions: [HookProvider: Set<Int>] = [
            .codex: [0, 1],
            .claude: [1, 2],
            .gemini: [0, 1],
            .cursor: [1, 2, 3]
        ]) {
            self.knownMajorVersions = knownMajorVersions
        }

        public func capabilities(for provider: HookProvider, version: ProviderVersion?) -> CapabilityMatrix {
            guard provider != .generic,
                  let version,
                  knownMajorVersions[provider, default: []].contains(version.major)
            else { return CapabilityMatrix(supported: [.monitorSessions]) }
            switch provider {
            case .codex:
                return CapabilityMatrix(supported: [
                    .monitorSessions, .approveRequests, .denyRequests, .answerQuestions
                ])
            case .claude:
                return CapabilityMatrix(supported: [
                    .monitorSessions, .approveRequests, .denyRequests, .answerQuestions, .reviewPlans
                ])
            case .gemini:
                return CapabilityMatrix(supported: [.monitorSessions, .approveRequests, .denyRequests, .reviewPlans])
            case .cursor:
                return CapabilityMatrix(supported: [.monitorSessions, .approveRequests, .denyRequests])
            case .generic:
                return CapabilityMatrix(supported: [.monitorSessions])
            }
        }
    }

    public struct ProviderCommandResult: Sendable, Equatable {
        public let status: Int32
        public let standardOutput: String

        public init(status: Int32, standardOutput: String) {
            self.status = status
            self.standardOutput = standardOutput
        }
    }

    public protocol ProviderCommandRunning: Sendable {
        func run(executable: URL, arguments: [String]) async throws -> ProviderCommandResult
    }

    public struct FoundationProviderCommandRunner: ProviderCommandRunning {
        public init() {}

        public func run(executable: URL, arguments: [String]) async throws -> ProviderCommandResult {
            try await Task.detached {
                let process = Process()
                let output = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = output
                try process.run()
                process.waitUntilExit()
                return ProviderCommandResult(
                    status: process.terminationStatus,
                    standardOutput: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                )
            }.value
        }
    }

    public struct ProviderBinaryInfo: Sendable, Equatable {
        public let provider: HookProvider
        public let executableURL: URL
        public let version: ProviderVersion
        public let capabilities: CapabilityMatrix

        public init(provider: HookProvider, executableURL: URL, version: ProviderVersion, capabilities: CapabilityMatrix) {
            self.provider = provider
            self.executableURL = executableURL
            self.version = version
            self.capabilities = capabilities
        }
    }

    public struct ProviderBinaryDetector: Sendable {
        private let runner: any ProviderCommandRunning
        private let compatibility: ProviderCompatibilityPolicy
        private let isExecutable: @Sendable (String) -> Bool

        public init(
            runner: any ProviderCommandRunning = FoundationProviderCommandRunner(),
            compatibility: ProviderCompatibilityPolicy = ProviderCompatibilityPolicy(),
            isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
        ) {
            self.runner = runner
            self.compatibility = compatibility
            self.isExecutable = isExecutable
        }

        public func detect(provider: HookProvider, searchPaths: [URL]? = nil) async throws -> ProviderBinaryInfo {
            guard provider != .generic else { throw ProviderIntegrationError.unsupportedProvider }
            let candidates = searchPaths ?? Self.defaultCandidates(provider: provider)
            guard let executable = candidates.first(where: { isExecutable($0.path) }) else {
                throw ProviderIntegrationError.binaryNotFound(provider)
            }
            let result = try await runner.run(executable: executable, arguments: ["--version"])
            guard result.status == 0, let version = ProviderVersion(result.standardOutput) else {
                throw ProviderIntegrationError.versionDetectionFailed(provider)
            }
            return ProviderBinaryInfo(
                provider: provider,
                executableURL: executable,
                version: version,
                capabilities: compatibility.capabilities(for: provider, version: version)
            )
        }

        public static func defaultCandidates(
            provider: HookProvider,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> [URL] {
            let executable = provider.rawValue
            var candidates = environment["PATH", default: ""].split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent(executable)
            }
            candidates += ["/opt/homebrew/bin", "/usr/local/bin"].map {
                URL(fileURLWithPath: $0).appendingPathComponent(executable)
            }
            if provider == .cursor {
                candidates.append(URL(fileURLWithPath: "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"))
            }
            var seen = Set<String>()
            return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
        }
    }

    public enum ProviderIntegrationError: Error, Sendable, Equatable {
        case unsupportedProvider
        case binaryNotFound(HookProvider)
        case versionDetectionFailed(HookProvider)
    }

    public struct ProviderHookInstallation: Sendable {
        private struct EventDefinition: Sendable {
            let name: String
            let matcher: String?
            let timeout: Int

            init(_ name: String, matcher: String? = nil, timeout: Int) {
                self.name = name
                self.matcher = matcher
                self.timeout = timeout
            }
        }

        public let provider: HookProvider
        public let configURL: URL
        public let format: ManagedConfigFormat
        public let hooks: [HookCommandDefinition]

        public init(provider: HookProvider, configURL: URL, format: ManagedConfigFormat, hooks: [HookCommandDefinition]) {
            self.provider = provider
            self.configURL = configURL
            self.format = format
            self.hooks = hooks
        }

        public static func userLevel(
            provider: HookProvider,
            hookExecutableURL: URL,
            providerVersion: ProviderVersion? = nil,
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        ) throws -> ProviderHookInstallation {
            let configURL: URL
            let format: ManagedConfigFormat
            switch provider {
            case .codex:
                configURL = homeDirectory.appendingPathComponent(".codex/hooks.json")
                format = .json
            case .claude:
                configURL = homeDirectory.appendingPathComponent(".claude/settings.json")
                format = .json
            case .gemini:
                configURL = homeDirectory.appendingPathComponent(".gemini/settings.json")
                format = .json
            case .cursor:
                configURL = homeDirectory.appendingPathComponent(".cursor/hooks.json")
                format = .json
            case .generic:
                throw ProviderIntegrationError.unsupportedProvider
            }
            let versionPrefix = providerVersion.map { "AGENTCONTROL_PROVIDER_VERSION=" + shellQuoted($0.description) + " " } ?? ""
            let command = versionPrefix + shellQuoted(hookExecutableURL.path) + " provider-hook " + provider.rawValue
            return ProviderHookInstallation(
                provider: provider,
                configURL: configURL,
                format: format,
                hooks: definitions(provider: provider, command: command)
            )
        }

        private static func definitions(provider: HookProvider, command: String) -> [HookCommandDefinition] {
            let events = eventDefinitions(for: provider)
            return events.map { event in
                HookCommandDefinition(
                    event: event.name,
                    matcher: event.matcher,
                    command: command,
                    timeoutSeconds: event.timeout,
                    marker: "agentcontrol.\(provider.rawValue).\(event.name.lowercased())",
                    usesNameField: provider == .gemini,
                    layout: provider == .cursor ? .direct : .nested,
                    failClosed: provider == .cursor
                        && ["preToolUse", "beforeShellExecution", "beforeMCPExecution"].contains(event.name)
                )
            }
        }

        private static func eventDefinitions(for provider: HookProvider) -> [EventDefinition] {
            switch provider {
            case .codex: codexEvents
            case .claude: claudeEvents
            case .gemini: geminiEvents
            case .cursor: cursorEvents
            case .generic: []
            }
        }

        private static let codexEvents = [
            EventDefinition("SessionStart", timeout: 5), EventDefinition("UserPromptSubmit", timeout: 5),
            EventDefinition("PreToolUse", timeout: 70), EventDefinition("PermissionRequest", timeout: 70),
            EventDefinition("PostToolUse", timeout: 5), EventDefinition("PreCompact", timeout: 5),
            EventDefinition("PostCompact", timeout: 5), EventDefinition("SubagentStart", timeout: 5),
            EventDefinition("SubagentStop", timeout: 5), EventDefinition("Stop", timeout: 5)
        ]

        /// WorktreeCreate is a replacement hook that must return a directory,
        /// not an observer. FileChanged requires a literal path matcher. Installing
        /// either globally would change provider behavior instead of monitoring it.
        private static let claudeEvents = [
            EventDefinition("SessionStart", timeout: 5), EventDefinition("Setup", timeout: 5),
            EventDefinition("UserPromptSubmit", timeout: 5), EventDefinition("UserPromptExpansion", timeout: 5),
            EventDefinition("MessageDisplay", timeout: 5),
            EventDefinition("PreToolUse", timeout: 70), EventDefinition("PermissionRequest", timeout: 70),
            EventDefinition("PermissionDenied", timeout: 5), EventDefinition("PostToolUse", timeout: 5),
            EventDefinition("PostToolUseFailure", timeout: 5), EventDefinition("PostToolBatch", timeout: 5),
            EventDefinition("Notification", timeout: 5),
            EventDefinition("Elicitation", timeout: 60), EventDefinition("ElicitationResult", timeout: 5),
            EventDefinition("SubagentStart", timeout: 5), EventDefinition("SubagentStop", timeout: 5),
            EventDefinition("TaskCreated", timeout: 5), EventDefinition("PreCompact", timeout: 5),
            EventDefinition("PostCompact", timeout: 5), EventDefinition("ConfigChange", timeout: 5),
            EventDefinition("InstructionsLoaded", timeout: 5), EventDefinition("CwdChanged", timeout: 5),
            EventDefinition("WorktreeRemove", timeout: 5),
            EventDefinition("TeammateIdle", timeout: 5), EventDefinition("TaskCompleted", timeout: 5),
            EventDefinition("Stop", timeout: 5), EventDefinition("StopFailure", timeout: 5),
            EventDefinition("SessionEnd", timeout: 5)
        ]

        private static let geminiEvents = [
            EventDefinition("SessionStart", timeout: 1000), EventDefinition("BeforeAgent", timeout: 1000),
            EventDefinition("BeforeModel", timeout: 1000),
            EventDefinition("BeforeToolSelection", timeout: 1000),
            EventDefinition("BeforeTool", timeout: 60000), EventDefinition("AfterTool", timeout: 1000),
            EventDefinition("AfterModel", timeout: 1000), EventDefinition("Notification", timeout: 1000),
            EventDefinition("PreCompress", timeout: 1000), EventDefinition("AfterAgent", timeout: 1000),
            EventDefinition("SessionEnd", timeout: 1000)
        ]

        private static let cursorEvents = [
            EventDefinition("sessionStart", timeout: 5),
            EventDefinition("beforeSubmitPrompt", timeout: 5),
            EventDefinition("preToolUse", matcher: "Write|Delete|Task", timeout: 70),
            EventDefinition("postToolUse", timeout: 5),
            EventDefinition("postToolUseFailure", timeout: 5),
            EventDefinition("subagentStart", timeout: 5),
            EventDefinition("subagentStop", timeout: 5),
            EventDefinition("beforeShellExecution", timeout: 70),
            EventDefinition("beforeMCPExecution", timeout: 70),
            EventDefinition("afterShellExecution", timeout: 5),
            EventDefinition("afterMCPExecution", timeout: 5),
            EventDefinition("beforeReadFile", timeout: 5),
            EventDefinition("afterFileEdit", timeout: 5),
            EventDefinition("beforeTabFileRead", timeout: 5),
            EventDefinition("afterTabFileEdit", timeout: 5),
            EventDefinition("afterAgentResponse", timeout: 5),
            EventDefinition("afterAgentThought", timeout: 5),
            EventDefinition("preCompact", timeout: 5),
            EventDefinition("stop", timeout: 5),
            EventDefinition("sessionEnd", timeout: 5),
            EventDefinition("workspaceOpen", timeout: 5)
        ]

        private static func shellQuoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
#endif
