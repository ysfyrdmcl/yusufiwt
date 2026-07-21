import AgentDomain
import AgentHookKit
import AgentLocalIPC
import AgentPersistence
import AgentProtocol
import Foundation
import Testing

@Suite("Structured provider usage mapping")
struct UsageMappingTests {
    private let updatedAt = Date(timeIntervalSince1970: 1_784_454_400)

    @Test("Explicit quota remaining stays separate from token counters")
    func structuredQuotaUsage() throws {
        let metrics = try mappedMetrics(fixture: "structured-quota-usage", provider: "generic")
        #expect(metrics.first(where: { $0.kind == .quotaRemaining })?.remainingPercent == 73)
        let counts = try #require(metrics.first(where: { $0.kind == .tokenCounts }))
        #expect(counts.inputTokens == 1200)
        #expect(counts.outputTokens == 300)
        #expect(counts.remainingPercent == nil)
    }

    @Test("Structured context total and used produce context remaining")
    func structuredContextUsage() throws {
        let metrics = try mappedMetrics(fixture: "structured-context-usage", provider: "generic")
        let context = try #require(metrics.first(where: { $0.kind == .contextRemaining }))
        #expect(context.total == 1000)
        #expect(context.used == 250)
        #expect(context.remaining == 750)
        #expect(context.remainingPercent == 75)
    }

    @Test("Codex remains unavailable when its hook does not provide structured usage")
    func unavailableProviderUsage() throws {
        #expect(try mappedMetrics(fixture: "codex-stop", provider: "codex").isEmpty)
    }

    @Test("Claude PostToolUse maps its structured tool response counters")
    func claudePostToolUsage() throws {
        let metrics = try mappedMetrics(fixture: "claude-post-tool-usage", provider: "claude")
        let counts = try #require(metrics.first(where: { $0.kind == .tokenCounts }))
        #expect(counts.inputTokens == 700)
        #expect(counts.outputTokens == 200)
        #expect(counts.total == 900)
        #expect(counts.remainingPercent == nil)
    }

    @Test("Gemini usage metadata remains token counts without a fabricated percentage")
    func geminiUsage() throws {
        let metrics = try mappedMetrics(fixture: "gemini-usage", provider: "gemini")
        let counts = try #require(metrics.first(where: { $0.kind == .tokenCounts }))
        #expect(counts.inputTokens == 400)
        #expect(counts.outputTokens == 80)
        #expect(counts.total == 480)
        #expect(counts.remainingPercent == nil)
        #expect(metrics.allSatisfy { $0.kind == .tokenCounts })
    }

    @Test("Malformed and overflowing counters are ignored safely")
    func invalidCounters() {
        let fields: [String: JSONValue] = [
            "hook_event_name": .string("AfterModel"),
            "context_window_size": .number(0),
            "context_tokens": .number(25),
            "usage": .object([
                "input_tokens": .number(-1),
                "output_tokens": .number(Double.greatestFiniteMagnitude)
            ])
        ]
        #expect(ProviderUsageMapper().metrics(
            provider: AdapterID("generic"), fields: fields, updatedAt: updatedAt
        ).isEmpty)
    }

    @Test("Cursor-style context usage percentage maps to remaining context")
    func contextUsagePercent() {
        let metrics = ProviderUsageMapper().metrics(
            provider: AdapterID("cursor"),
            fields: [
                "context_usage_percent": .number(27),
                "context_tokens": .number(270),
                "context_window_size": .number(1000)
            ],
            updatedAt: updatedAt
        )
        #expect(metrics.first(where: { $0.kind == .contextRemaining })?.remainingPercent == 73)
    }

    @Test("Cursor preCompact fixture maps to context remaining")
    func cursorPreCompact() throws {
        let mapping = try ProviderHookMapper().map(
            provider: .cursor,
            input: loadFixture("cursor-pre-compact"),
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "3.7.12"],
            now: updatedAt
        )
        guard case let .usageUpdated(update) = mapping.submission.envelope.domainEvent else {
            Issue.record("Expected Cursor context usage")
            return
        }
        let context = try #require(update.metrics.first(where: { $0.kind == .contextRemaining }))
        #expect(context.total == 1000)
        #expect(context.used == 250)
        #expect(context.remaining == 750)
        #expect(context.remainingPercent == 75)
        #expect(update.concurrentState == .running)
    }

    @Test("Provider mapper usage reaches the helper-owned persisted session snapshot")
    func persistedMappingPipeline() async throws {
        let input = try loadFixture("gemini-usage")
        let mapping = try ProviderHookMapper().map(
            provider: .gemini,
            input: input,
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0"],
            now: updatedAt
        )
        guard case let .usageUpdated(update) = mapping.submission.envelope.domainEvent else {
            Issue.record("Expected a normalized usage update")
            return
        }
        #expect(update.metrics.first?.kind == .tokenCounts)

        let database = try DatabaseActor(configuration: .inMemory)
        let registry = SessionRegistryActor(database: database)
        #expect(try await registry.ingest(mapping.submission) == .appended)
        let item = try #require(try await database.sessions().first)
        #expect(item.usageMetrics.first?.total == 480)
        #expect(try await database.session(id: item.id)?.usageMetrics.first?.remainingPercent == nil)
        await database.close()
    }

    @Test("Mapped out-of-order usage does not overwrite or append an older snapshot")
    func mappedUsageOrdering() async throws {
        let mapper = ProviderHookMapper()
        let database = try DatabaseActor(configuration: .inMemory)
        let registry = SessionRegistryActor(database: database)
        let newer = try mapper.map(
            provider: .generic,
            input: quotaInput(sequence: 2, remainingPercent: 73),
            environment: [:],
            now: updatedAt
        )
        let older = try mapper.map(
            provider: .generic,
            input: quotaInput(sequence: 1, remainingPercent: 12),
            environment: [:],
            now: updatedAt.addingTimeInterval(1)
        )
        #expect(try await registry.ingest(newer.submission) == .appended)
        #expect(try await registry.ingest(older.submission) == .duplicate)
        #expect(try await database.eventCount() == 1)
        #expect(try await database.session(
            id: newer.submission.envelope.sessionID
        )?.usageMetrics.first?.remainingPercent == 73)
        await database.close()
    }

    private func mappedMetrics(fixture: String, provider: String) throws -> [SessionUsageMetric] {
        let value = try loadFixture(fixture)
        guard case let .object(fields) = value else {
            Issue.record("Usage fixture must be an object")
            return []
        }
        return ProviderUsageMapper().metrics(
            provider: AdapterID(provider), fields: fields, updatedAt: updatedAt
        )
    }

    private func loadFixture(_ name: String) throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    private func quotaInput(sequence: Int64, remainingPercent: Double) -> JSONValue {
        .object([
            "session_id": .string("ordered-usage-session"),
            "cwd": .string("/private/tmp/work"),
            "hook_event_name": .string("Status"),
            "sequence": .number(Double(sequence)),
            "rate_limit": .object(["remaining_percent": .number(remainingPercent)])
        ])
    }
}
