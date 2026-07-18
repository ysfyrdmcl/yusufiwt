import BuildSupport
import Testing

@Suite("Phase 17 release feature policy")
struct Phase17FeatureFlagTests {
    @Test("Internal alpha has an explicit, dependency-safe feature set")
    func internalAlphaDefaults() throws {
        let configuration = ReleaseFeatureConfiguration.internalAlpha

        try configuration.validate()
        #expect(configuration.profile == .internalAlpha)
        #expect(configuration.isEnabled(.managedCodex))
        #expect(configuration.isEnabled(.companionRemoteDecisions))
        #expect(configuration.isEnabled(.redactedDiagnosticFeedback))
    }

    @Test("Emergency disables always override rollout enables")
    func emergencyDisableWins() throws {
        let configuration = ReleaseFeatureConfiguration(
            profile: .beta,
            enabled: [.companionRelay, .companionRemoteDecisions, .pushNotifications],
            emergencyDisabled: [.companionRemoteDecisions, .pushNotifications]
        )

        try configuration.validate()
        #expect(configuration.isEnabled(.companionRelay))
        #expect(!configuration.isEnabled(.companionRemoteDecisions))
        #expect(!configuration.isEnabled(.pushNotifications))
    }

    @Test("Dependent features cannot be enabled without their authority")
    func dependencyValidation() {
        let configuration = ReleaseFeatureConfiguration(
            profile: .stable,
            enabled: [.companionRemoteDecisions]
        )

        #expect(throws: ReleaseFeatureConfigurationError.missingDependency(
            feature: .companionRemoteDecisions,
            dependency: .companionRelay
        )) {
            try configuration.validate()
        }
    }
}
