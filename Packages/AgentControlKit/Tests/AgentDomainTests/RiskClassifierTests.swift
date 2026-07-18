import AgentDomain
import Foundation
import Testing

@Suite("Deterministic risk classifier")
struct RiskClassifierTests {
    @Test("Risk fixtures classify deterministically")
    func fixtures() throws {
        let url = try #require(Bundle.module.url(forResource: "risk-cases", withExtension: "json"))
        let cases = try JSONDecoder().decode([RiskCase].self, from: Data(contentsOf: url))
        let classifier = RiskClassifier()
        for item in cases {
            let result = classifier.classify(item.input)
            #expect(result.level == item.expectedLevel, "Fixture: \(item.name)")
            #expect(result.remoteApproval == item.expectedRemoteApproval, "Fixture: \(item.name)")
        }
    }

    @Test("Critical risk is never remotely approvable")
    func criticalRemotePolicy() {
        let input = RiskInput(
            action: .executeCommand(.init(executable: URL(fileURLWithPath: "/usr/bin/sudo"), arguments: ["rm", "-rf", "/"])),
            workspaceRoot: URL(fileURLWithPath: "/workspace"),
            signals: [.privilegeEscalation, .recursiveDelete, .destructiveWildcard]
        )
        let result = RiskClassifier().classify(input)
        #expect(result.level == .critical)
        #expect(result.remoteApproval == .forbidden)
    }

    @Test("Structured command signals cannot lower risk", arguments: [
        ParsedCommand(executable: URL(fileURLWithPath: "/usr/bin/sudo"), arguments: ["true"]),
        ParsedCommand(executable: URL(fileURLWithPath: "/bin/su"), arguments: ["root"]),
        ParsedCommand(executable: URL(fileURLWithPath: "/bin/rm"), arguments: ["-fr", "/tmp/data"]),
    ])
    func criticalCommands(command: ParsedCommand) {
        let result = RiskClassifier().classify(.init(
            action: .executeCommand(command),
            workspaceRoot: URL(fileURLWithPath: "/workspace")
        ))
        #expect(result.level == .critical)
        #expect(result.remoteApproval == .forbidden)
    }

    @Test("Shell composition and file deletion raise risk")
    func highRiskDetails() {
        let classifier = RiskClassifier()
        let shell = classifier.classify(.init(
            action: .executeCommand(.init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["echo", "a && b"])),
            workspaceRoot: URL(fileURLWithPath: "/workspace")
        ))
        let deletion = classifier.classify(.init(
            action: .modifyFiles(.init(paths: [URL(fileURLWithPath: "/workspace/file")], operation: .delete)),
            workspaceRoot: URL(fileURLWithPath: "/workspace")
        ))
        #expect(shell.level == .high)
        #expect(deletion.level == .high)
    }

    @Test("Secret paths are critical and writable tools are medium")
    func actionDetails() {
        let classifier = RiskClassifier()
        let secret = classifier.classify(.init(
            action: .modifyFiles(.init(paths: [URL(fileURLWithPath: "/workspace/.ssh/id_ed25519")], operation: .read)),
            workspaceRoot: URL(fileURLWithPath: "/workspace")
        ))
        let writableTool = classifier.classify(.init(
            action: .useTool(.init(name: "editor", isReadOnly: false)),
            workspaceRoot: URL(fileURLWithPath: "/workspace")
        ))
        let plan = classifier.classify(.init(
            action: .changePlan(.init(title: "Plan")),
            workspaceRoot: URL(fileURLWithPath: "/workspace")
        ))
        #expect(secret.level == .critical)
        #expect(writableTool.level == .medium)
        #expect(plan.level == .medium)
    }
}

private struct RiskCase: Decodable {
    let name: String
    let expectedLevel: RiskLevel
    let expectedRemoteApproval: RemoteApprovalPolicy
    let action: String
    let path: String?
    let signals: Set<RiskSignal>

    var input: RiskInput {
        let workspace = URL(fileURLWithPath: "/workspace")
        switch action {
        case "modify":
            return RiskInput(
                action: .modifyFiles(.init(paths: [URL(fileURLWithPath: path ?? "/workspace/file")], operation: .write)),
                workspaceRoot: workspace,
                signals: signals
            )
        case "network":
            return RiskInput(
                action: .accessNetwork(.init(host: "example.com", port: 443, usesTLS: true)),
                workspaceRoot: workspace,
                signals: signals
            )
        default:
            return RiskInput(action: .custom(.init(summary: action)), workspaceRoot: workspace, signals: signals)
        }
    }
}
