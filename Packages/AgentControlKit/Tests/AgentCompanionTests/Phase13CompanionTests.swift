import AgentCompanion
import AgentDomain
import Foundation
import Testing

private let phase13Now = Date(timeIntervalSince1970: 2_000_000_000)

private func inboxItem(
    risk: RiskLevel,
    kind: CompanionRequestKind = .approval,
    question: CompanionQuestionDescriptor? = nil,
    expiresAt: Date = phase13Now.addingTimeInterval(300)
) -> CompanionInboxItem {
    .init(
        id: UUID(), requestVersion: 1, sessionID: SessionID(UUID()), agentName: "Codex",
        projectName: "AgentControl", title: "Permission required", detail: "Run tests",
        risk: risk, kind: kind, question: question, createdAt: phase13Now, expiresAt: expiresAt
    )
}

@Test func notificationAndApplicationDecisionPolicyFailsClosed() throws {
    let policy = CompanionDecisionPolicy()
    try policy.authorize(
        outcome: .approve, for: inboxItem(risk: .low),
        evidence: .init(surface: .notificationAction), now: phase13Now
    )
    try policy.authorize(
        outcome: .approve, for: inboxItem(risk: .medium),
        evidence: .init(surface: .notificationAction), now: phase13Now
    )
    #expect(throws: CompanionAuthorizationError.approvalRequiresApplication) {
        try policy.authorize(
            outcome: .approve, for: inboxItem(risk: .high),
            evidence: .init(surface: .notificationAction, strongAuthentication: true), now: phase13Now
        )
    }
    #expect(throws: CompanionAuthorizationError.strongAuthenticationRequired) {
        try policy.authorize(
            outcome: .approve, for: inboxItem(risk: .high),
            evidence: .init(surface: .applicationDetail, holdCompleted: true), now: phase13Now
        )
    }
    #expect(throws: CompanionAuthorizationError.holdRequired) {
        try policy.authorize(
            outcome: .approve, for: inboxItem(risk: .high),
            evidence: .init(surface: .applicationDetail, strongAuthentication: true), now: phase13Now
        )
    }
    try policy.authorize(
        outcome: .approve, for: inboxItem(risk: .high),
        evidence: .init(surface: .applicationDetail, strongAuthentication: true, holdCompleted: true),
        now: phase13Now
    )
    #expect(throws: CompanionAuthorizationError.criticalApprovalForbidden) {
        try policy.authorize(
            outcome: .approve, for: inboxItem(risk: .critical),
            evidence: .init(surface: .applicationDetail, strongAuthentication: true, holdCompleted: true),
            now: phase13Now
        )
    }
}

@Test func secretAndExpiredRequestsCannotBeAnswered() throws {
    let policy = CompanionDecisionPolicy()
    let secret = inboxItem(
        risk: .low, kind: .question,
        question: .init(kind: .secret)
    )
    #expect(secret.availability(at: phase13Now) == .macRequired)
    #expect(throws: CompanionAuthorizationError.secretAnswerForbidden) {
        try policy.authorize(
            outcome: .answer, for: secret, evidence: .init(surface: .applicationDetail),
            answer: "hidden", now: phase13Now
        )
    }
    #expect(throws: CompanionAuthorizationError.requestExpired) {
        try policy.authorize(
            outcome: .deny, for: inboxItem(risk: .low, expiresAt: phase13Now),
            evidence: .init(surface: .notificationAction), now: phase13Now
        )
    }
}

@Test func outboxDoesNotReportSuccessBeforeProviderAcknowledgment() async {
    let outbox = CompanionDecisionOutbox()
    let payload = CompanionDecisionPayload(
        requestID: UUID(), requestVersion: 1, requestedOutcome: .approve, decidedAt: phase13Now
    )
    let pending = await outbox.enqueue(payload, now: phase13Now)
    await outbox.markServerAccepted(
        pending.id, envelopeID: UUID(), at: phase13Now.addingTimeInterval(1)
    )
    var snapshot = await outbox.snapshot()
    #expect(snapshot.first?.state == .awaitingProviderAcknowledgment)
    #expect(snapshot.first?.state.isSuccess == false)

    await outbox.markAcknowledged(
        .init(
            requestID: payload.requestID, applied: true, providerReference: "provider-1",
            acknowledgedAt: phase13Now.addingTimeInterval(2)
        ),
        at: phase13Now.addingTimeInterval(2)
    )
    snapshot = await outbox.snapshot()
    #expect(snapshot.first?.state == .applied)
    #expect(snapshot.first?.state.isSuccess == true)
}

@Test func notificationPrivacyAndGenericFallbackAreDeterministic() {
    let item = inboxItem(risk: .high)
    let hidden = CompanionNotificationRenderer.render(item, privacy: .hidden)
    #expect(hidden.title == "yusufiwt")
    #expect(!hidden.body.contains(item.projectName))
    #expect(hidden.categoryIdentifier == CompanionNotificationCategory.highApproval)

    let full = CompanionNotificationRenderer.render(item, privacy: .full)
    #expect(full.title == item.title)
    #expect(full.body == item.detail)
    let secret = inboxItem(risk: .low, kind: .question, question: .init(kind: .secret))
    #expect(CompanionNotificationCategory.identifier(for: secret) == CompanionNotificationCategory.questionReview)
    #expect(CompanionNotificationRenderer.genericFallback.categoryIdentifier == CompanionNotificationCategory.status)
}

@Test func pairingCodecAndDeepLinksRoundTrip() throws {
    let material = PairingKeyMaterial()
    let payload = try PairingQRCode.make(
        relayOrigin: #require(URL(string: "https://relay.example.com")), sessionID: UUID(),
        macDeviceID: DeviceID(UUID()), macEphemeralPublicKey: material.publicKey,
        expiresAt: phase13Now.addingTimeInterval(60)
    )
    let url = try PairingQRCodeCodec.encode(payload)
    #expect(try PairingQRCodeCodec.decode(url.absoluteString, now: phase13Now) == payload)
    var brandedPairingURL = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    brandedPairingURL.scheme = "yusufiwt"
    #expect(try PairingQRCodeCodec.decode(#require(brandedPairingURL.url).absoluteString, now: phase13Now) == payload)

    let requestID = UUID()
    #expect(try CompanionDeepLink(url: #require(URL(string: "agentcontrol://inbox/\(requestID)"))) == .inbox(requestID))
    #expect(try CompanionDeepLink(url: #require(URL(string: "yusufiwt://inbox/\(requestID)"))) == .inbox(requestID))
    #expect(try CompanionDeepLink(url: #require(URL(string: "https://example.com"))) == nil)
}
