#if os(macOS)
    import AgentLocalIPC
    import Foundation

    public struct QuietHours: Codable, Sendable, Equatable {
        public let startMinute: Int
        public let endMinute: Int

        public init(startMinute: Int, endMinute: Int) {
            self.startMinute = min(max(startMinute, 0), 1439)
            self.endMinute = min(max(endMinute, 0), 1439)
        }

        public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
            guard startMinute != endMinute else { return false }
            let components = calendar.dateComponents([.hour, .minute], from: date)
            let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            if startMinute < endMinute {
                return minute >= startMinute && minute < endMinute
            }
            return minute >= startMinute || minute < endMinute
        }
    }

    public struct MacNotificationPreferences: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var soundEnabled: Bool
        public var decisionNotificationsEnabled: Bool
        public var approvalNotificationsEnabled: Bool
        public var questionPlanNotificationsEnabled: Bool
        public var completedNotificationsEnabled: Bool
        public var failedNotificationsEnabled: Bool
        public var longRunningIdleNotificationsEnabled: Bool
        public var focusAware: Bool
        public var quietHours: QuietHours?
        public var privacyLevel: NotificationPrivacyLevel

        public init(
            enabled: Bool = true,
            soundEnabled: Bool = true,
            decisionNotificationsEnabled: Bool = true,
            approvalNotificationsEnabled: Bool? = nil,
            questionPlanNotificationsEnabled: Bool? = nil,
            completedNotificationsEnabled: Bool = true,
            failedNotificationsEnabled: Bool = true,
            longRunningIdleNotificationsEnabled: Bool = true,
            focusAware: Bool = true,
            quietHours: QuietHours? = nil,
            privacyLevel: NotificationPrivacyLevel = .generic
        ) {
            self.enabled = enabled
            self.soundEnabled = soundEnabled
            self.decisionNotificationsEnabled = decisionNotificationsEnabled
            self.approvalNotificationsEnabled = approvalNotificationsEnabled ?? decisionNotificationsEnabled
            self.questionPlanNotificationsEnabled = questionPlanNotificationsEnabled ?? decisionNotificationsEnabled
            self.completedNotificationsEnabled = completedNotificationsEnabled
            self.failedNotificationsEnabled = failedNotificationsEnabled
            self.longRunningIdleNotificationsEnabled = longRunningIdleNotificationsEnabled
            self.focusAware = focusAware
            self.quietHours = quietHours
            self.privacyLevel = privacyLevel
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, soundEnabled, decisionNotificationsEnabled
            case approvalNotificationsEnabled, questionPlanNotificationsEnabled
            case completedNotificationsEnabled, failedNotificationsEnabled
            case longRunningIdleNotificationsEnabled, focusAware, quietHours, privacyLevel
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            soundEnabled = try values.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
            let legacyDecisions = try values.decodeIfPresent(Bool.self, forKey: .decisionNotificationsEnabled) ?? true
            decisionNotificationsEnabled = legacyDecisions
            approvalNotificationsEnabled = try values.decodeIfPresent(
                Bool.self, forKey: .approvalNotificationsEnabled
            ) ?? legacyDecisions
            questionPlanNotificationsEnabled = try values.decodeIfPresent(
                Bool.self, forKey: .questionPlanNotificationsEnabled
            ) ?? legacyDecisions
            completedNotificationsEnabled = try values.decodeIfPresent(
                Bool.self, forKey: .completedNotificationsEnabled
            ) ?? true
            failedNotificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .failedNotificationsEnabled) ?? true
            longRunningIdleNotificationsEnabled = try values.decodeIfPresent(
                Bool.self, forKey: .longRunningIdleNotificationsEnabled
            ) ?? true
            focusAware = try values.decodeIfPresent(Bool.self, forKey: .focusAware) ?? true
            quietHours = try values.decodeIfPresent(QuietHours.self, forKey: .quietHours)
            privacyLevel = try values.decodeIfPresent(NotificationPrivacyLevel.self, forKey: .privacyLevel) ?? .generic
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(enabled, forKey: .enabled)
            try values.encode(soundEnabled, forKey: .soundEnabled)
            try values.encode(decisionNotificationsEnabled, forKey: .decisionNotificationsEnabled)
            try values.encode(approvalNotificationsEnabled, forKey: .approvalNotificationsEnabled)
            try values.encode(questionPlanNotificationsEnabled, forKey: .questionPlanNotificationsEnabled)
            try values.encode(completedNotificationsEnabled, forKey: .completedNotificationsEnabled)
            try values.encode(failedNotificationsEnabled, forKey: .failedNotificationsEnabled)
            try values.encode(longRunningIdleNotificationsEnabled, forKey: .longRunningIdleNotificationsEnabled)
            try values.encode(focusAware, forKey: .focusAware)
            try values.encodeIfPresent(quietHours, forKey: .quietHours)
            try values.encode(privacyLevel, forKey: .privacyLevel)
        }

        public func decisionsEnabled(for kind: HookDecisionKind) -> Bool {
            switch kind {
            case .approval: approvalNotificationsEnabled
            case .question, .plan: questionPlanNotificationsEnabled
            }
        }
    }

    public enum NotificationPrivacyLevel: String, Codable, CaseIterable, Sendable, Equatable {
        case generic
        case projectAndEvent
    }

    public final class MacNotificationPreferencesStore: @unchecked Sendable {
        private let defaults: UserDefaults
        private let key: String

        public init(defaults: UserDefaults = .standard, key: String = "mac-local.notification-preferences") {
            self.defaults = defaults
            self.key = key
        }

        public func load() -> MacNotificationPreferences {
            guard let data = defaults.data(forKey: key),
                  let value = try? JSONDecoder().decode(MacNotificationPreferences.self, from: data)
            else { return MacNotificationPreferences() }
            return value
        }

        public func save(_ value: MacNotificationPreferences) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            defaults.set(data, forKey: key)
        }
    }

    public enum NotificationDeliveryPolicy: Sendable, Equatable {
        case suppress
        case deliverSilently
        case deliverWithSound
    }

    public enum MacNotificationPolicy {
        public static func delivery(
            preferences: MacNotificationPreferences,
            at date: Date = Date(),
            calendar: Calendar = .current
        ) -> NotificationDeliveryPolicy {
            guard preferences.enabled else { return .suppress }
            if preferences.quietHours?.contains(date, calendar: calendar) == true {
                return .deliverSilently
            }
            return preferences.soundEnabled ? .deliverWithSound : .deliverSilently
        }
    }

    public struct NotificationDeduplicator: Sendable {
        private var delivered: Set<String> = []

        public init() {}

        public mutating func shouldDeliver(_ decision: PendingHookDecision) -> Bool {
            delivered.insert(Self.key(decision)).inserted
        }

        public mutating func reconcile(active decisions: [PendingHookDecision]) {
            let active = Set(decisions.map(Self.key))
            delivered.formIntersection(active)
        }

        private static func key(_ decision: PendingHookDecision) -> String {
            "\(decision.requestID.uuidString.lowercased()):\(decision.revision):\(decision.kind.rawValue)"
        }
    }
#endif
