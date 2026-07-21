#if os(macOS)
    import AgentDomain
    import Foundation

    public enum NotchPanelFormatting {
        private static let stateKeys: [SessionState: String] = [
            .discovered: "status.discovered",
            .starting: "status.discovered",
            .thinking: "status.thinking",
            .executing: "status.executing",
            .running: "status.running",
            .waitingApproval: "status.waitingApproval",
            .waitingInput: "status.waitingInput",
            .paused: "status.paused",
            .completed: "status.completed",
            .failed: "status.failed",
            .cancelled: "status.cancelled",
            .disconnected: "status.offline",
            .stale: "status.offline"
        ]

        public static func elapsed(from start: Date, to end: Date) -> String {
            let seconds = max(0, Int(end.timeIntervalSince(start)))
            if seconds < 60 {
                return "<1m"
            }
            let minutes = seconds / 60
            if minutes < 60 {
                return "\(minutes)m"
            }
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            if hours < 24 {
                return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
            }
            let days = hours / 24
            let remainingHours = hours % 24
            return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
        }

        public static func stateTitleKey(_ state: SessionState) -> String {
            stateKeys[state] ?? "status.offline"
        }

        public static func alertTitle(_ kind: SessionAlertKind) -> String {
            switch kind {
            case .longRunning: String(localized: "alert.kind.longRunning")
            case .idle: String(localized: "alert.kind.idle")
            case .stale: String(localized: "alert.kind.stale")
            case .waitingApproval: String(localized: "alert.kind.waitingApproval")
            case .waitingInput: String(localized: "alert.kind.waitingInput")
            }
        }

        public static func automationTitle(_ kind: AutomationActionKind) -> String {
            switch kind {
            case .readFile: String(localized: "automation.kind.readFile")
            case .readOnlyTool: String(localized: "automation.kind.readOnlyTool")
            }
        }
    }
#endif
