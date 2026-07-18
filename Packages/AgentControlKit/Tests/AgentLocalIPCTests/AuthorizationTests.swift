import AgentLocalIPC
import Darwin
import Testing

@Suite("Local IPC authorization")
struct AuthorizationTests {
    @Test("Unix peers must have the helper user ID")
    func socketPeers() {
        let policy = SameUserPeerValidator(expectedUserID: 501)
        #expect(policy.authorize(PeerCredentials(userID: 501, groupID: 20)))
        #expect(!policy.authorize(PeerCredentials(userID: 502, groupID: 20)))
    }

    @Test("XPC requires matching user, bundle identifier, and signing team")
    func xpcClients() {
        let checker = SignatureFixture(
            values: [
                10: CodeSignatureIdentity(identifier: "com.yusuf.agentcontrol.mac", teamIdentifier: "TEAM"),
                11: CodeSignatureIdentity(identifier: "com.attacker.app", teamIdentifier: "TEAM"),
                12: CodeSignatureIdentity(identifier: "com.yusuf.agentcontrol.mac", teamIdentifier: "OTHER")
            ]
        )
        let policy = XPCClientAuthorizationPolicy(
            expectedUserID: 501,
            expectedTeamIdentifier: "TEAM",
            checker: checker
        )
        #expect(policy.authorize(XPCClientIdentity(processID: 10, userID: 501)))
        #expect(!policy.authorize(XPCClientIdentity(processID: 10, userID: 502)))
        #expect(!policy.authorize(XPCClientIdentity(processID: 11, userID: 501)))
        #expect(!policy.authorize(XPCClientIdentity(processID: 12, userID: 501)))
        #expect(!policy.authorize(XPCClientIdentity(processID: 99, userID: 501)))
    }

    @Test("Ad-hoc signatures are only accepted when explicitly enabled")
    func adHocPolicy() {
        let checker = SignatureFixture(
            values: [1: CodeSignatureIdentity(identifier: "com.yusuf.agentcontrol.mac", teamIdentifier: nil)]
        )
        let denied = XPCClientAuthorizationPolicy(expectedUserID: 501, expectedTeamIdentifier: nil, checker: checker)
        let allowed = XPCClientAuthorizationPolicy(
            expectedUserID: 501,
            expectedTeamIdentifier: nil,
            allowsAdHocSignatures: true,
            checker: checker
        )
        #expect(!denied.authorize(XPCClientIdentity(processID: 1, userID: 501)))
        #expect(allowed.authorize(XPCClientIdentity(processID: 1, userID: 501)))
    }
}

private struct SignatureFixture: CodeSignatureChecking {
    let values: [pid_t: CodeSignatureIdentity]

    func signatureIdentity(processID: pid_t) -> CodeSignatureIdentity? {
        values[processID]
    }
}
