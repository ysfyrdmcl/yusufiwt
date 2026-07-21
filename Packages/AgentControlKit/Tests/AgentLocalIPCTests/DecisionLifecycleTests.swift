#if os(macOS)
    import AgentDomain
    import AgentLocalIPC
    import AgentProtocol
    import Foundation
    import Testing

    @Suite("Authoritative decision lifecycle", .serialized)
    // The serialized suite documents one end-to-end lifecycle contract.
    // swiftlint:disable:next type_body_length
    struct DecisionLifecycleTests {
        @Test("User resolution remains awaiting provider acknowledgment until a provider status arrives")
        func userResolutionAndAcknowledgment() async throws {
            let fixture = try LocalIPCFixture()
            let request = Self.request(fixture: fixture)
            let broker = HookDecisionBroker()
            async let providerResponse = broker.wait(for: request)
            try await waitUntil { await broker.pending().count == 1 }

            #expect(await broker.resolve(.init(
                requestID: request.requestID,
                revision: request.revision,
                decision: .approve
            )) == .accepted)
            #expect(await providerResponse.decisionValue?.decision == .approve)
            #expect(await broker.pending().isEmpty)
            #expect(await broker.lifecycles().first?.state == .userResolvedAwaitingProviderAck)

            await broker.observeProviderStatus(
                requestID: request.requestID,
                revision: request.revision,
                status: .providerAcknowledged
            )
            #expect(await broker.lifecycles().first?.state == .applied)

            // Exact retry is idempotent; a conflicting second answer never reaches the provider.
            #expect(await broker.resolve(.init(
                requestID: request.requestID,
                revision: request.revision,
                decision: .approve
            )) == .accepted)
            #expect(await broker.resolve(.init(
                requestID: request.requestID,
                revision: request.revision,
                decision: .deny
            )) == .notFound)
        }

        @Test("Denial and automation retain their source and map provider acknowledgment correctly")
        func denialAndAutomation() async throws {
            let fixture = try LocalIPCFixture()
            let deniedRequest = Self.request(fixture: fixture)
            let broker = HookDecisionBroker()
            async let deniedResponse = broker.wait(for: deniedRequest)
            try await waitUntil { await broker.pending().count == 1 }
            #expect(await broker.resolve(.init(
                requestID: deniedRequest.requestID,
                revision: 1,
                decision: .deny
            )) == .accepted)
            _ = await deniedResponse
            await broker.observeProviderStatus(
                requestID: deniedRequest.requestID,
                revision: 1,
                status: .providerAcknowledged
            )
            let denied = try #require(await broker.lifecycles().first {
                $0.requestID == deniedRequest.requestID
            })
            #expect(denied.state == .deniedApplied)
            #expect(denied.resolutionSource == .user)

            let automaticRequest = Self.request(fixture: fixture, requestID: UUID())
            _ = await broker.recordAutomaticResolution(.approve, for: automaticRequest)
            let automaticPending = try #require(await broker.lifecycles().first {
                $0.requestID == automaticRequest.requestID
            })
            #expect(automaticPending.state == .automaticallyResolvedAwaitingProviderAck)
            #expect(automaticPending.resolutionSource == .automation)
            #expect(await broker.pending().isEmpty)
            await broker.observeProviderStatus(
                requestID: automaticRequest.requestID,
                revision: 1,
                status: .applied
            )
            #expect(await broker.lifecycles().first {
                $0.requestID == automaticRequest.requestID
            }?.state == .applied)
        }

        @Test("Provider denial confirms a local deny but rejects a local approval")
        func providerDenialOutcome() async throws {
            let fixture = try LocalIPCFixture()
            let broker = HookDecisionBroker()

            let approvedRequest = Self.request(fixture: fixture)
            async let approvedResponse = broker.wait(for: approvedRequest)
            try await waitUntil { await broker.pending().count == 1 }
            #expect(await broker.resolve(.init(
                requestID: approvedRequest.requestID,
                revision: 1,
                decision: .approve
            )) == .accepted)
            _ = await approvedResponse
            await broker.observeProviderStatus(
                requestID: approvedRequest.requestID,
                revision: 1,
                status: .providerRejected
            )
            #expect(await Self.lifecycleState(broker: broker, requestID: approvedRequest.requestID) == .providerRejected)

            let deniedRequest = Self.request(fixture: fixture, requestID: UUID())
            async let deniedResponse = broker.wait(for: deniedRequest)
            try await waitUntil { await broker.pending().count == 1 }
            #expect(await broker.resolve(.init(
                requestID: deniedRequest.requestID,
                revision: 1,
                decision: .deny
            )) == .accepted)
            _ = await deniedResponse
            await broker.observeProviderStatus(
                requestID: deniedRequest.requestID,
                revision: 1,
                status: .providerRejected
            )
            #expect(await Self.lifecycleState(broker: broker, requestID: deniedRequest.requestID) == .deniedApplied)
        }

        @Test("A reused provider fingerprint cannot replay a decision into a new invocation")
        func reusedFingerprintStartsNewInvocation() async throws {
            let fixture = try LocalIPCFixture()
            let requestID = UUID()
            let broker = HookDecisionBroker()
            let first = Self.request(fixture: fixture, requestID: requestID)
            async let firstResponse = broker.wait(for: first)
            try await waitUntil { await broker.pending().count == 1 }
            #expect(await broker.resolve(.init(
                requestID: requestID, revision: 1, decision: .approve
            )) == .accepted)
            #expect(await firstResponse.decisionValue?.decision == .approve)

            let second = Self.request(fixture: fixture, requestID: requestID)
            #expect(second.submission.envelope.eventID != first.submission.envelope.eventID)
            async let secondResponse = broker.wait(for: second)
            try await waitUntil { await broker.pending().count == 1 }
            #expect(await broker.resolve(.init(
                requestID: requestID, revision: 1, decision: .deny
            )) == .accepted)
            #expect(await secondResponse.decisionValue?.decision == .deny)
        }

        @Test("Duplicate waiters join while a higher revision supersedes the old invocation")
        func duplicateJoinAndHigherRevision() async throws {
            let fixture = try LocalIPCFixture()
            let requestID = UUID()
            let broker = HookDecisionBroker()
            let first = Self.request(fixture: fixture, requestID: requestID)
            async let firstWaiter = broker.wait(for: first)
            async let duplicateWaiter = broker.wait(for: first)
            try await waitUntil { await broker.pending().count == 1 }
            #expect(await broker.resolve(.init(
                requestID: requestID, revision: 1, decision: .approve
            )) == .accepted)
            #expect(await firstWaiter.decisionValue?.decision == .approve)
            #expect(await duplicateWaiter.decisionValue?.decision == .approve)

            let old = Self.request(fixture: fixture, requestID: UUID(), revision: 1)
            async let oldWaiter = broker.wait(for: old)
            try await waitUntil { await broker.pending().contains { $0.requestID == old.requestID } }
            let revised = Self.request(fixture: fixture, requestID: old.requestID, revision: 2)
            async let revisedWaiter = broker.wait(for: revised)
            #expect(await oldWaiter.neutralValue == .timeout)
            try await waitUntil {
                await broker.pending().contains { $0.requestID == revised.requestID && $0.revision == 2 }
            }
            #expect(await broker.resolve(.init(
                requestID: revised.requestID, revision: 1, decision: .deny
            )) == .revisionMismatch)
            #expect(await broker.resolve(.init(
                requestID: revised.requestID, revision: 2, decision: .deny
            )) == .accepted)
            #expect(await revisedWaiter.decisionValue?.decision == .deny)
        }

        @Test("Resolved decisions expire on provider acknowledgment timeout, not original prompt expiry")
        func providerAcknowledgmentTimeout() async throws {
            let fixture = try LocalIPCFixture()
            let clock = LockedTestDate(fixture.date)
            let broker = HookDecisionBroker(
                now: { clock.now() },
                providerAcknowledgmentTimeoutSeconds: 30
            )
            let request = Self.request(fixture: fixture)
            async let response = broker.wait(for: request)
            try await waitUntil { await broker.pending().count == 1 }
            #expect(await broker.resolve(.init(
                requestID: request.requestID, revision: 1, decision: .approve
            )) == .accepted)
            _ = await response
            clock.advance(by: 29)
            #expect(await Self.lifecycleState(broker: broker, requestID: request.requestID)
                == .userResolvedAwaitingProviderAck)
            clock.advance(by: 2)
            #expect(await Self.lifecycleState(broker: broker, requestID: request.requestID) == .expired)
        }

        @Test("Helper read models expose awaiting acknowledgment and then applied without recreating pending work")
        // swiftlint:disable:next function_body_length
        func helperLifecycleEndpoint() async throws {
            let fixture = try LocalIPCFixture()
            let stack = try await makeTestRuntime(paths: temporaryPaths())
            let request = Self.request(fixture: fixture)
            async let providerResponse = stack.runtime.handle(.requestDecision(request))
            try await waitUntil {
                guard case let .pendingDecisions(values) = await stack.runtime.handle(.pendingDecisions) else {
                    return false
                }
                return values.count == 1
            }

            guard case .decisionResolution(.accepted) = await stack.runtime.handle(.resolveDecision(.init(
                requestID: request.requestID,
                revision: request.revision,
                decision: .approve
            ))) else {
                Issue.record("Helper did not accept the current revision")
                return
            }
            guard case .decision = await providerResponse else {
                Issue.record("Provider waiter did not receive the user decision")
                return
            }
            #expect(await Self.lifecycleState(runtime: stack.runtime, requestID: request.requestID)
                == .userResolvedAwaitingProviderAck)

            let providerStatus = HelperEventSubmission(
                envelope: EventEnvelope(
                    eventID: EventID(UUID()),
                    eventType: "approval.statusChanged",
                    source: request.submission.envelope.source,
                    sessionID: request.submission.envelope.sessionID,
                    sequence: 10000,
                    occurredAt: fixture.date.addingTimeInterval(10),
                    receivedAt: fixture.date.addingTimeInterval(10),
                    payload: .object([
                        "id": .string(request.requestID.uuidString.lowercased()),
                        "revision": .number(1),
                        "status": .string(ApprovalStatus.applied.rawValue)
                    ]),
                    privacyClass: .privateMetadata,
                    correlationID: request.submission.envelope.correlationID,
                    schemaHash: "decision-lifecycle-test"
                ),
                initialSession: request.submission.initialSession
            )
            guard case .eventAccepted = await stack.runtime.handle(.submitEvent(providerStatus)) else {
                Issue.record("Provider acknowledgment was not accepted")
                return
            }
            #expect(await Self.lifecycleState(runtime: stack.runtime, requestID: request.requestID) == .applied)
            guard case let .pendingDecisions(pending) = await stack.runtime.handle(.pendingDecisions) else {
                Issue.record("Pending endpoint returned the wrong response")
                return
            }
            #expect(pending.isEmpty)
            await stack.runtime.gracefulShutdown()
        }

        private static func lifecycleState(
            runtime: HelperRuntime,
            requestID: UUID
        ) async -> DecisionLifecycleState? {
            guard case let .decisionLifecycles(values) = await runtime.handle(.decisionLifecycles) else {
                return nil
            }
            return values.first { $0.requestID == requestID }?.state
        }

        private static func lifecycleState(
            broker: HookDecisionBroker,
            requestID: UUID
        ) async -> DecisionLifecycleState? {
            await broker.lifecycles().first { $0.requestID == requestID }?.state
        }

        private static func request(
            fixture: LocalIPCFixture,
            requestID: UUID = UUID(),
            revision: Int64 = 1
        ) -> HookDecisionRequest {
            let original = fixture.submission()
            let approval = ApprovalRequest(
                id: ApprovalRequestID(requestID),
                sessionID: fixture.sessionID,
                providerRequestID: "provider-request",
                action: .executeCommand(ParsedCommand(
                    executable: URL(fileURLWithPath: "/usr/bin/swift"),
                    arguments: ["test"],
                    workingDirectory: original.initialSession.project.rootURL
                )),
                risk: RiskAssessment(level: .medium, reasons: ["workspace-write"]),
                createdAt: fixture.date,
                expiresAt: fixture.date.addingTimeInterval(1000),
                revision: revision,
                status: .received
            )
            let envelope = EventEnvelope(
                eventID: EventID(UUID()),
                eventType: "approval.requested",
                source: original.envelope.source,
                sessionID: fixture.sessionID,
                sequence: 1,
                occurredAt: fixture.date,
                receivedAt: fixture.date,
                payload: (try? JSONValue.encoding(approval)) ?? .object([:]),
                privacyClass: .sensitive,
                correlationID: original.envelope.correlationID,
                schemaHash: "decision-lifecycle-test"
            )
            return HookDecisionRequest(
                requestID: requestID,
                revision: revision,
                kind: .approval,
                prompt: "Run swift test?",
                expiresAt: .distantFuture,
                waitTimeoutMilliseconds: 2000,
                submission: HelperEventSubmission(envelope: envelope, initialSession: original.initialSession)
            )
        }
    }

    private func waitUntil(
        attempts: Int = 100,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw LocalIPCError.timeout
    }

    private extension HelperResponse {
        var decisionValue: HookDecisionResult? {
            guard case let .decision(value) = self else { return nil }
            return value
        }

        var neutralValue: NeutralFallbackReason? {
            guard case let .neutral(value) = self else { return nil }
            return value
        }
    }

    private final class LockedTestDate: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        func now() -> Date {
            lock.withLock { value }
        }

        func advance(by interval: TimeInterval) {
            lock.withLock { value = value.addingTimeInterval(interval) }
        }
    }
#endif
