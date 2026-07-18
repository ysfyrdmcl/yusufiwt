import AgentDomain
import AgentProtocol
import Foundation
import Testing

@Suite("Versioned event envelope")
struct EventEnvelopeTests {
    @Test("Known fixture decodes and re-encodes")
    func knownFixture() throws {
        let data = try fixture("event-envelope-v1")
        let envelope = try EventEnvelope.decodeBounded(data)
        #expect(envelope.protocolVersion == 1)
        #expect(envelope.eventType == "session.stateChanged")
        #expect(envelope.privacyClass == .privateMetadata)
        #expect(try JSONEncoder().encode(envelope).isEmpty == false)
    }

    @Test("Unknown fields and event types are forward tolerant")
    func forwardTolerance() throws {
        let envelope = try EventEnvelope.decodeBounded(fixture("event-envelope-future"))
        #expect(envelope.domainEvent == .unknown(type: "future.providerEvent"))
    }

    @Test("Oversized payloads are rejected")
    func sizeLimit() {
        let data = Data(repeating: 0x20, count: EventEnvelope.maximumEncodedSize + 1)
        #expect(throws: ProtocolContractError.encodedSizeExceeded) {
            try EventEnvelope.decodeBounded(data)
        }
    }

    @Test("Envelope initializer and protocol negotiation are stable")
    func initializerAndNegotiation() throws {
        let envelope = EventEnvelope(
            eventID: EventID(UUID()),
            eventType: "session.stateChanged",
            source: EventSource(adapterID: AdapterID("codex"), adapterVersion: "1", nodeID: NodeID(UUID())),
            sessionID: SessionID(UUID()),
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_001),
            payload: .object(["state": .string("running")]),
            privacyClass: .privateMetadata,
            correlationID: EnvelopeID(UUID()),
            schemaHash: "sha256:test"
        )
        #expect(envelope.domainEvent == .stateChanged(.running))
        #expect(WireProtocolVersion.supports(1))
        #expect(!WireProtocolVersion.supports(2))
        #expect(try EventEnvelope.decodeBounded(JSONEncoder().encode(envelope)) == envelope)
    }

    @Test("JSON value supports every JSON shape")
    func jsonShapes() throws {
        let value = JSONValue.object([
            "array": .array([.string("value"), .number(2), .bool(true), .null])
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
        #expect(JSONValue.array([])["missing"] == nil)
        #expect(JSONValue.bool(false).stringValue == nil)
    }

    @Test("Invalid timestamps fail with a typed protocol error")
    func invalidTimestamp() throws {
        let text = try #require(String(data: fixture("event-envelope-v1"), encoding: .utf8))
            .replacingOccurrences(of: "2026-07-17T12:00:00Z", with: "invalid")
        #expect(throws: ProtocolContractError.invalidTimestamp) {
            try EventEnvelope.decodeBounded(Data(text.utf8))
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
