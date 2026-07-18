#if os(macOS)
    import AgentDomain
    import AgentLocalIPC
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
        case expired
        case superseded
        case rejected
        case failed

        public var isApplied: Bool {
            false
        }
    }

    public struct DecisionPresentation: Sendable, Equatable {
        public let title: String
        public let detailLines: [String]
        public let risk: RiskAssessment?
        public let riskReasons: [String]

        public init(decision: PendingHookDecision) {
            risk = decision.approval?.risk
            riskReasons = decision.approval?.risk.reasons ?? []
            switch decision.kind {
            case .approval:
                title = decision.prompt
                detailLines = Self.lines(for: decision.approval?.action)
            case .question:
                title = decision.question?.prompt ?? decision.prompt
                detailLines = decision.choices
            case .plan:
                title = decision.planTitle ?? decision.prompt
                detailLines = decision.prompt == title ? [] : [decision.prompt]
            }
        }

        private static func lines(for action: AgentAction?) -> [String] {
            guard let action else { return [] }
            switch action {
            case let .executeCommand(command):
                var lines = ["Executable: \(command.executable.path)"]
                if !command.arguments.isEmpty {
                    lines.append("Arguments: \(command.arguments.joined(separator: " "))")
                }
                if let directory = command.workingDirectory {
                    lines.append("Working directory: \(directory.path)")
                }
                if !command.environmentVariableNames.isEmpty {
                    lines.append("Environment keys: \(command.environmentVariableNames.sorted().joined(separator: ", "))")
                }
                return lines
            case let .modifyFiles(summary):
                return ["\(summary.operation.rawValue.capitalized): \(summary.paths.map(\.path).joined(separator: ", "))"]
            case let .accessNetwork(summary):
                let endpoint = summary.port.map { "\(summary.host):\($0)" } ?? summary.host
                return ["\(summary.usesTLS ? "TLS" : "Network"): \(endpoint)"]
            case let .useTool(summary):
                return ["Tool: \(summary.name)", summary.isReadOnly ? "Read-only" : "May modify data"]
            case let .changePlan(summary):
                return [summary.title]
            case let .custom(summary):
                return [summary.summary]
            }
        }
    }

    @MainActor
    public enum TerminalFallback {
        public static func open(for decision: PendingHookDecision) {
            let bundleID = decision.terminalContext?.applicationBundleID
            if let bundleID, let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
                return
            }
            if let root = decision.projectRootURL {
                NSWorkspace.shared.open(root)
            }
        }
    }
#endif
