import AgentDomain
import Foundation

public struct EventSource: Codable, Sendable, Equatable {
    public let adapterID: AdapterID
    public let adapterVersion: String
    public let nodeID: NodeID
    public let processID: Int32?

    public init(adapterID: AdapterID, adapterVersion: String, nodeID: NodeID, processID: Int32? = nil) {
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.nodeID = nodeID
        self.processID = processID
    }
}

public enum ProtocolContractError: Error, Sendable, Equatable {
    case encodedSizeExceeded
    case invalidTimestamp
}

public struct EventEnvelope: Codable, Sendable, Equatable {
    public static let currentProtocolVersion = 1
    public static let maximumEncodedSize = 1_048_576

    public let protocolVersion: Int
    public let eventID: EventID
    public let eventType: String
    public let source: EventSource
    public let sessionID: SessionID
    public let providerSessionID: String?
    public let sequence: Int64
    public let occurredAt: Date
    public let receivedAt: Date
    public let payload: JSONValue
    public let privacyClass: PrivacyClass
    public let correlationID: EnvelopeID
    public let schemaHash: String

    public init(
        protocolVersion: Int = EventEnvelope.currentProtocolVersion,
        eventID: EventID,
        eventType: String,
        source: EventSource,
        sessionID: SessionID,
        providerSessionID: String? = nil,
        sequence: Int64,
        occurredAt: Date,
        receivedAt: Date,
        payload: JSONValue,
        privacyClass: PrivacyClass,
        correlationID: EnvelopeID,
        schemaHash: String
    ) {
        self.protocolVersion = protocolVersion
        self.eventID = eventID
        self.eventType = eventType
        self.source = source
        self.sessionID = sessionID
        self.providerSessionID = providerSessionID
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.receivedAt = receivedAt
        self.payload = payload
        self.privacyClass = privacyClass
        self.correlationID = correlationID
        self.schemaHash = schemaHash
    }

    public static func decodeBounded(_ data: Data) throws -> EventEnvelope {
        guard data.count <= maximumEncodedSize else { throw ProtocolContractError.encodedSizeExceeded }
        return try JSONDecoder().decode(EventEnvelope.self, from: data)
    }

    public var domainEvent: AgentEvent {
        switch eventType {
        case "session.stateChanged":
            guard let stateName = payload["state"]?.stringValue,
                  let state = SessionState(rawValue: stateName)
            else { return .unknown(type: eventType) }
            return .stateChanged(state)
        case "approval.requested":
            guard let request = decodePayload(ApprovalRequest.self) else { return .unknown(type: eventType) }
            return .approvalRequested(request)
        case "approval.statusChanged":
            guard let change = decodePayload(ApprovalStatusChange.self) else { return .unknown(type: eventType) }
            return .approvalStatusChanged(id: change.id, status: change.status)
        case "question.requested":
            guard let question = decodePayload(AgentQuestion.self) else { return .unknown(type: eventType) }
            return .questionRequested(question)
        case "question.resolved":
            guard let resolution = decodePayload(QuestionResolution.self) else { return .unknown(type: eventType) }
            return .questionResolved(resolution.id)
        case "session.usageUpdated":
            guard let update = decodePayload(SessionUsageUpdate.self) else { return .unknown(type: eventType) }
            return .usageUpdated(update)
        case "provider.resumed":
            return .providerResumed
        default:
            return .unknown(type: eventType)
        }
    }

    private func decodePayload<Value: Decodable>(_ type: Value.Type) -> Value? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, eventID, eventType, source, sessionID, providerSessionID, sequence
        case occurredAt, receivedAt, payload, privacyClass, correlationID, schemaHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        eventID = try container.decode(EventID.self, forKey: .eventID)
        eventType = try container.decode(String.self, forKey: .eventType)
        source = try container.decode(EventSource.self, forKey: .source)
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        providerSessionID = try container.decodeIfPresent(String.self, forKey: .providerSessionID)
        sequence = try container.decode(Int64.self, forKey: .sequence)
        occurredAt = try Self.decodeDate(container.decode(String.self, forKey: .occurredAt))
        receivedAt = try Self.decodeDate(container.decode(String.self, forKey: .receivedAt))
        payload = try container.decode(JSONValue.self, forKey: .payload)
        privacyClass = try container.decode(PrivacyClass.self, forKey: .privacyClass)
        correlationID = try container.decode(EnvelopeID.self, forKey: .correlationID)
        schemaHash = try container.decode(String.self, forKey: .schemaHash)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(eventType, forKey: .eventType)
        try container.encode(source, forKey: .source)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(providerSessionID, forKey: .providerSessionID)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(Self.encodeDate(occurredAt), forKey: .occurredAt)
        try container.encode(Self.encodeDate(receivedAt), forKey: .receivedAt)
        try container.encode(payload, forKey: .payload)
        try container.encode(privacyClass, forKey: .privacyClass)
        try container.encode(correlationID, forKey: .correlationID)
        try container.encode(schemaHash, forKey: .schemaHash)
    }

    private static func decodeDate(_ value: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else { throw ProtocolContractError.invalidTimestamp }
        return date
    }

    private static func encodeDate(_ value: Date) -> String {
        ISO8601DateFormatter().string(from: value)
    }
}

private struct ApprovalStatusChange: Codable {
    let id: ApprovalRequestID
    let status: ApprovalStatus
}

private struct QuestionResolution: Codable {
    let id: QuestionID
}
