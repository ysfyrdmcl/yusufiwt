import AgentDomain
import Foundation
import Testing

@Suite("Strong identifiers and domain models")
struct StrongIDAndModelTests {
    @Test("Every strong identifier round trips through Codable")
    func identifierRoundTrip() throws {
        let uuid = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let original = SessionID(uuid)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SessionID.self, from: data) == original)
    }

    @Test("Capability matrix exposes only declared behavior")
    func capabilityMatrix() {
        let matrix = CapabilityMatrix(supported: [.monitorSessions, .answerQuestions])
        #expect(matrix.supports(.monitorSessions))
        #expect(!matrix.supports(.approveRequests))
    }

    @Test("System abstractions can be replaced deterministically")
    func deterministicProviders() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let uuid = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(FixedAgentClock(now: date, monotonicNanoseconds: 42).now == date)
        #expect(FixedUUIDProvider(uuid).makeUUID() == uuid)
    }
}
