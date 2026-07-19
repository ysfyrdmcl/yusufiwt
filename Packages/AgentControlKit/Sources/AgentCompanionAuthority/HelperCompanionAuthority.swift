#if os(macOS)
    import AgentCompanion
    import AgentDomain
    import Foundation

    /// The helper-owned bridge is the only companion component allowed to invoke a provider.
    /// Network delivery and device receipt never produce an applied acknowledgment.
    public actor HelperCompanionAuthority {
        private let authority: LocalMacDecisionAuthority
        private let provider: any ProviderDecisionApplying

        public init(localMacIdentity: CompanionIdentity, provider: any ProviderDecisionApplying) throws {
            guard localMacIdentity.role == .localMac else { throw CompanionCryptoError.policyRejected }
            authority = try LocalMacDecisionAuthority(macIdentity: localMacIdentity)
            self.provider = provider
        }

        // Keep the helper boundary explicit; each value participates in authority validation.
        // swiftlint:disable:next function_parameter_count
        public func apply(
            envelope: SealedRelayEnvelope,
            companionRole: CompanionDeviceRole,
            companionSigningPublicKey: Data,
            companionAgreementPublicKey: Data,
            context: CompanionDecisionContext,
            now: Date
        ) async throws -> ProviderAcknowledgmentPayload {
            try await authority.validateAndApply(
                envelope,
                senderRole: companionRole,
                senderSigningPublicKey: companionSigningPublicKey,
                senderAgreementPublicKey: companionAgreementPublicKey,
                context: context,
                provider: provider,
                now: now
            )
        }
    }
#endif
