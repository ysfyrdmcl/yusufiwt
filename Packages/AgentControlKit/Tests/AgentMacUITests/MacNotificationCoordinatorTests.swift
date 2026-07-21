#if os(macOS)
    import AgentDomain
    import AgentLocalIPC
    import AgentMacUI
    import AgentProtocol
    import Foundation
    import Testing
    @preconcurrency import UserNotifications

    @Suite("Mac decision notifications", .serialized)
    @MainActor
    struct MacNotificationCoordinatorTests {
        @Test("Pending decisions schedule once and resolved decisions remove pending and delivered notifications")
        func scheduleDeduplicateAndRemove() async throws {
            let center = FixtureNotificationCenter()
            let coordinator = MacNotificationCoordinator(center: center)
            await coordinator.configure()
            let decision = Self.decision()

            await coordinator.reconcile([decision])
            await coordinator.reconcile([decision])
            #expect(center.requests.count == 1)
            let identifier = try #require(center.requests.first?.identifier)
            center.markDelivered(identifier)

            await coordinator.reconcile([PendingHookDecision]())
            #expect(center.requests.isEmpty)
            #expect(center.deliveredIdentifiers.isEmpty)
            #expect(center.removedPending.contains(identifier))
            #expect(center.removedDelivered.contains(identifier))
        }

        @Test("Default tap is review-only, carries a non-sensitive route, and survives cold handler setup")
        func defaultTapAndColdRoute() async throws {
            let center = FixtureNotificationCenter()
            let coordinator = MacNotificationCoordinator(center: center)
            await coordinator.configure()
            let decision = Self.decision()
            await coordinator.reconcile([decision])
            let request = try #require(center.requests.first)
            #expect(Set(request.content.userInfo.keys.compactMap { $0 as? String })
                == ["requestID", "sessionID", "revision", "kind"])
            #expect(!request.content.userInfo.values.contains { String(describing: $0).contains(decision.prompt) })

            let response = try #require(MacNotificationCoordinator.response(
                userInfo: request.content.userInfo,
                actionIdentifier: UNNotificationDefaultActionIdentifier
            ))
            #expect(response.action == .review)
            #expect(response.requestID == decision.requestID)

            coordinator.receive(response)
            #expect(coordinator.pendingResponseCount == 1)
            let recorder = NotificationResponseRecorder()
            coordinator.responseHandler = { value in recorder.record(value) }
            #expect(coordinator.pendingResponseCount == 0)
            #expect(recorder.values == [response])
        }

        @Test("High-risk and secret requests expose review only and secret content is generic")
        func reviewOnlyCategoriesAndPrivacy() async throws {
            let high = Self.decision(risk: .high)
            let secret = Self.decision(kind: .question, questionKind: .secret)
            #expect(MacNotificationCoordinator.category(for: high) == .approvalReviewOnly)
            #expect(MacNotificationCoordinator.category(for: secret) == .secretQuestion)

            for categoryID in [
                MacNotificationCategory.approvalReviewOnly.rawValue,
                MacNotificationCategory.planReviewOnly.rawValue,
                MacNotificationCategory.secretQuestion.rawValue
            ] {
                let category = try #require(MacNotificationCoordinator.categories.first {
                    $0.identifier == categoryID
                })
                #expect(category.actions.map(\.identifier) == [MacNotificationAction.review.rawValue])
            }

            let center = FixtureNotificationCenter()
            let coordinator = MacNotificationCoordinator(
                center: center,
                preferences: MacNotificationPreferences(privacyLevel: .projectAndEvent)
            )
            await coordinator.configure()
            await coordinator.reconcile([secret])
            let content = try #require(center.requests.first?.content)
            #expect(content.body == String(localized: "notification.body.secret"))
            #expect(!content.body.contains(secret.prompt))
            #expect(content.sound != nil)
        }

        @Test("Disabled sound remains silent and an auto-resolved empty snapshot schedules nothing")
        func soundAndAutomaticSuppression() async throws {
            let center = FixtureNotificationCenter()
            let coordinator = MacNotificationCoordinator(
                center: center,
                preferences: MacNotificationPreferences(soundEnabled: false)
            )
            await coordinator.configure()
            await coordinator.reconcile([PendingHookDecision]())
            #expect(center.requests.isEmpty)

            await coordinator.reconcile([Self.decision()])
            #expect(try #require(center.requests.first).content.sound == nil)
        }

        @Test("Pending work waits for authorization and preference changes replace the scheduled request")
        func delayedAuthorizationAndPreferenceRefresh() async throws {
            let center = FixtureNotificationCenter()
            let coordinator = MacNotificationCoordinator(center: center)
            let decision = Self.decision()

            await coordinator.reconcile([decision])
            #expect(center.requests.isEmpty)

            await coordinator.configure()
            #expect(center.requests.count == 1)
            #expect(try #require(center.requests.first).content.sound != nil)

            await coordinator.updatePreferences(MacNotificationPreferences(soundEnabled: false))
            #expect(center.requests.count == 1)
            #expect(try #require(center.requests.first).content.sound == nil)
        }

        @Test("Notch presentation does not disable enabled completion notifications")
        func notchDoesNotSuppressCompletion() async throws {
            let center = FixtureNotificationCenter()
            let coordinator = MacNotificationCoordinator(center: center)
            coordinator.setUsesNotchSurface(true)
            await coordinator.configure()
            await coordinator.reconcile(RegistryNotification(
                sessionID: SessionID(UUID()),
                eventID: EventID(UUID()),
                state: .completed,
                snapshotRevision: 2
            ))
            let content = try #require(center.requests.first?.content)
            #expect(content.body == String(localized: "notification.body.completed"))
        }

        // The fixture mirrors the complete provider request boundary for all three decision kinds.
        // swiftlint:disable:next function_body_length
        private static func decision(
            kind: HookDecisionKind = .approval,
            risk: RiskLevel = .low,
            questionKind: QuestionKind = .freeText
        ) -> PendingHookDecision {
            let requestID = UUID()
            let sessionID = SessionID(UUID())
            let nodeID = NodeID(UUID())
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let project = ProjectReference(
                id: ProjectID(UUID()),
                name: "Private Fixture Project",
                rootURL: URL(fileURLWithPath: "/private/tmp/private-fixture")
            )
            let session = AgentSession(
                id: sessionID,
                nodeID: nodeID,
                adapterID: AdapterID("codex"),
                externalSessionID: "provider-session",
                project: project,
                terminalContext: nil,
                parentSessionID: nil,
                state: .discovered,
                startedAt: now,
                endedAt: nil,
                lastMeaningfulEventAt: now,
                snapshotRevision: 0
            )
            let payload: JSONValue
            switch kind {
            case .approval:
                let approval = ApprovalRequest(
                    id: ApprovalRequestID(requestID),
                    sessionID: sessionID,
                    providerRequestID: "provider-request",
                    action: .executeCommand(ParsedCommand(
                        executable: URL(fileURLWithPath: "/usr/bin/swift"),
                        arguments: ["test"],
                        workingDirectory: project.rootURL
                    )),
                    risk: RiskAssessment(level: risk, reasons: ["fixture-risk"]),
                    createdAt: now,
                    expiresAt: .distantFuture,
                    revision: 1,
                    status: .received
                )
                payload = (try? JSONValue.encoding(approval)) ?? .object([:])
            case .question:
                let question = AgentQuestion(
                    id: QuestionID(requestID),
                    sessionID: sessionID,
                    kind: questionKind,
                    prompt: "Never expose this secret prompt"
                )
                payload = (try? JSONValue.encoding(question)) ?? .object([:])
            case .plan:
                payload = .object(["title": .string("Review private plan")])
            }
            let envelope = EventEnvelope(
                eventID: EventID(UUID()),
                eventType: kind == .approval ? "approval.requested" : "question.requested",
                source: EventSource(adapterID: AdapterID("codex"), adapterVersion: "1", nodeID: nodeID),
                sessionID: sessionID,
                sequence: 1,
                occurredAt: now,
                receivedAt: now,
                payload: payload,
                privacyClass: questionKind == .secret ? .secret : .sensitive,
                correlationID: EnvelopeID(UUID()),
                schemaHash: "notification-fixture"
            )
            return PendingHookDecision(request: HookDecisionRequest(
                requestID: requestID,
                revision: 1,
                kind: kind,
                prompt: kind == .question ? "Never expose this secret prompt" : "Approve private fixture?",
                expiresAt: .distantFuture,
                submission: HelperEventSubmission(envelope: envelope, initialSession: session)
            ))
        }
    }

    @MainActor
    private final class NotificationResponseRecorder {
        private(set) var values: [MacNotificationResponse] = []

        func record(_ value: MacNotificationResponse) {
            values.append(value)
        }
    }

    @MainActor
    private final class FixtureNotificationCenter: MacNotificationCentering {
        var delegate: (any UNUserNotificationCenterDelegate)?
        private(set) var categories: Set<UNNotificationCategory> = []
        private(set) var requests: [UNNotificationRequest] = []
        private(set) var deliveredIdentifiers: Set<String> = []
        private(set) var removedPending: [String] = []
        private(set) var removedDelivered: [String] = []

        func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
            self.categories = categories
        }

        func requestAuthorization(options _: UNAuthorizationOptions) async throws -> Bool {
            true
        }

        func pendingNotificationRequests() async -> [UNNotificationRequest] {
            requests
        }

        func deliveredNotificationIdentifiers() async -> [String] {
            Array(deliveredIdentifiers)
        }

        func add(_ request: UNNotificationRequest) async throws {
            requests.removeAll { $0.identifier == request.identifier }
            requests.append(request)
        }

        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
            removedPending.append(contentsOf: identifiers)
            requests.removeAll { identifiers.contains($0.identifier) }
        }

        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
            removedDelivered.append(contentsOf: identifiers)
            deliveredIdentifiers.subtract(identifiers)
        }

        func markDelivered(_ identifier: String) {
            requests.removeAll { $0.identifier == identifier }
            deliveredIdentifiers.insert(identifier)
        }
    }
#endif
