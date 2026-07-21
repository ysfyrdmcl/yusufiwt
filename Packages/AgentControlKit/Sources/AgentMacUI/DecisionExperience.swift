#if os(macOS)
    // Decision presentation and its fail-neutral command parser are reviewed together.
    // swiftlint:disable file_length
    import AgentDomain
    import AgentLocalIPC
    import AgentPersistence
    import AppKit
    import Foundation

    public enum DecisionAvailability: Sendable, Equatable {
        case actionable
        case expired
        case secretRequiresTerminal

        public static func evaluate(_ decision: PendingHookDecision, now: Date = Date()) -> DecisionAvailability {
            if let expiry = decision.expiresAt, expiry <= now {
                return .expired
            }
            let isSecretQuestion = decision.question?.kind == .secret || decision.privacyClass == .secret
            if decision.kind == .question, isSecretQuestion {
                return .secretRequiresTerminal
            }
            return .actionable
        }
    }

    public enum LocalAcknowledgmentStatus: Sendable, Equatable {
        case sending
        case sentToProvider
        case automaticallySentToProvider
        case providerAcknowledged
        case applied
        case deniedApplied
        case expired
        case cancelled
        case superseded
        case rejected
        case failed

        public var isApplied: Bool {
            self == .applied || self == .deniedApplied
        }
    }

    public struct DecisionPresentation: Sendable, Equatable {
        public let title: String
        public let provider: String?
        public let project: String?
        public let detailLines: [String]
        public let expectedEffects: [String]
        public let risk: RiskAssessment?
        public let riskReasons: [String]
        public let redactedCommand: String?
        public let approvalScope: String?

        public init(decision: PendingHookDecision) {
            risk = decision.approval?.risk
            provider = decision.provider
            project = decision.projectName
            switch decision.kind {
            case .approval:
                if case let .executeCommand(command)? = decision.approval?.action {
                    let commandPresentation = SafeCommandPresentation(command: command)
                    title = commandPresentation.title ?? decision.prompt
                    detailLines = commandPresentation.detailLines
                    expectedEffects = commandPresentation.expectedEffects
                    riskReasons = Array(Set(
                        (decision.approval?.risk.reasons ?? []) + commandPresentation.riskReasons
                    )).sorted()
                    redactedCommand = commandPresentation.redactedCommand
                } else {
                    title = RedactedDiagnosticExporter.sanitize(decision.prompt)
                    detailLines = Self.lines(for: decision.approval?.action)
                    expectedEffects = Self.effects(for: decision.approval?.action)
                    riskReasons = decision.approval?.risk.reasons ?? []
                    redactedCommand = nil
                }
                approvalScope = String(localized: "decision.scope.once", defaultValue: "Once")
            case .question:
                title = RedactedDiagnosticExporter.sanitize(decision.question?.prompt ?? decision.prompt)
                detailLines = []
                expectedEffects = []
                riskReasons = []
                redactedCommand = nil
                approvalScope = nil
            case .plan:
                title = RedactedDiagnosticExporter.sanitize(decision.planTitle ?? decision.prompt)
                detailLines = decision.prompt == title
                    ? []
                    : [RedactedDiagnosticExporter.sanitize(decision.prompt)]
                expectedEffects = [String(
                    localized: "decision.effect.planImplementation",
                    defaultValue: "The provider may begin implementing the reviewed plan after acknowledgment."
                )]
                riskReasons = []
                redactedCommand = nil
                approvalScope = String(localized: "decision.scope.once", defaultValue: "Once")
            }
        }

        // Exhaustive action formatting is kept together so no case loses privacy sanitization.
        // swiftlint:disable:next function_body_length
        private static func lines(for action: AgentAction?) -> [String] {
            guard let action else { return [] }
            switch action {
            case let .executeCommand(command):
                var lines = [Self.format(
                    "decision.presentation.executable",
                    defaultValue: "Executable: %@",
                    command.executable.path
                )]
                if !command.arguments.isEmpty {
                    lines.append(Self.format(
                        "decision.presentation.arguments",
                        defaultValue: "Arguments: %@",
                        command.arguments.joined(separator: " ")
                    ))
                }
                if let directory = command.workingDirectory {
                    lines.append(Self.format(
                        "decision.presentation.workingDirectory",
                        defaultValue: "Working directory: %@",
                        directory.path
                    ))
                }
                if !command.environmentVariableNames.isEmpty {
                    lines.append(Self.format(
                        "decision.presentation.environmentKeys",
                        defaultValue: "Environment keys: %@",
                        command.environmentVariableNames.sorted().joined(separator: ", ")
                    ))
                }
                return lines
            case let .modifyFiles(summary):
                return [Self.format(
                    "decision.presentation.fileOperation",
                    defaultValue: "%1$@ — %2$@",
                    summary.operation.rawValue.capitalized,
                    summary.paths.map(\.path).joined(separator: ", ")
                )]
            case let .accessNetwork(summary):
                let endpoint = summary.port.map { "\(summary.host):\($0)" } ?? summary.host
                return [Self.format(
                    "decision.presentation.network",
                    defaultValue: "%1$@ — %2$@",
                    summary.usesTLS ? "TLS" : String(localized: "decision.presentation.networkLabel", defaultValue: "Network"),
                    endpoint
                )]
            case let .useTool(summary):
                return [
                    Self.format("decision.presentation.tool", defaultValue: "Tool: %@", summary.name),
                    summary.isReadOnly
                        ? String(localized: "decision.presentation.readOnly", defaultValue: "Read-only")
                        : String(localized: "decision.presentation.mayModify", defaultValue: "May modify data")
                ]
            case let .changePlan(summary):
                return [summary.title]
            case let .custom(summary):
                return [summary.summary]
            }
        }

        private static func effects(for action: AgentAction?) -> [String] {
            switch action {
            case .executeCommand:
                [String(
                    localized: "decision.effect.localCommand",
                    defaultValue: "Runs a local command; the executable or its scripts may create or modify files."
                )]
            case .modifyFiles:
                [String(localized: "decision.effect.modifyFiles", defaultValue: "Creates or changes local project files.")]
            case .accessNetwork:
                [String(localized: "decision.effect.network", defaultValue: "Connects to a network endpoint.")]
            case let .useTool(summary):
                [summary.isReadOnly
                    ? String(localized: "decision.effect.read", defaultValue: "Reads local data.")
                    : String(localized: "decision.effect.mayChange", defaultValue: "May change local data.")]
            case .changePlan:
                [String(localized: "decision.effect.changePlan", defaultValue: "Changes the agent's implementation plan.")]
            case .custom:
                [String(localized: "decision.effect.custom", defaultValue: "Runs the provider-described action.")]
            case nil:
                []
            }
        }

        private static func format(
            _ key: StaticString,
            defaultValue: String.LocalizationValue,
            _ arguments: CVarArg...
        ) -> String {
            String(
                format: String(localized: key, defaultValue: defaultValue),
                locale: Locale.current,
                arguments: arguments
            )
        }
    }

    private struct SafeCommandPresentation {
        let title: String?
        let detailLines: [String]
        let expectedEffects: [String]
        let riskReasons: [String]
        let redactedCommand: String

        init(command: ParsedCommand) {
            let raw = Self.rawCommand(command)
            redactedCommand = RedactedDiagnosticExporter.sanitize(raw)
            let parsed = SafeShellTokenizer.tokenize(redactedCommand)
            let tokens = parsed.tokens
            let executable = tokens.first ?? command.executable.lastPathComponent
            let arguments = Array(tokens.dropFirst())
            let details = Self.details(
                executable: executable,
                arguments: arguments,
                workingDirectory: command.workingDirectory
            )
            title = Self.title(executable: executable, details: details)
            detailLines = details.lines
            expectedEffects = Self.effects(executable: executable, details: details)
            riskReasons = Self.riskReasons(
                executable: executable,
                arguments: arguments,
                operators: parsed.operators,
                workingDirectory: command.workingDirectory
            )
        }

        private struct Details {
            var project: String?
            var scheme: String?
            var configuration: String?
            var sdk: String?
            var destination: String?
            var derivedDataPath: String?
            var codeSigningDisabled = false
            var lines: [String]
        }

        private static func rawCommand(_ command: ParsedCommand) -> String {
            let executable = command.executable.lastPathComponent.lowercased()
            if ["sh", "bash", "zsh"].contains(executable) {
                let commandIndex = command.arguments.firstIndex(where: { ["-c", "-lc"].contains($0) })
                if let commandIndex, command.arguments.indices.contains(commandIndex + 1) {
                    return command.arguments[commandIndex + 1]
                }
            }
            return ([command.executable.path] + command.arguments).joined(separator: " ")
        }

        // Parsing every supported xcodebuild display option in one pass avoids partial summaries.
        // swiftlint:disable:next function_body_length
        private static func details(
            executable: String,
            arguments: [String],
            workingDirectory: URL?
        ) -> Details {
            var values: [String: String] = [:]
            var index = 0
            let valuedOptions = ["-project", "-scheme", "-configuration", "-sdk", "-destination", "-derivedDataPath"]
            while index < arguments.count {
                let argument = arguments[index]
                if valuedOptions.contains(argument), arguments.indices.contains(index + 1) {
                    values[argument] = arguments[index + 1]
                    index += 2
                    continue
                }
                index += 1
            }
            let signingDisabled = arguments.contains("CODE_SIGNING_ALLOWED=NO")
                || arguments.contains("CODE_SIGNING_REQUIRED=NO")
            var lines = [Self.format(
                "decision.presentation.tool",
                defaultValue: "Tool: %@",
                URL(fileURLWithPath: executable).lastPathComponent
            )]
            if executable.hasPrefix("/") {
                lines.append(Self.format("decision.presentation.executable", defaultValue: "Executable: %@", executable))
            }
            if let project = values["-project"] {
                lines.append(Self.format("decision.presentation.project", defaultValue: "Project: %@", project))
            }
            if let scheme = values["-scheme"] {
                lines.append(Self.format("decision.presentation.scheme", defaultValue: "Scheme: %@", scheme))
            }
            if let configuration = values["-configuration"] {
                lines.append(Self.format(
                    "decision.presentation.configuration",
                    defaultValue: "Configuration: %@",
                    configuration
                ))
            }
            if values["-sdk"] != nil || values["-destination"] != nil {
                lines.append(Self.format(
                    "decision.presentation.sdkDestination",
                    defaultValue: "SDK / destination: %1$@ / %2$@",
                    values["-sdk"] ?? "—",
                    values["-destination"] ?? "—"
                ))
            }
            if signingDisabled {
                lines.append(String(
                    localized: "decision.presentation.codeSigningDisabled",
                    defaultValue: "Code signing: disabled"
                ))
            }
            if let path = values["-derivedDataPath"] {
                lines.append(Self.format(
                    "decision.presentation.buildOutput",
                    defaultValue: "Build output: %@",
                    displayPath(path, workingDirectory: workingDirectory)
                ))
            }
            if let workingDirectory {
                lines.append(Self.format(
                    "decision.presentation.workingDirectory",
                    defaultValue: "Working directory: %@",
                    workingDirectory.path
                ))
            }
            return Details(
                project: values["-project"],
                scheme: values["-scheme"],
                configuration: values["-configuration"],
                sdk: values["-sdk"],
                destination: values["-destination"],
                derivedDataPath: values["-derivedDataPath"],
                codeSigningDisabled: signingDisabled,
                lines: lines
            )
        }

        private static func title(executable: String, details: Details) -> String? {
            guard URL(fileURLWithPath: executable).lastPathComponent == "xcodebuild",
                  let scheme = details.scheme
            else { return nil }
            if let configuration = details.configuration {
                return Self.format(
                    "decision.title.xcodebuild.configuration",
                    defaultValue: "Wants to build the %1$@ scheme in %2$@",
                    scheme,
                    configuration
                )
            }
            return Self.format(
                "decision.title.xcodebuild",
                defaultValue: "Wants to build the %@ scheme",
                scheme
            )
        }

        private static func effects(executable: String, details: Details) -> [String] {
            if URL(fileURLWithPath: executable).lastPathComponent == "xcodebuild" {
                var effects = [String(
                    localized: "decision.effect.xcodebuild",
                    defaultValue: "Creates local build artifacts; project build scripts may also run."
                )]
                if let output = details.derivedDataPath {
                    effects.append(Self.format(
                        "decision.effect.derivedData",
                        defaultValue: "Writes derived build data to %@.",
                        output
                    ))
                }
                return effects
            }
            return [String(
                localized: "decision.effect.localCommand",
                defaultValue: "Runs a local command; its executable or scripts may create or modify files."
            )]
        }

        private static func riskReasons(
            executable: String,
            arguments: [String],
            operators: Set<ShellOperator>,
            workingDirectory: URL?
        ) -> [String] {
            var reasons: [String] = []
            let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
            if name == "sudo" || arguments.contains("sudo") {
                reasons.append("privilegeEscalation")
            }
            if operators.contains(.pipeline) {
                reasons.append("pipeline")
            }
            if operators.contains(.redirection) {
                reasons.append("redirection")
            }
            if operators.contains(.subshell) {
                reasons.append("subshell")
            }
            if ["curl", "wget", "nc", "ssh", "scp"].contains(name) {
                reasons.append("networkTool")
            }
            if name == "rm", arguments.contains(where: { $0 == "-rf" || $0 == "-fr" }) {
                reasons.append("recursiveDelete")
            }
            if let index = arguments.firstIndex(of: "-derivedDataPath"), arguments.indices.contains(index + 1) {
                if let root = workingDirectory, !isWithinDisplayPath(arguments[index + 1], root: root) {
                    reasons.append("outsideWorkspaceWrite")
                }
            }
            return reasons.sorted()
        }

        private static func displayPath(_ path: String, workingDirectory: URL?) -> String {
            guard let workingDirectory else { return path }
            if path == "$PWD" {
                return workingDirectory.path
            }
            if path.hasPrefix("$PWD/") {
                let suffix = String(path.dropFirst("$PWD/".count))
                return workingDirectory.appendingPathComponent(suffix).standardizedFileURL.path
            }
            return path
        }

        private static func isWithinDisplayPath(_ path: String, root: URL) -> Bool {
            let displayed = displayPath(path, workingDirectory: root)
            guard displayed.hasPrefix("/") else { return true }
            let normalized = URL(fileURLWithPath: displayed).standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            return normalized == rootPath || normalized.hasPrefix(rootPath + "/")
        }

        private static func format(
            _ key: StaticString,
            defaultValue: String.LocalizationValue,
            _ arguments: CVarArg...
        ) -> String {
            String(
                format: String(localized: key, defaultValue: defaultValue),
                locale: Locale.current,
                arguments: arguments
            )
        }
    }

    private enum ShellOperator: Hashable {
        case pipeline
        case redirection
        case subshell
    }

    private enum SafeShellTokenizer {
        struct Result {
            let tokens: [String]
            let operators: Set<ShellOperator>
        }

        // The single-pass tokenizer deliberately keeps quote and operator state adjacent.
        // swiftlint:disable:next function_body_length
        static func tokenize(_ command: String) -> Result {
            enum Quote { case single, double }
            var quote: Quote?
            var escaped = false
            var token = ""
            var tokens: [String] = []
            var operators: Set<ShellOperator> = []
            let characters = Array(command)
            var index = 0
            func finishToken() {
                guard !token.isEmpty else { return }
                tokens.append(token)
                token.removeAll(keepingCapacity: true)
            }
            while index < characters.count {
                let character = characters[index]
                if escaped {
                    token.append(character)
                    escaped = false
                    index += 1
                    continue
                }
                if character == "\\", quote != .single {
                    escaped = true
                    index += 1
                    continue
                }
                if character == "'", quote != .double {
                    quote = quote == .single ? nil : .single
                    index += 1
                    continue
                }
                if character == "\"", quote != .single {
                    quote = quote == .double ? nil : .double
                    index += 1
                    continue
                }
                if quote == nil, character.isWhitespace {
                    finishToken()
                    index += 1
                    continue
                }
                if quote == nil, character == "|" {
                    finishToken()
                    operators.insert(.pipeline)
                    index += 1
                    continue
                }
                if quote == nil, character == ">" || character == "<" {
                    finishToken()
                    operators.insert(.redirection)
                    index += 1
                    continue
                }
                if character == "`" || (character == "$" && characters.indices.contains(index + 1) && characters[index + 1] == "(") {
                    operators.insert(.subshell)
                }
                token.append(character)
                index += 1
            }
            finishToken()
            return Result(tokens: tokens, operators: operators)
        }
    }

#endif
