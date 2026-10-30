@testable import AgentLocalIPC
import Foundation
import Testing

struct CodexAccountUsageReaderTests {
    @Test("Weekly account usage accepts either window and rejects other quotas")
    func weeklyWindow() {
        let now = Date()
        let weekly: [String: Any] = ["usedPercent": 73.0, "windowDurationMins": 10080, "resetsAt": 1_800_000_000.0]
        let short: [String: Any] = ["usedPercent": 10.0, "windowDurationMins": 300]
        for slot in ["primary", "secondary"] {
            let metric = CodexAccountUsageReader.weeklyMetric(from: ["rateLimitsByLimitId": ["codex": [slot: weekly]]], at: now)
            #expect(metric?.remainingPercent == 27)
            #expect(metric?.updatedAt == now)
        }
        #expect(CodexAccountUsageReader.weeklyMetric(from: ["rateLimits": ["primary": short]], at: now) == nil)
    }
}
