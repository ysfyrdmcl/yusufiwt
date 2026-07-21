import Foundation

public enum SessionUsageMetricKind: String, Codable, CaseIterable, Sendable, Hashable {
    case quotaRemaining
    case contextRemaining
    case tokenCounts
}

public enum UsageMetricPrecision: String, Codable, Sendable, Hashable {
    case exact
    case estimated
}

public struct SessionUsageUpdate: Codable, Sendable, Equatable {
    public let metrics: [SessionUsageMetric]
    public let concurrentState: SessionState?

    public init(metrics: [SessionUsageMetric], concurrentState: SessionState? = nil) {
        self.metrics = metrics
        self.concurrentState = concurrentState
    }
}

/// Provider-supplied usage data whose semantics stay explicit across every layer.
/// Token counts never imply an account quota or a context-window percentage.
public struct SessionUsageMetric: Codable, Sendable, Hashable {
    public static let defaultStaleAfter: TimeInterval = 5 * 60

    public let provider: AdapterID
    public let kind: SessionUsageMetricKind
    public let total: Int64?
    public let used: Int64?
    public let remaining: Int64?
    public let inputTokens: Int64?
    public let outputTokens: Int64?
    public let remainingPercent: Int?
    public let precision: UsageMetricPrecision
    public let source: String
    public let updatedAt: Date

    public init(
        provider: AdapterID,
        kind: SessionUsageMetricKind,
        total: Int64? = nil,
        used: Int64? = nil,
        remaining: Int64? = nil,
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        remainingPercent: Double? = nil,
        precision: UsageMetricPrecision = .exact,
        source: String,
        updatedAt: Date
    ) {
        self.provider = provider
        self.kind = kind
        self.total = Self.nonnegative(total)
        self.used = Self.nonnegative(used)
        self.inputTokens = Self.nonnegative(inputTokens)
        self.outputTokens = Self.nonnegative(outputTokens)
        self.precision = precision
        self.source = source
        self.updatedAt = updatedAt

        let safeRemaining = Self.nonnegative(remaining)
        if kind == .contextRemaining, let total = self.total, let used = self.used {
            self.remaining = safeRemaining ?? max(0, total - min(total, used))
        } else {
            self.remaining = safeRemaining
        }
        self.remainingPercent = Self.normalizedPercent(
            explicit: remainingPercent,
            kind: kind,
            total: self.total,
            used: self.used,
            remaining: self.remaining
        )
    }

    private enum CodingKeys: String, CodingKey {
        case provider, kind, total, used, remaining, inputTokens, outputTokens
        case remainingPercent, precision, source, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            provider: container.decode(AdapterID.self, forKey: .provider),
            kind: container.decode(SessionUsageMetricKind.self, forKey: .kind),
            total: container.decodeIfPresent(Int64.self, forKey: .total),
            used: container.decodeIfPresent(Int64.self, forKey: .used),
            remaining: container.decodeIfPresent(Int64.self, forKey: .remaining),
            inputTokens: container.decodeIfPresent(Int64.self, forKey: .inputTokens),
            outputTokens: container.decodeIfPresent(Int64.self, forKey: .outputTokens),
            remainingPercent: container.decodeIfPresent(Double.self, forKey: .remainingPercent),
            precision: container.decodeIfPresent(UsageMetricPrecision.self, forKey: .precision) ?? .exact,
            source: container.decode(String.self, forKey: .source),
            updatedAt: container.decode(Date.self, forKey: .updatedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(total, forKey: .total)
        try container.encodeIfPresent(used, forKey: .used)
        try container.encodeIfPresent(remaining, forKey: .remaining)
        try container.encodeIfPresent(inputTokens, forKey: .inputTokens)
        try container.encodeIfPresent(outputTokens, forKey: .outputTokens)
        try container.encodeIfPresent(remainingPercent, forKey: .remainingPercent)
        try container.encode(precision, forKey: .precision)
        try container.encode(source, forKey: .source)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    public func isStale(
        at referenceDate: Date,
        staleAfter: TimeInterval = SessionUsageMetric.defaultStaleAfter
    ) -> Bool {
        referenceDate.timeIntervalSince(updatedAt) > max(0, staleAfter)
    }

    private static func nonnegative(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func normalizedPercent(
        explicit: Double?,
        kind: SessionUsageMetricKind,
        total: Int64?,
        used: Int64?,
        remaining: Int64?
    ) -> Int? {
        guard kind != .tokenCounts else { return nil }
        if let explicit, explicit.isFinite {
            return Int(min(100, max(0, explicit)).rounded())
        }
        guard let total, total > 0 else { return nil }
        let remainingValue: Int64
        if let remaining {
            remainingValue = min(total, remaining)
        } else if let used {
            remainingValue = max(0, total - min(total, used))
        } else {
            return nil
        }
        let percent = Double(remainingValue) / Double(total) * 100
        return Int(min(100, max(0, percent)).rounded())
    }
}
