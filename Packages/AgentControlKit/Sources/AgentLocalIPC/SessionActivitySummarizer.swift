#if os(macOS)
    import AgentDomain
    import AgentProtocol
    import Foundation

    public struct SessionActivitySummarizer: Sendable {
        public init() {}

        public func summary(for envelope: EventEnvelope) -> SessionActivitySummary {
            let kind: SessionActivitySummary.Kind = switch envelope.eventType {
            case "approval.requested", "plan.reviewRequested": .waitingApproval
            case "question.requested": .waitingInput
            case "plan.started", "plan.updated", "turn.planUpdated": .planning
            case "tool.started", "tool.completed", "tool.use", "tool.called": .usingTool
            case "file.read", "file.search", "workspace.scan": .inspectingFiles
            case "session.completed", "turn.completed": .completed
            case "session.failed", "turn.failed": .failed
            case "session.cancelled", "turn.cancelled", "turn.interrupted": .stopped
            case "session.stateChanged": stateKind(envelope.payload["state"]?.stringValue)
            default: inferredKind(from: envelope.eventType)
            }
            return SessionActivitySummary(
                kind: kind,
                detail: safeDetail(from: envelope),
                updatedAt: envelope.receivedAt
            )
        }

        private func stateKind(_ rawValue: String?) -> SessionActivitySummary.Kind {
            switch rawValue.flatMap(SessionState.init(rawValue:)) {
            case .waitingApproval: .waitingApproval
            case .waitingInput: .waitingInput
            case .completed: .completed
            case .failed: .failed
            case .cancelled: .stopped
            case .thinking: .planning
            default: .working
            }
        }

        private func inferredKind(from eventType: String) -> SessionActivitySummary.Kind {
            let lowered = eventType.lowercased()
            if lowered.contains("plan") {
                return .planning
            }
            if lowered.contains("file") || lowered.contains("search") {
                return .inspectingFiles
            }
            if lowered.contains("tool") || lowered.contains("command") {
                return .usingTool
            }
            return .working
        }

        private func safeDetail(from envelope: EventEnvelope) -> String? {
            guard envelope.privacyClass == .publicMetadata else { return nil }
            for key in ["safe_summary", "tool_name", "toolName", "action"] {
                guard let raw = envelope.payload[key]?.stringValue else { continue }
                let value = raw
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                return String(value.prefix(80))
            }
            return nil
        }
    }
#endif
