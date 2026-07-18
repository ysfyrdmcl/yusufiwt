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

/// Shipping features that can be rolled out or disabled without introducing a
/// development bypass. Emergency disables always win over rollout enables.
public enum ProductFeature: String, Codable, CaseIterable, Sendable, Hashable {
    case managedCodex = "managed_codex"
    case providerHooks = "provider_hooks"
    case companionRelay = "companion_relay"
    case companionRemoteDecisions = "companion_remote_decisions"
    case pushNotifications = "push_notifications"
    case liveActivities = "live_activities"
    case widgets
    case watchCompanion = "watch_companion"
    case automaticUpdates = "automatic_updates"
    case redactedDiagnosticFeedback = "redacted_diagnostic_feedback"
}

public enum ReleaseProfile: String, Codable, CaseIterable, Sendable {
    case internalAlpha = "internal_alpha"
    case beta
    case stable
}

public enum ReleaseFeatureConfigurationError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case missingDependency(feature: ProductFeature, dependency: ProductFeature)
}

public struct ReleaseFeatureConfiguration: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let profile: ReleaseProfile
    public let enabled: Set<ProductFeature>
    public let emergencyDisabled: Set<ProductFeature>

    public init(
        schemaVersion: Int = 1,
        profile: ReleaseProfile,
        enabled: Set<ProductFeature>,
        emergencyDisabled: Set<ProductFeature> = []
    ) {
        self.schemaVersion = schemaVersion
        self.profile = profile
        self.enabled = enabled
        self.emergencyDisabled = emergencyDisabled
    }

    public static let internalAlpha = ReleaseFeatureConfiguration(
        profile: .internalAlpha,
        enabled: Set(ProductFeature.allCases)
    )

    public func isEnabled(_ feature: ProductFeature) -> Bool {
        enabled.contains(feature) && !emergencyDisabled.contains(feature)
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw ReleaseFeatureConfigurationError.unsupportedSchemaVersion(schemaVersion)
        }
        let dependencies: [ProductFeature: Set<ProductFeature>] = [
            .companionRemoteDecisions: [.companionRelay],
            .pushNotifications: [.companionRelay],
            .liveActivities: [.companionRelay, .pushNotifications],
            .widgets: [.companionRelay],
            .watchCompanion: [.companionRelay]
        ]
        for feature in ProductFeature.allCases where enabled.contains(feature) {
            for dependency in dependencies[feature, default: []] where !enabled.contains(dependency) {
                throw ReleaseFeatureConfigurationError.missingDependency(
                    feature: feature,
                    dependency: dependency
                )
            }
        }
    }
}
