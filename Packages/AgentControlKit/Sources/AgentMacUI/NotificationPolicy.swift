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
        public var focusAware: Bool
        public var quietHours: QuietHours?

        public init(
            enabled: Bool = true,
            soundEnabled: Bool = true,
            focusAware: Bool = true,
            quietHours: QuietHours? = nil
        ) {
            self.enabled = enabled
            self.soundEnabled = soundEnabled
            self.focusAware = focusAware
            self.quietHours = quietHours
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
            "\(decision.requestID.uuidString.lowercased()):\(decision.revision)"
        }
    }
#endif
