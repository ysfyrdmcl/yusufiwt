#if os(macOS)
    import AgentDomain
    import SwiftUI

    public enum AgentControlSpacing {
        public static let compact: CGFloat = 6
        public static let standard: CGFloat = 12
        public static let section: CGFloat = 20
        public static let page: CGFloat = 24
    }

    public struct SessionStatusToken {
        public let color: Color
        public let symbol: String
        public let titleKey: LocalizedStringKey

        // Exhaustive visual mapping is clearer than splitting session states across helpers.
        // swiftlint:disable:next cyclomatic_complexity
        public static func token(for state: SessionState) -> SessionStatusToken {
            switch state {
            case .waitingApproval:
                SessionStatusToken(color: .orange, symbol: "exclamationmark.shield.fill", titleKey: "status.waitingApproval")
            case .waitingInput:
                SessionStatusToken(color: .yellow, symbol: "questionmark.bubble.fill", titleKey: "status.waitingInput")
            case .failed:
                SessionStatusToken(color: .red, symbol: "xmark.octagon.fill", titleKey: "status.failed")
            case .completed:
                SessionStatusToken(color: .green, symbol: "checkmark.circle.fill", titleKey: "status.completed")
            case .cancelled:
                SessionStatusToken(color: .secondary, symbol: "slash.circle.fill", titleKey: "status.cancelled")
            case .disconnected, .stale:
                SessionStatusToken(color: .secondary, symbol: "wifi.slash", titleKey: "status.offline")
            case .starting, .thinking:
                SessionStatusToken(color: .indigo, symbol: "sparkles", titleKey: "status.thinking")
            case .executing:
                SessionStatusToken(color: .blue, symbol: "terminal.fill", titleKey: "status.executing")
            case .running:
                SessionStatusToken(color: .blue, symbol: "bolt.fill", titleKey: "status.running")
            case .paused:
                SessionStatusToken(color: .secondary, symbol: "pause.circle.fill", titleKey: "status.paused")
            case .discovered:
                SessionStatusToken(color: .secondary, symbol: "circle.dotted", titleKey: "status.discovered")
            }
        }
    }

    public struct RiskVisualToken {
        public let color: Color
        public let symbol: String
        public let titleKey: LocalizedStringKey

        public static func token(for risk: RiskLevel) -> RiskVisualToken {
            switch risk {
            case .low: RiskVisualToken(color: .green, symbol: "checkmark.shield", titleKey: "risk.low")
            case .medium: RiskVisualToken(color: .yellow, symbol: "shield.lefthalf.filled", titleKey: "risk.medium")
            case .high: RiskVisualToken(color: .orange, symbol: "exclamationmark.shield", titleKey: "risk.high")
            case .critical: RiskVisualToken(color: .red, symbol: "xmark.shield.fill", titleKey: "risk.critical")
            }
        }
    }

    public struct AgentCardModifier: ViewModifier {
        public func body(content: Content) -> some View {
            content
                .padding(AgentControlSpacing.standard)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                }
        }
    }

    public extension View {
        func agentCard() -> some View {
            modifier(AgentCardModifier())
        }
    }
#endif
