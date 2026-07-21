#if os(macOS)
    import AgentDomain
    import AgentPersistence
    import Foundation

    public struct SessionUsagePresentation: Sendable, Equatable {
        public let kind: SessionUsageMetricKind?
        public let titleKey: String
        public let value: String
        public let sourceLabel: String?
        public let helpKey: String
        public let isAvailable: Bool
        public let isStale: Bool

        public init(
            session: SessionListItem?,
            at referenceDate: Date,
            staleAfter: TimeInterval = SessionUsageMetric.defaultStaleAfter
        ) {
            guard let session,
                  let metric = Self.preferredMetric(
                      session.usageMetrics,
                      at: referenceDate,
                      staleAfter: staleAfter
                  ),
                  let value = Self.value(metric)
            else {
                kind = nil
                titleKey = "notch.tokens"
                value = "—"
                sourceLabel = session.map { Self.sourceLabel($0) }
                helpKey = "usage.providerUnavailable"
                isAvailable = false
                isStale = false
                return
            }

            kind = metric.kind
            titleKey = switch metric.kind {
            case .quotaRemaining: "usage.quotaRemaining"
            case .contextRemaining: "usage.contextRemaining"
            case .tokenCounts: "usage.tokenCounts"
            }
            self.value = value
            sourceLabel = Self.sourceLabel(session)
            isAvailable = true
            isStale = metric.isStale(at: referenceDate, staleAfter: staleAfter)
            helpKey = isStale ? "usage.stale" : titleKey
        }

        private static func preferredMetric(
            _ metrics: [SessionUsageMetric],
            at referenceDate: Date,
            staleAfter: TimeInterval
        ) -> SessionUsageMetric? {
            let usable = metrics.filter { value($0) != nil }
            let fresh = usable.filter { !$0.isStale(at: referenceDate, staleAfter: staleAfter) }
            return preferred(in: fresh) ?? preferred(in: usable)
        }

        private static func preferred(in metrics: [SessionUsageMetric]) -> SessionUsageMetric? {
            for kind in [
                SessionUsageMetricKind.quotaRemaining,
                .contextRemaining,
                .tokenCounts
            ] {
                if let metric = metrics.filter({ $0.kind == kind }).max(by: { $0.updatedAt < $1.updatedAt }) {
                    return metric
                }
            }
            return nil
        }

        private static func value(_ metric: SessionUsageMetric) -> String? {
            switch metric.kind {
            case .quotaRemaining, .contextRemaining:
                return metric.remainingPercent.map { "\($0)%" }
            case .tokenCounts:
                if let input = metric.inputTokens, let output = metric.outputTokens {
                    return "\(input)↓ · \(output)↑"
                }
                if let total = metric.total {
                    return "\(total)"
                }
                if let input = metric.inputTokens {
                    return "\(input)↓"
                }
                if let output = metric.outputTokens {
                    return "\(output)↑"
                }
                return nil
            }
        }

        private static func sourceLabel(_ session: SessionListItem) -> String {
            "\(session.adapterID.rawValue.capitalized) · \(session.projectName)"
        }
    }
#endif
