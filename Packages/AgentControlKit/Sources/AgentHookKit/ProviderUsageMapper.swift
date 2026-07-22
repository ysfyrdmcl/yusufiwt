#if os(macOS)
    import AgentDomain
    import AgentProtocol
    import Foundation

    /// Maps only explicit structured provider fields. It never parses terminal text or rendered provider UI.
    public struct ProviderUsageMapper: Sendable {
        private typealias IntegerMatch = (value: Int64, path: String)

        private struct ContextCounts {
            let total: IntegerMatch?
            let used: IntegerMatch?
            let remaining: IntegerMatch?
        }

        public init() {}

        public func metrics(
            provider: AdapterID,
            fields: [String: JSONValue],
            updatedAt: Date
        ) -> [SessionUsageMetric] {
            var result: [SessionUsageMetric] = []
            if let metric = quotaMetric(provider: provider, fields: fields, updatedAt: updatedAt) {
                result.append(metric)
            }
            if let metric = contextMetric(provider: provider, fields: fields, updatedAt: updatedAt) {
                result.append(metric)
            }
            if let metric = tokenMetric(provider: provider, fields: fields, updatedAt: updatedAt) {
                result.append(metric)
            }
            return result
        }

        private func quotaMetric(
            provider: AdapterID,
            fields: [String: JSONValue],
            updatedAt: Date
        ) -> SessionUsageMetric? {
            let paths = [
                ["quota", "remaining_percent"], ["quota", "remaining_percentage"],
                ["rate_limit", "remaining_percent"], ["rate_limit", "remaining_percentage"],
                ["rateLimit", "remainingPercent"], ["usage", "quota_remaining_percent"],
                ["usage", "quotaRemainingPercent"], ["quota_remaining_percent"]
            ]
            guard let match = firstNumber(in: fields, paths: paths) else { return nil }
            let isWeekly = firstString(in: fields, paths: [
                ["quota", "window"], ["rate_limit", "window"], ["rateLimit", "window"],
                ["usage", "quota_window"], ["usage", "quotaWindow"], ["quota_window"]
            ]).map { ["week", "weekly", "7d", "7_day", "7-day"].contains($0.lowercased()) } ?? false
            let reset = firstDate(in: fields, paths: [
                ["quota", "resets_at"], ["rate_limit", "resets_at"], ["rateLimit", "resetsAt"],
                ["usage", "quota_resets_at"], ["usage", "quotaResetsAt"], ["quota_resets_at"]
            ])
            return SessionUsageMetric(
                provider: provider,
                kind: .quotaRemaining,
                remainingPercent: match.value,
                precision: precision(fields),
                source: match.path,
                updatedAt: updatedAt,
                quotaWindow: isWeekly ? .weekly : nil,
                resetsAt: reset
            )
        }

        private func contextMetric(
            provider: AdapterID,
            fields: [String: JSONValue],
            updatedAt: Date
        ) -> SessionUsageMetric? {
            let counts = contextCounts(in: fields)
            let remainingPercentPaths = [
                ["context_remaining_percent"], ["context", "remaining_percent"],
                ["context_window", "remaining_percent"], ["usage", "context_remaining_percent"],
                ["usage", "contextRemainingPercent"]
            ]
            if let match = firstNumber(in: fields, paths: remainingPercentPaths) {
                return SessionUsageMetric(
                    provider: provider,
                    kind: .contextRemaining,
                    total: counts.total?.value,
                    used: counts.used?.value,
                    remaining: counts.remaining?.value,
                    remainingPercent: match.value,
                    precision: precision(fields),
                    source: contextSource(primaryPath: match.path, counts: counts),
                    updatedAt: updatedAt
                )
            }

            let usedPercentPaths = [
                ["context_usage_percent"], ["context", "usage_percent"],
                ["context_window", "usage_percent"], ["usage", "context_usage_percent"],
                ["usage", "contextUsagePercent"]
            ]
            if let match = firstNumber(in: fields, paths: usedPercentPaths) {
                return SessionUsageMetric(
                    provider: provider,
                    kind: .contextRemaining,
                    total: counts.total?.value,
                    used: counts.used?.value,
                    remaining: counts.remaining?.value,
                    remainingPercent: 100 - match.value,
                    precision: precision(fields),
                    source: contextSource(primaryPath: match.path, counts: counts),
                    updatedAt: updatedAt
                )
            }

            guard let total = counts.total, total.value > 0,
                  counts.used != nil || counts.remaining != nil
            else { return nil }
            return SessionUsageMetric(
                provider: provider,
                kind: .contextRemaining,
                total: total.value,
                used: counts.used?.value,
                remaining: counts.remaining?.value,
                precision: precision(fields),
                source: [total.path, counts.used?.path, counts.remaining?.path].compactMap(\.self).joined(separator: "+"),
                updatedAt: updatedAt
            )
        }

        private func contextSource(primaryPath: String, counts: ContextCounts) -> String {
            [primaryPath, counts.total?.path, counts.used?.path, counts.remaining?.path]
                .compactMap(\.self)
                .joined(separator: "+")
        }

        private func contextCounts(in fields: [String: JSONValue]) -> ContextCounts {
            let total = firstInteger(in: fields, paths: [
                ["context_window_size"], ["context", "total_tokens"], ["context", "total"],
                ["context_window", "total_tokens"], ["context_window", "size"],
                ["usage", "context_window", "total"], ["usage", "contextWindow", "total"]
            ])
            let used = firstInteger(in: fields, paths: [
                ["context_tokens"], ["context", "used_tokens"], ["context", "used"],
                ["context_window", "used_tokens"], ["context_window", "used"],
                ["usage", "context_window", "used"], ["usage", "contextWindow", "used"]
            ])
            let remaining = firstInteger(in: fields, paths: [
                ["context_tokens_remaining"], ["context", "remaining_tokens"],
                ["context_window", "remaining_tokens"], ["usage", "context_window", "remaining"]
            ])
            return ContextCounts(total: total, used: used, remaining: remaining)
        }

        private func tokenMetric(
            provider: AdapterID,
            fields: [String: JSONValue],
            updatedAt: Date
        ) -> SessionUsageMetric? {
            let input = firstInteger(in: fields, paths: [
                ["usage", "input_tokens"], ["usage", "inputTokens"],
                ["token_usage", "input_tokens"], ["tokenUsage", "inputTokens"],
                ["tool_response", "usage", "input_tokens"], ["tool_response", "usage", "inputTokens"],
                ["usageMetadata", "promptTokenCount"], ["llm_response", "usageMetadata", "promptTokenCount"]
            ])
            let output = firstInteger(in: fields, paths: [
                ["usage", "output_tokens"], ["usage", "outputTokens"],
                ["token_usage", "output_tokens"], ["tokenUsage", "outputTokens"],
                ["tool_response", "usage", "output_tokens"], ["tool_response", "usage", "outputTokens"],
                ["usageMetadata", "candidatesTokenCount"], ["llm_response", "usageMetadata", "candidatesTokenCount"]
            ])
            let total = firstInteger(in: fields, paths: [
                ["usage", "total_tokens"], ["usage", "totalTokens"],
                ["token_usage", "total_tokens"], ["tokenUsage", "totalTokens"],
                ["tool_response", "usage", "total_tokens"], ["tool_response", "usage", "totalTokens"],
                ["tool_response", "totalTokens"],
                ["usageMetadata", "totalTokenCount"], ["llm_response", "usageMetadata", "totalTokenCount"]
            ])
            guard input != nil || output != nil || total != nil else { return nil }
            return SessionUsageMetric(
                provider: provider,
                kind: .tokenCounts,
                total: total?.value,
                inputTokens: input?.value,
                outputTokens: output?.value,
                precision: precision(fields),
                source: [input?.path, output?.path, total?.path].compactMap(\.self).joined(separator: "+"),
                updatedAt: updatedAt
            )
        }

        private func precision(_ fields: [String: JSONValue]) -> UsageMetricPrecision {
            if fields["usage_estimated"] == .bool(true) || fields["estimated"] == .bool(true) {
                return .estimated
            }
            return .exact
        }

        private func firstNumber(
            in fields: [String: JSONValue],
            paths: [[String]]
        ) -> (value: Double, path: String)? {
            for path in paths {
                guard let value = value(in: fields, at: path), let number = number(value), number.isFinite else { continue }
                return (number, path.joined(separator: "."))
            }
            return nil
        }

        private func firstInteger(
            in fields: [String: JSONValue],
            paths: [[String]]
        ) -> IntegerMatch? {
            for path in paths {
                guard let value = value(in: fields, at: path), let integer = integer(value) else { continue }
                return (integer, path.joined(separator: "."))
            }
            return nil
        }

        private func firstString(in fields: [String: JSONValue], paths: [[String]]) -> String? {
            for path in paths {
                guard let value = value(in: fields, at: path)?.stringValue else { continue }
                return value
            }
            return nil
        }

        private func firstDate(in fields: [String: JSONValue], paths: [[String]]) -> Date? {
            for path in paths {
                guard let value = value(in: fields, at: path) else { continue }
                switch value {
                case let .string(raw):
                    if let date = ISO8601DateFormatter().date(from: raw) { return date }
                    if let seconds = Double(raw) { return Date(timeIntervalSince1970: seconds) }
                case let .number(seconds) where seconds.isFinite:
                    return Date(timeIntervalSince1970: seconds)
                default:
                    continue
                }
            }
            return nil
        }

        private func value(in fields: [String: JSONValue], at path: [String]) -> JSONValue? {
            guard let first = path.first, var value = fields[first] else { return nil }
            for component in path.dropFirst() {
                guard let nested = value[component] else { return nil }
                value = nested
            }
            return value
        }

        private func number(_ value: JSONValue) -> Double? {
            switch value {
            case let .number(number): number
            case let .string(string): Double(string)
            case .object, .array, .bool, .null: nil
            }
        }

        private func integer(_ value: JSONValue) -> Int64? {
            if case let .string(string) = value {
                return Int64(string).flatMap { $0 >= 0 ? $0 : nil }
            }
            guard let number = number(value), number.isFinite, number >= 0,
                  number.rounded() == number, number < Double(Int64.max)
            else { return nil }
            return Int64(number)
        }
    }
#endif
