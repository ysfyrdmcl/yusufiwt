import AgentDomain
import AgentProtocol
import Foundation

struct StoredEnvelopeMetadata: Codable {
    let protocolVersion: Int
    let eventID: EventID
    let eventType: String
    let source: EventSource
    let sessionID: SessionID
    let providerSessionID: String?
    let sequence: Int64
    let occurredAt: Date
    let receivedAt: Date
    let privacyClass: PrivacyClass
    let correlationID: EnvelopeID
    let schemaHash: String

    init(_ envelope: EventEnvelope) {
        protocolVersion = envelope.protocolVersion
        eventID = envelope.eventID
        eventType = envelope.eventType
        source = envelope.source
        sessionID = envelope.sessionID
        providerSessionID = envelope.providerSessionID
        sequence = envelope.sequence
        occurredAt = envelope.occurredAt
        receivedAt = envelope.receivedAt
        privacyClass = envelope.privacyClass
        correlationID = envelope.correlationID
        schemaHash = envelope.schemaHash
    }

    func envelope(payload: JSONValue) -> EventEnvelope {
        EventEnvelope(
            protocolVersion: protocolVersion, eventID: eventID, eventType: eventType,
            source: source, sessionID: sessionID, providerSessionID: providerSessionID,
            sequence: sequence, occurredAt: occurredAt, receivedAt: receivedAt,
            payload: payload, privacyClass: privacyClass, correlationID: correlationID, schemaHash: schemaHash
        )
    }
}
