import Foundation

public protocol AgentIdentifier: Codable, Hashable, Sendable, CustomStringConvertible {
    var rawValue: UUID { get }
    init(_ rawValue: UUID)
}

public extension AgentIdentifier {
    var description: String {
        rawValue.uuidString.lowercased()
    }

    init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(UUID.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct NodeID: AgentIdentifier { public let rawValue: UUID; public init(_ rawValue: UUID) {
    self.rawValue = rawValue
} }
public struct ProjectID: AgentIdentifier { public let rawValue: UUID; public init(_ rawValue: UUID) {
    self.rawValue = rawValue
} }
public struct SessionID: AgentIdentifier { public let rawValue: UUID; public init(_ rawValue: UUID) {
    self.rawValue = rawValue
} }
public struct TurnID: AgentIdentifier { public let rawValue: UUID; public init(_ rawValue: UUID) {
    self.rawValue = rawValue
} }
public struct ToolRunID: AgentIdentifier { public let rawValue: UUID; public init(_ rawValue: UUID) {
    self.rawValue = rawValue
} }
public struct ApprovalRequestID: AgentIdentifier { public let rawValue: UUID; public init(_ rawValue: UUID) {
    self.rawValue = rawValue
} }
public struct QuestionID: AgentIdentifier { public let rawValue: UUID; public init(_ rawValue: UUID) {
    self.rawValue = rawValue
} }
public struct DeviceID: AgentIdentifier { public let rawValue: UUID; public init(_ rawValue: UUID) {
    self.rawValue = rawValue
} }
public struct EnvelopeID: AgentIdentifier { public let rawValue: UUID; public init(_ rawValue: UUID) {
    self.rawValue = rawValue
} }
public struct EventID: AgentIdentifier { public let rawValue: UUID; public init(_ rawValue: UUID) {
    self.rawValue = rawValue
} }

public struct AdapterID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
