import AgentDomain
import BuildSupport
import Testing

@Suite("Debug feature flag contract")
struct FeatureFlagPolicyTests {
    @Test("Debug accepts explicitly requested overrides")
    func debugOverrides() {
        let policy = FeatureFlagPolicy(environment: .debug)
        #expect(policy.effectiveDebugOverrides(["fake-agent"]) == ["fake-agent"])
    }

    @Test("Staging and production reject debug overrides", arguments: [
        BuildEnvironment.staging,
        BuildEnvironment.production,
    ])
    func nonDebugOverrides(environment: BuildEnvironment) {
        let policy = FeatureFlagPolicy(environment: environment)
        #expect(policy.effectiveDebugOverrides(["fake-agent", "insecure-localhost"]).isEmpty)
    }

    @Test("Domain remains available without a platform framework")
    func domainContract() {
        #expect(AgentDomainModule.contractVersion == 1)
    }
}
