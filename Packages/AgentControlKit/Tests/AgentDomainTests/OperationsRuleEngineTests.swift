import AgentDomain
import Foundation
import Testing

@Suite("Phase 9 operations rule engine")
struct OperationsRuleEngineTests {
    @Test("Duration alerts are deterministic with a fake clock")
    func deterministicDurationRules() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let session = makeSession(
            state: .waitingApproval,
            startedAt: now.addingTimeInterval(-3600),
            activityAt: now.addingTimeInterval(-900)
        )
        let rules = [
            AlertRule(name: "Long", kind: .longRunning, thresholdSeconds: 3000),
            AlertRule(name: "Waiting", kind: .waitingApproval, thresholdSeconds: 600),
            AlertRule(name: "Idle only", kind: .idle, thresholdSeconds: 1)
        ]
        let alerts = OperationsRuleEngine.alerts(
            for: [session], rules: rules,
            clock: FixedAgentClock(now: now, monotonicNanoseconds: 42)
        )
        #expect(alerts.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.longRunning, .waitingApproval])
        #expect(alerts.first(where: { $0.kind == .longRunning })?.observedDurationSeconds == 3600)
        #expect(alerts.first(where: { $0.kind == .waitingApproval })?.observedDurationSeconds == 900)
    }

    @Test("Automation is fail-closed above low risk and outside the narrow allowlist")
    func automationBoundary() {
        let session = makeSession(state: .waitingApproval)
        let rule = LowRiskAutomationRule(
            name: "Read only", actionKinds: [.readFile, .readOnlyTool],
            adapterID: session.adapterID, projectID: session.project.id
        )
        for level in [RiskLevel.medium, .high, .critical] {
            let request = approval(
                session: session,
                action: .modifyFiles(FileChangeSummary(paths: [session.project.rootURL], operation: .read)),
                risk: level
            )
            #expect(OperationsRuleEngine.automation(for: request, session: session, rules: [rule]) != .allow(ruleID: rule.id))
        }
        let command = approval(
            session: session,
            action: .executeCommand(ParsedCommand(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])),
            risk: .low
        )
        #expect(OperationsRuleEngine.automation(for: command, session: session, rules: [rule]) != .allow(ruleID: rule.id))
    }

    @Test("An explicit scoped rule can allow only normalized low-risk reads")
    func explicitLowRiskRule() {
        let session = makeSession(state: .waitingApproval)
        let rule = LowRiskAutomationRule(
            name: "Workspace reads", actionKinds: [.readFile],
            adapterID: session.adapterID, projectID: session.project.id
        )
        let request = approval(
            session: session,
            action: .modifyFiles(FileChangeSummary(paths: [session.project.rootURL], operation: .read)),
            risk: .low
        )
        #expect(OperationsRuleEngine.automation(for: request, session: session, rules: [rule]) == .allow(ruleID: rule.id))
        var disabled = rule
        disabled.isEnabled = false
        #expect(OperationsRuleEngine.automation(for: request, session: session, rules: [disabled]) != .allow(ruleID: rule.id))
    }

    private func makeSession(
        state: SessionState,
        startedAt: Date = Date(timeIntervalSince1970: 1_999_999_000),
        activityAt: Date = Date(timeIntervalSince1970: 1_999_999_900)
    ) -> AgentSession {
        AgentSession(
            id: SessionID(UUID()), nodeID: NodeID(UUID()), adapterID: AdapterID("codex"),
            externalSessionID: nil,
            project: ProjectReference(id: ProjectID(UUID()), name: "Fixture", rootURL: URL(fileURLWithPath: "/tmp/fixture")),
            terminalContext: nil, parentSessionID: nil, state: state, startedAt: startedAt,
            endedAt: nil, lastMeaningfulEventAt: activityAt, snapshotRevision: 1
        )
    }

    private func approval(session: AgentSession, action: AgentAction, risk: RiskLevel) -> ApprovalRequest {
        ApprovalRequest(
            id: ApprovalRequestID(UUID()), sessionID: session.id, providerRequestID: "fixture",
            action: action, risk: RiskAssessment(level: risk, reasons: ["fixture"]),
            createdAt: session.lastMeaningfulEventAt, expiresAt: nil, revision: 1, status: .received
        )
    }
}
