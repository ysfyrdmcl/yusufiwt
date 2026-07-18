import Foundation

public protocol AgentClock: Sendable {
    var now: Date { get }
    var monotonicNanoseconds: UInt64 { get }
}

public struct SystemAgentClock: AgentClock {
    public init() {}
    public var now: Date {
        Date()
    }

    public var monotonicNanoseconds: UInt64 {
        UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    }
}

public struct FixedAgentClock: AgentClock {
    public let now: Date
    public let monotonicNanoseconds: UInt64
    public init(now: Date, monotonicNanoseconds: UInt64) {
        self.now = now
        self.monotonicNanoseconds = monotonicNanoseconds
    }
}

public protocol UUIDProviding: Sendable { func makeUUID() -> UUID }

public struct SystemUUIDProvider: UUIDProviding {
    public init() {}
    public func makeUUID() -> UUID {
        UUID()
    }
}

public struct FixedUUIDProvider: UUIDProviding {
    private let value: UUID
    public init(_ value: UUID) {
        self.value = value
    }

    public func makeUUID() -> UUID {
        value
    }
}
