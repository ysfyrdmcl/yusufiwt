#if os(macOS)
    // Notification contracts and their coordinator stay colocated for native category review.
    // swiftlint:disable file_length
    import AgentDomain
    import AgentLocalIPC
    import Foundation
    @preconcurrency import UserNotifications

    public enum MacNotificationCategory: String, Sendable {
        case approval = "AGENTCONTROL_APPROVAL"
        case approvalReviewOnly = "AGENTCONTROL_APPROVAL_REVIEW_ONLY"
        case question = "AGENTCONTROL_QUESTION"
        case secretQuestion = "AGENTCONTROL_SECRET_QUESTION"
        case plan = "AGENTCONTROL_PLAN"
        case planReviewOnly = "AGENTCONTROL_PLAN_REVIEW_ONLY"
        case alert = "AGENTCONTROL_ALERT"
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
        public let kind: HookDecisionKind?
        public let sessionID: SessionID?

        public init(
            action: MacNotificationAction,
            requestID: UUID,
            revision: Int64,
            kind: HookDecisionKind? = nil,
            sessionID: SessionID? = nil
        ) {
            self.action = action
            self.requestID = requestID
            self.revision = revision
            self.kind = kind
            self.sessionID = sessionID
        }
    }

    public enum NotificationAuthorizationState: Sendable, Equatable {
        case unknown
        case authorized
        case denied
    }

    @MainActor
    public protocol MacNotificationCentering: AnyObject {
        var delegate: (any UNUserNotificationCenterDelegate)? { get set }
        func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
        func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
        func pendingNotificationRequests() async -> [UNNotificationRequest]
        func deliveredNotificationIdentifiers() async -> [String]
        func add(_ request: UNNotificationRequest) async throws
        func removePendingNotificationRequests(withIdentifiers identifiers: [String])
        func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    }

    @MainActor
    private final class SystemMacNotificationCenter: MacNotificationCentering {
        private let center: UNUserNotificationCenter

        init(center: UNUserNotificationCenter = .current()) {
            self.center = center
        }

        var delegate: (any UNUserNotificationCenterDelegate)? {
            get { center.delegate }
            set { center.delegate = newValue }
        }

        func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
            center.setNotificationCategories(categories)
        }

        func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
            try await center.requestAuthorization(options: options)
        }

        func pendingNotificationRequests() async -> [UNNotificationRequest] {
            await center.pendingNotificationRequests()
        }

        func deliveredNotificationIdentifiers() async -> [String] {
            await center.deliveredNotifications().map(\.request.identifier)
        }

        func add(_ request: UNNotificationRequest) async throws {
            try await center.add(request)
        }

        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }

        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    @MainActor
    // Notification scheduling, response routing, and reconciliation share one actor-isolated owner.
    // swiftlint:disable:next type_body_length
    public final class MacNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
        public var responseHandler: (@MainActor @Sendable (MacNotificationResponse) -> Void)? {
            didSet { drainPendingResponses() }
        }

        public var reviewHandler: (@MainActor @Sendable () -> Void)?
        public private(set) var authorizationState: NotificationAuthorizationState = .unknown
        public private(set) var pendingResponseCount = 0

        private let center: any MacNotificationCentering
        private var preferences: MacNotificationPreferences
        private var deduplicator = NotificationDeduplicator()
        private var deliveredAlertIDs: Set<String> = []
        private var pendingResponses: [MacNotificationResponse] = []
        private var lastDecisionSnapshot: [PendingHookDecision] = []

        public init(
            center: (any MacNotificationCentering)? = nil,
            preferences: MacNotificationPreferences = .init()
        ) {
            self.center = center ?? SystemMacNotificationCenter()
            self.preferences = preferences
            super.init()
            installDelegateAndCategories()
        }

        public func installDelegateAndCategories() {
            center.delegate = self
            center.setNotificationCategories(Self.categories)
        }

        public func configure() async {
            // Delegate/category registration must precede both authorization and
            // scheduling, including launches caused by a notification response.
            installDelegateAndCategories()
            do {
                authorizationState = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                    ? .authorized
                    : .denied
            } catch {
                authorizationState = .denied
            }
            if authorizationState == .authorized {
                deduplicator = NotificationDeduplicator()
                await reconcile(lastDecisionSnapshot)
            }
        }

        public func updatePreferences(_ value: MacNotificationPreferences) async {
            preferences = value
            // Replacing an already scheduled request with the same stable identifier
            // is how sound/privacy changes take effect without creating duplicates.
            deduplicator = NotificationDeduplicator()
            await reconcile(lastDecisionSnapshot)
        }

        public func setUsesNotchSurface(_: Bool) {
            // Retained for source compatibility. The notch is a presentation
            // surface, not authority to disable notification preferences.
        }

        public func reconcile(_ decisions: [PendingHookDecision], now: Date = Date()) async {
            lastDecisionSnapshot = decisions
            let active = decisions.filter {
                DecisionAvailability.evaluate($0, now: now) != .expired
                    && preferences.enabled
                    && preferences.decisionsEnabled(for: $0.kind)
            }
            deduplicator.reconcile(active: active)
            let activeIdentifiers = Set(active.map(Self.identifier))
            await removeStaleDecisionNotifications(activeIdentifiers: activeIdentifiers)

            guard authorizationState == .authorized else { return }
            for decision in active {
                guard deduplicator.shouldDeliver(decision) else { continue }
                let policy = MacNotificationPolicy.delivery(preferences: preferences, at: now)
                guard policy != .suppress else { continue }
                let content = UNMutableNotificationContent()
                content.title = preferences.privacyLevel == .projectAndEvent
                    ? decision.projectName ?? String(localized: "notification.title")
                    : String(localized: "notification.title")
                content.body = Self.body(for: decision, privacyLevel: preferences.privacyLevel)
                content.categoryIdentifier = Self.category(for: decision).rawValue
                content.threadIdentifier = decision.sessionID.description
                content.userInfo = Self.routeInfo(for: decision)
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

        public func remove(requestID: UUID, revision: Int64, kind: HookDecisionKind) {
            let identifier = Self.identifier(requestID: requestID, revision: revision, kind: kind)
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }

        public func reconcile(_ alerts: [SessionAlert], now: Date = Date()) async {
            guard authorizationState == .authorized,
                  preferences.longRunningIdleNotificationsEnabled
            else { return }
            let activeIDs = Set(alerts.map(\.id))
            deliveredAlertIDs.formIntersection(activeIDs)
            let policy = MacNotificationPolicy.delivery(preferences: preferences, at: now)
            guard policy != .suppress else { return }
            for alert in alerts where deliveredAlertIDs.insert(alert.id).inserted {
                let content = UNMutableNotificationContent()
                content.title = String(localized: "notification.title")
                content.body = "\(NotchPanelFormatting.alertTitle(alert.kind)): \(Int(alert.observedDurationSeconds / 60)) min"
                content.categoryIdentifier = MacNotificationCategory.alert.rawValue
                content.threadIdentifier = alert.sessionID.description
                content.interruptionLevel = preferences.focusAware ? .passive : .active
                if policy == .deliverWithSound {
                    content.sound = .default
                }
                try? await center.add(UNNotificationRequest(
                    identifier: "agentcontrol.alert.\(alert.id)", content: content, trigger: nil
                ))
            }
        }

        public func reconcile(
            _ event: RegistryNotification,
            projectName: String? = nil,
            now: Date = Date()
        ) async {
            guard authorizationState == .authorized else { return }
            let enabled: Bool
            let body: String
            switch event.state {
            case .completed:
                enabled = preferences.completedNotificationsEnabled
                body = String(localized: "notification.body.completed")
            case .failed:
                enabled = preferences.failedNotificationsEnabled
                body = String(localized: "notification.body.failed")
            case .waitingInput:
                enabled = preferences.questionPlanNotificationsEnabled
                body = String(localized: "notification.body.waitingInput")
            case .waitingApproval:
                enabled = preferences.approvalNotificationsEnabled
                body = String(localized: "notification.body.waitingApproval")
            default:
                return
            }
            guard enabled else { return }
            let policy = MacNotificationPolicy.delivery(preferences: preferences, at: now)
            guard policy != .suppress else { return }
            let content = UNMutableNotificationContent()
            content.title = preferences.privacyLevel == .projectAndEvent
                ? projectName ?? String(localized: "notification.title")
                : String(localized: "notification.title")
            content.body = body
            content.categoryIdentifier = MacNotificationCategory.alert.rawValue
            content.threadIdentifier = event.sessionID.description
            if policy == .deliverWithSound {
                content.sound = .default
            }
            try? await center.add(UNNotificationRequest(
                identifier: "agentcontrol.session.\(event.eventID.description).\(event.snapshotRevision)",
                content: content,
                trigger: nil
            ))
        }

        public func receive(_ response: MacNotificationResponse) {
            guard let responseHandler else {
                pendingResponses.append(response)
                pendingResponseCount = pendingResponses.count
                return
            }
            responseHandler(response)
        }

        public nonisolated func userNotificationCenter(
            _: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            defer { completionHandler() }
            let route = Self.response(
                userInfo: response.notification.request.content.userInfo,
                actionIdentifier: response.actionIdentifier
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let route {
                    receive(route)
                } else {
                    reviewHandler?()
                }
            }
        }

        public nonisolated func userNotificationCenter(
            _: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            var options: UNNotificationPresentationOptions = [.banner, .list]
            if notification.request.content.sound != nil {
                options.insert(.sound)
            }
            completionHandler(options)
        }

        public nonisolated static func response(
            userInfo: [AnyHashable: Any],
            actionIdentifier: String
        ) -> MacNotificationResponse? {
            let action: MacNotificationAction
            if actionIdentifier == UNNotificationDefaultActionIdentifier {
                action = .review
            } else if let explicit = MacNotificationAction(rawValue: actionIdentifier) {
                action = explicit
            } else {
                return nil
            }
            guard let rawRequestID = userInfo["requestID"] as? String,
                  let requestID = UUID(uuidString: rawRequestID)
            else { return nil }
            let rawRevision = userInfo["revision"]
            let revision = (rawRevision as? NSNumber)?.int64Value ?? (rawRevision as? Int64) ?? 0
            let kind = (userInfo["kind"] as? String).flatMap(HookDecisionKind.init(rawValue:))
            let sessionID = (userInfo["sessionID"] as? String)
                .flatMap(UUID.init(uuidString:))
                .map(SessionID.init)
            return MacNotificationResponse(
                action: action,
                requestID: requestID,
                revision: revision,
                kind: kind,
                sessionID: sessionID
            )
        }

        public static var categories: Set<UNNotificationCategory> {
            let approve = UNNotificationAction(
                identifier: MacNotificationAction.approve.rawValue,
                title: String(localized: "notification.action.approve"),
                options: [.authenticationRequired]
            )
            let deny = UNNotificationAction(
                identifier: MacNotificationAction.deny.rawValue,
                title: String(localized: "notification.action.deny"),
                options: [.authenticationRequired, .destructive]
            )
            let review = UNNotificationAction(
                identifier: MacNotificationAction.review.rawValue,
                title: String(localized: "notification.action.review"),
                options: [.foreground]
            )
            let terminal = UNNotificationAction(
                identifier: MacNotificationAction.openTerminal.rawValue,
                title: String(localized: "notification.action.openTerminal"),
                options: [.foreground]
            )
            return [
                UNNotificationCategory(
                    identifier: MacNotificationCategory.approval.rawValue,
                    actions: [approve, deny, review, terminal], intentIdentifiers: []
                ),
                UNNotificationCategory(
                    identifier: MacNotificationCategory.approvalReviewOnly.rawValue,
                    actions: [review], intentIdentifiers: []
                ),
                UNNotificationCategory(
                    identifier: MacNotificationCategory.question.rawValue,
                    actions: [review, terminal], intentIdentifiers: []
                ),
                UNNotificationCategory(
                    identifier: MacNotificationCategory.secretQuestion.rawValue,
                    actions: [review], intentIdentifiers: []
                ),
                UNNotificationCategory(
                    identifier: MacNotificationCategory.plan.rawValue,
                    actions: [approve, deny, review, terminal], intentIdentifiers: []
                ),
                UNNotificationCategory(
                    identifier: MacNotificationCategory.planReviewOnly.rawValue,
                    actions: [review], intentIdentifiers: []
                ),
                UNNotificationCategory(
                    identifier: MacNotificationCategory.alert.rawValue,
                    actions: [review], intentIdentifiers: []
                )
            ]
        }

        public static func identifier(_ decision: PendingHookDecision) -> String {
            identifier(requestID: decision.requestID, revision: decision.revision, kind: decision.kind)
        }

        public static func identifier(requestID: UUID, revision: Int64, kind: HookDecisionKind) -> String {
            "agentcontrol.decision.\(kind.rawValue).\(requestID.uuidString.lowercased()).\(revision)"
        }

        public static func category(for decision: PendingHookDecision) -> MacNotificationCategory {
            let reviewOnly = (decision.approval?.risk.level ?? .low) >= .high
            return switch decision.kind {
            case .approval: reviewOnly ? .approvalReviewOnly : .approval
            case .plan: reviewOnly ? .planReviewOnly : .plan
            case .question:
                DecisionAvailability.evaluate(decision) == .secretRequiresTerminal ? .secretQuestion : .question
            }
        }

        private func drainPendingResponses() {
            guard let responseHandler, !pendingResponses.isEmpty else { return }
            let queued = pendingResponses
            pendingResponses.removeAll()
            pendingResponseCount = 0
            for response in queued {
                responseHandler(response)
            }
        }

        private func removeStaleDecisionNotifications(activeIdentifiers: Set<String>) async {
            let pending = await center.pendingNotificationRequests().map(\.identifier)
            let delivered = await center.deliveredNotificationIdentifiers()
            let stale = Set(pending + delivered).filter {
                $0.hasPrefix("agentcontrol.decision.") && !activeIdentifiers.contains($0)
            }
            guard !stale.isEmpty else { return }
            let identifiers = Array(stale)
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }

        private static func routeInfo(for decision: PendingHookDecision) -> [String: Any] {
            [
                "requestID": decision.requestID.uuidString.lowercased(),
                "sessionID": decision.sessionID.description,
                "revision": decision.revision,
                "kind": decision.kind.rawValue
            ]
        }

        private static func body(
            for decision: PendingHookDecision,
            privacyLevel _: NotificationPrivacyLevel
        ) -> String {
            if DecisionAvailability.evaluate(decision) == .secretRequiresTerminal {
                return String(localized: "notification.body.secret")
            }
            return switch decision.kind {
            case .approval: String(localized: "notification.body.approval")
            case .question: String(localized: "notification.body.question")
            case .plan: String(localized: "notification.body.plan")
            }
        }
    }
#endif
