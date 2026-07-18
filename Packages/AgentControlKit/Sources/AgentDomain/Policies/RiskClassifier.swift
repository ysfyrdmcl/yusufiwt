import Foundation

public struct RiskClassifier: Sendable {
    private static let criticalSignals: Set<RiskSignal> = [
        .privilegeEscalation,
        .recursiveDelete,
        .destructiveWildcard,
        .diskOperation,
        .productionDeployment,
        .secretAccess,
        .pipeToShell,
        .unknownShellComposition,
        .networkWithSecret,
        .forcePushProtectedBranch,
        .destructiveDatabaseMigration
    ]

    public init() {}

    public func classify(_ input: RiskInput) -> RiskAssessment {
        var level = baseLevel(for: input.action)
        var reasons: [String] = []

        let critical = input.signals.intersection(Self.criticalSignals)
        if !critical.isEmpty {
            level = .critical
            reasons.append(contentsOf: critical.map(\.rawValue).sorted())
        }

        switch input.action {
        case let .executeCommand(command):
            classify(command, level: &level, reasons: &reasons)
        case let .modifyFiles(change):
            classify(change, workspaceRoot: input.workspaceRoot, level: &level, reasons: &reasons)
        case .accessNetwork:
            level = max(level, .high)
            reasons.append("networkAccess")
        case let .useTool(tool):
            if !tool.isReadOnly {
                level = max(level, .medium)
            }
        case .changePlan, .custom:
            break
        }

        return RiskAssessment(level: level, reasons: Array(Set(reasons)).sorted())
    }

    private func baseLevel(for action: AgentAction) -> RiskLevel {
        switch action {
        case .executeCommand, .modifyFiles, .changePlan: .medium
        case .accessNetwork: .high
        case .useTool, .custom: .low
        }
    }

    private func classify(_ command: ParsedCommand, level: inout RiskLevel, reasons: inout [String]) {
        let executable = command.executable.lastPathComponent.lowercased()
        if executable == "sudo" || executable == "su" {
            level = .critical
            reasons.append("privilegeEscalation")
        }
        let joined = command.arguments.joined(separator: " ").lowercased()
        if executable == "rm", joined.contains("-rf") || joined.contains("-fr") {
            level = .critical
            reasons.append("recursiveDelete")
        }
        if ["&&", "||", ";", "|", ">", "<", "$("].contains(where: joined.contains) {
            level = max(level, .high)
            reasons.append("shellComposition")
        }
    }

    private func classify(
        _ change: FileChangeSummary,
        workspaceRoot: URL,
        level: inout RiskLevel,
        reasons: inout [String]
    ) {
        for path in change.paths {
            if !isWithin(path, root: workspaceRoot) {
                level = max(level, .high)
                reasons.append("outsideWorkspace")
            }
            let lowerPath = path.standardizedFileURL.path.lowercased()
            if ["/.ssh/", "/.gnupg/", "/keychain/", "/credentials", "/.env"].contains(where: lowerPath.contains) {
                level = .critical
                reasons.append("secretPath")
            }
        }
        if change.operation == .delete {
            level = max(level, .high)
            reasons.append("fileDeletion")
        }
    }

    private func isWithin(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
