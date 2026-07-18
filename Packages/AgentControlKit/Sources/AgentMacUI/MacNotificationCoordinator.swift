#if os(macOS)
    import AgentLocalIPC
    import Foundation
    @preconcurrency import UserNotifications

    public enum MacNotificationCategory: String, Sendable {
        case approval = "AGENTCONTROL_APPROVAL"
        case question = "AGENTCONTROL_QUESTION"
        case secretQuestion = "AGENTCONTROL_SECRET_QUESTION"
        case plan = "AGENTCONTROL_PLAN"
    }

    public enum MacNotificationAction: String, Sendable {
        case approve = "AGENTCONTROL_APPROVE"
        case deny = "AGENTCONTROL_DENY"
        case review = "AGENTCONTROL_REVIEW"
        case openTerminal = "AGENTCONTROL_OPEN_TERMINAL"
    }

    public struct MacNotificationResponse: Sendable, Equatable {
        public let action: MacNotificationAction
        public let requestID: UUID
        public let revision: Int64

        public init(action: MacNotificationAction, requestID: UUID, revision: Int64) {
            self.action = action
            self.requestID = requestID
            self.revision = revision
        }
    }

    public enum NotificationAuthorizationState: Sendable, Equatable {
        case unknown
        case authorized
        case denied
    }

    @MainActor
    public final class MacNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
        public var responseHandler: (@MainActor @Sendable (MacNotificationResponse) -> Void)?
        public private(set) var authorizationState: NotificationAuthorizationState = .unknown

        private let center: UNUserNotificationCenter
        private var preferences: MacNotificationPreferences
        private var deduplicator = NotificationDeduplicator()

        public init(
            center: UNUserNotificationCenter = .current(),
            preferences: MacNotificationPreferences = .init()
        ) {
            self.center = center
            self.preferences = preferences
            super.init()
        }

        public func configure() async {
            center.delegate = self
            center.setNotificationCategories(Self.categories)
            do {
                authorizationState = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                    ? .authorized
                    : .denied
            } catch {
                authorizationState = .denied
            }
        }

        public func updatePreferences(_ value: MacNotificationPreferences) {
            preferences = value
        }

        public func reconcile(_ decisions: [PendingHookDecision], now: Date = Date()) async {
            guard authorizationState != .denied else { return }
            deduplicator.reconcile(active: decisions)
            let activeIdentifiers = Set(decisions.map(Self.identifier))
            let pending = await center.pendingNotificationRequests()
            let stale = pending.map(\.identifier).filter { $0.hasPrefix("agentcontrol.decision.") && !activeIdentifiers.contains($0) }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }

            for decision in decisions where DecisionAvailability.evaluate(decision, now: now) == .actionable {
                guard deduplicator.shouldDeliver(decision) else { continue }
                let policy = MacNotificationPolicy.delivery(preferences: preferences, at: now)
                guard policy != .suppress else { continue }
                let content = UNMutableNotificationContent()
                content.title = decision.projectName ?? "AgentControl"
                content.body = Self.body(for: decision)
                content.categoryIdentifier = Self.category(for: decision).rawValue
                content.threadIdentifier = decision.sessionID.description
                content.userInfo = [
                    "requestID": decision.requestID.uuidString.lowercased(),
                    "revision": decision.revision
                ]
                content.interruptionLevel = preferences.focusAware ? .passive : .active
                if policy == .deliverWithSound {
                    content.sound = .default
                }
                try? await center.add(UNNotificationRequest(
                    identifier: Self.identifier(decision),
                    content: content,
                    trigger: nil
                ))
            }
        }

        public nonisolated func userNotificationCenter(
            _: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            defer { completionHandler() }
            guard let action = MacNotificationAction(rawValue: response.actionIdentifier),
                  let request = response.notification.request.content.userInfo["requestID"] as? String,
                  let requestID = UUID(uuidString: request)
            else { return }
            let rawRevision = response.notification.request.content.userInfo["revision"]
            let revision = (rawRevision as? NSNumber)?.int64Value ?? (rawRevision as? Int64) ?? 0
            let value = MacNotificationResponse(action: action, requestID: requestID, revision: revision)
            Task { @MainActor [weak self] in self?.responseHandler?(value) }
        }

        public nonisolated func userNotificationCenter(
            _: UNUserNotificationCenter,
            willPresent _: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .list, .sound])
        }

        public static var categories: Set<UNNotificationCategory> {
            let approve = UNNotificationAction(
                identifier: MacNotificationAction.approve.rawValue,
                title: "Approve",
                options: [.authenticationRequired]
            )
            let deny = UNNotificationAction(
                identifier: MacNotificationAction.deny.rawValue,
                title: "Deny",
                options: [.authenticationRequired, .destructive]
            )
            let review = UNNotificationAction(
                identifier: MacNotificationAction.review.rawValue,
                title: "Review",
                options: [.foreground]
            )
            let terminal = UNNotificationAction(
                identifier: MacNotificationAction.openTerminal.rawValue,
                title: "Open Terminal",
                options: [.foreground]
            )
            return [
                UNNotificationCategory(
                    identifier: MacNotificationCategory.approval.rawValue,
                    actions: [approve, deny, review, terminal],
                    intentIdentifiers: []
                ),
                UNNotificationCategory(identifier: MacNotificationCategory.question.rawValue, actions: [review, terminal], intentIdentifiers: []),
                UNNotificationCategory(identifier: MacNotificationCategory.secretQuestion.rawValue, actions: [terminal], intentIdentifiers: []),
                UNNotificationCategory(identifier: MacNotificationCategory.plan.rawValue, actions: [approve, deny, review, terminal], intentIdentifiers: [])
            ]
        }

        private static func identifier(_ decision: PendingHookDecision) -> String {
            "agentcontrol.decision.\(decision.requestID.uuidString.lowercased()).\(decision.revision)"
        }

        private static func category(for decision: PendingHookDecision) -> MacNotificationCategory {
            switch decision.kind {
            case .approval: .approval
            case .plan: .plan
            case .question:
                DecisionAvailability.evaluate(decision) == .secretRequiresTerminal ? .secretQuestion : .question
            }
        }

        private static func body(for decision: PendingHookDecision) -> String {
            if DecisionAvailability.evaluate(decision) == .secretRequiresTerminal {
                return "A secret answer is required in the terminal."
            }
            return decision.prompt
        }
    }
#endif
