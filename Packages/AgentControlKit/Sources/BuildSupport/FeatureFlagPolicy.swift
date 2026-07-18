import AgentDomain

/// Build environments supported by all native clients.
public enum BuildEnvironment: String, Sendable, CaseIterable {
    case debug
    case staging
    case production
}

/// Prevents development-only switches from changing staging or production behavior.
public struct FeatureFlagPolicy: Sendable {
    public let environment: BuildEnvironment

    public init(environment: BuildEnvironment) {
        self.environment = environment
    }

    public var permitsDebugOverrides: Bool {
        environment == .debug
    }

    public func effectiveDebugOverrides(_ requested: Set<String>) -> Set<String> {
        permitsDebugOverrides ? requested : []
    }
}
