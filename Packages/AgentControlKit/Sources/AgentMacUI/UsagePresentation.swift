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
        public let resetsAt: Date?

        public init(
            session: SessionListItem?, at referenceDate: Date,
            staleAfter: TimeInterval = SessionUsageMetric.defaultStaleAfter
        ) {
            let metric = session?.usageMetrics.filter { $0.kind == .contextRemaining }
                .max { $0.updatedAt < $1.updatedAt }
            self.init(metric: metric, titleKey: "usage.contextUsed", source: nil,
                      at: referenceDate, staleAfter: staleAfter)
        }

        public init(
            accountMetric: SessionUsageMetric?, at referenceDate: Date,
            staleAfter: TimeInterval = SessionUsageMetric.defaultStaleAfter
        ) {
            let metric = accountMetric.flatMap {
                $0.provider == AdapterID("codex") && $0.kind == .quotaRemaining && $0.quotaWindow == .weekly ? $0 : nil
            }
            self.init(metric: metric, titleKey: "usage.weeklyUsed", source: "Codex",
                      at: referenceDate, staleAfter: staleAfter)
        }

        private init(metric: SessionUsageMetric?, titleKey: String, source: String?, at date: Date, staleAfter: TimeInterval) {
            kind = metric?.kind
            self.titleKey = titleKey
            value = metric?.remainingPercent.map { "\(100 - $0)%" }
                ?? String(localized: "usage.weeklyUnavailable", defaultValue: "data unavailable")
            sourceLabel = source
            isAvailable = metric?.remainingPercent != nil
            isStale = metric?.isStale(at: date, staleAfter: staleAfter) ?? false
            helpKey = isStale ? "usage.stale" : titleKey
            resetsAt = metric?.resetsAt
        }
    }
#endif
