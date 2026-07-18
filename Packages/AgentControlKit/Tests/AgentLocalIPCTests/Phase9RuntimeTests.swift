import AgentDomain
import AgentLocalIPC
import AgentPersistence
import AgentProtocol
import Foundation
import Testing

@Suite("Phase 9 helper operations", .serialized)
struct Phase9RuntimeTests {
    @Test("Helper auto-approves only an explicit normalized low-risk read rule")
    func narrowAutomation() async throws {
        let paths = try temporaryPaths()
        let stack = try await makeTestRuntime(paths: paths)
        let fixture = try LocalIPCFixture()
        let submission = fixture.submission()
        let rule = LowRiskAutomationRule(
            name: "Fixture reads", actionKinds: [.readFile],
            adapterID: submission.initialSession.adapterID,
            projectID: submission.initialSession.project.id
        )
        try await stack.database.upsertRule(.automation(rule))

        let approval = ApprovalRequest(
            id: ApprovalRequestID(UUID()), sessionID: submission.initialSession.id,
            providerRequestID: "read", action: .modifyFiles(FileChangeSummary(
                paths: [submission.initialSession.project.rootURL], operation: .read
            )),
            risk: RiskAssessment(level: .low, reasons: ["workspace-read"]),
            createdAt: fixture.date, expiresAt: nil, revision: 1, status: .received
        )
        let envelope = try EventEnvelope(
            eventID: EventID(UUID()), eventType: "approval.requested",
            source: submission.envelope.source, sessionID: submission.initialSession.id,
            sequence: 1, occurredAt: fixture.date, receivedAt: fixture.date,
            payload: JSONValue.encoding(approval), privacyClass: .privateMetadata,
            correlationID: EnvelopeID(UUID()), schemaHash: "phase9"
        )
        let request = HookDecisionRequest(
            requestID: approval.id.rawValue, revision: 1, kind: .approval, prompt: "Read?",
            submission: HelperEventSubmission(envelope: envelope, initialSession: submission.initialSession)
        )
        let response = await stack.runtime.handle(.requestDecision(request))
        guard case let .decision(result) = response else {
            Issue.record("Expected an automated decision")
            await stack.runtime.gracefulShutdown()
            return
        }
        #expect(result.decision == .approve)
        #expect(try await stack.database.auditEntries().first?.action == "allowed.lowRisk")
        await stack.runtime.gracefulShutdown()
    }

    @Test("Helper exposes typed rules, privacy, diagnostics, and repair endpoints")
    func typedOperationsEndpoints() async throws {
        let stack = try await makeTestRuntime(paths: temporaryPaths())
        let alert = AlertRule(name: "Idle", kind: .idle, thresholdSeconds: 60)
        #expect(await stack.runtime.handle(.upsertRule(.alert(alert))).savedRuleID == alert.id)
        #expect(await stack.runtime.handle(.listRules).ruleCount == 1)
        #expect(await stack.runtime.handle(.privacySettings).privacyValue == .privacyFirst)
        #expect(await stack.runtime.handle(.diagnostics).diagnosticsValue?.schemaVersion == 2)
        #expect(await stack.runtime.handle(.repair(.checkpointDatabase)).repairValue?.action == .checkpointDatabase)
        await stack.runtime.gracefulShutdown()
    }
}

private extension HelperResponse {
    var savedRuleID: UUID? {
        if case let .ruleSaved(rule) = self {
            rule.id
        } else {
            nil
        }
    }

    var ruleCount: Int? {
        if case let .rules(rules) = self {
            rules.count
        } else {
            nil
        }
    }

    var privacyValue: PrivacySettings? {
        if case let .privacySettings(value) = self {
            value
        } else {
            nil
        }
    }

    var diagnosticsValue: DiagnosticsReport? {
        if case let .diagnostics(value) = self {
            value
        } else {
            nil
        }
    }

    var repairValue: RepairResult? {
        if case let .repair(value) = self {
            value
        } else {
            nil
        }
    }
}
