import AgentCompanion
import AgentDomain
import Foundation
import Testing

private let phase14Now = Date(timeIntervalSince1970: 2_100_000_000)

private func phase14Session(
    state: SessionState,
    updatedAt: Date = phase14Now,
    summary: String = "Implemented companion surfaces"
) -> CompanionSessionSummary {
    .init(
        id: SessionID(UUID()), agentName: "Codex", projectName: "AgentControl",
        state: state, startedAt: phase14Now.addingTimeInterval(-600),
        updatedAt: updatedAt, summary: summary
    )
}

private func phase14Item(risk: RiskLevel, createdAt: Date = phase14Now) -> CompanionInboxItem {
    .init(
        id: UUID(), requestVersion: 1, sessionID: SessionID(UUID()),
        agentName: "Codex", projectName: "AgentControl", title: "Run test suite",
        detail: String(repeating: "sensitive-detail", count: 200), risk: risk,
        kind: .approval, createdAt: createdAt,
        expiresAt: phase14Now.addingTimeInterval(300)
    )
}

@Test func surfaceSnapshotIsBoundedAndOmitsRequestDetail() throws {
    let sessions = (0 ..< 20).map { index in
        phase14Session(
            state: index == 0 ? .completed : .running,
            updatedAt: phase14Now.addingTimeInterval(TimeInterval(-index)),
            summary: String(repeating: "completion", count: 50)
        )
    }
    let requests = (0 ..< 20).map { index in
        phase14Item(risk: index == 0 ? .critical : .low)
    }
    let snapshot = CompanionSurfaceSnapshot(sessions: sessions, inbox: requests, generatedAt: phase14Now)
    let data = try snapshot.encoded()

    #expect(data.count <= CompanionSurfaceLimits.maximumPayloadBytes)
    #expect(snapshot.watch.sessions.count == CompanionSurfaceLimits.maximumVisibleSessions)
    #expect(snapshot.watch.requests.count == CompanionSurfaceLimits.maximumVisibleRequests)
    #expect(snapshot.watch.highestPriorityRequest?.risk == .critical)
    #expect(data.range(of: Data("sensitive-detail".utf8)) == nil)
    #expect(try CompanionSurfaceSnapshot.decode(data) == snapshot)
}

@Test func watchOnlyApprovesLowRiskAndCanDenyAnyRisk() throws {
    let low = WatchRequestCard(item: phase14Item(risk: .low))
    let medium = WatchRequestCard(item: phase14Item(risk: .medium))
    let critical = WatchRequestCard(item: phase14Item(risk: .critical))

    #expect(WatchDecisionPolicy.disposition(outcome: .approve, card: low, now: phase14Now) == .allowed)
    #expect(WatchDecisionPolicy.disposition(outcome: .approve, card: medium, now: phase14Now) == .openIPhone)
    #expect(WatchDecisionPolicy.disposition(outcome: .approve, card: critical, now: phase14Now) == .openIPhone)
    #expect(WatchDecisionPolicy.disposition(outcome: .deny, card: critical, now: phase14Now) == .allowed)

    let mediumItem = phase14Item(risk: .medium)
    #expect(throws: CompanionAuthorizationError.watchApprovalForbidden) {
        try CompanionDecisionPolicy().authorize(
            outcome: .approve, for: mediumItem,
            evidence: .init(surface: .watch), now: phase14Now
        )
    }
}

@Test func watchDecisionCodecRoundTripsAndRejectsOversize() throws {
    let value = WatchDecisionMessage(
        requestID: UUID(), requestVersion: 7, outcome: .approve, createdAt: phase14Now
    )
    let encoded = try WatchMessageCodec.encodeDecision(value)
    #expect(try WatchMessageCodec.decodeDecision(encoded) == value)
    #expect(throws: CompanionSurfaceError.invalidWatchMessage) {
        try WatchMessageCodec.decodeDecision([
            WatchMessageCodec.decisionKey: Data(repeating: 1, count: CompanionSurfaceLimits.maximumPayloadBytes + 1)
        ])
    }
}

@Test func activityStateHasDeterministicStaleAndFinalSemantics() {
    let running = AgentActivityContentState(state: .running, updatedAt: phase14Now)
    #expect(running.staleAt.timeIntervalSince(running.updatedAt) == CompanionSurfaceLimits.staleInterval)
    #expect(!running.isFinal)
    #expect(AgentActivityContentState(state: .completed, updatedAt: phase14Now).isFinal)
    #expect(AgentActivityContentState(state: .failed, updatedAt: phase14Now).isFinal)
    #expect(AgentActivityContentState(state: .cancelled, updatedAt: phase14Now).isFinal)
}
