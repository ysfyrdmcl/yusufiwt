#if os(macOS)
    import Darwin
    import Foundation
    import Security

    public struct XPCClientIdentity: Sendable, Equatable {
        public let processID: pid_t
        public let userID: uid_t

        public init(processID: pid_t, userID: uid_t) {
            self.processID = processID
            self.userID = userID
        }
    }

    public struct CodeSignatureIdentity: Sendable, Equatable {
        public let identifier: String
        public let teamIdentifier: String?

        public init(identifier: String, teamIdentifier: String?) {
            self.identifier = identifier
            self.teamIdentifier = teamIdentifier
        }
    }

    public protocol CodeSignatureChecking: Sendable {
        func signatureIdentity(processID: pid_t) -> CodeSignatureIdentity?
    }

    public struct SecurityCodeSignatureChecker: CodeSignatureChecking {
        public init() {}

        public func signatureIdentity(processID: pid_t) -> CodeSignatureIdentity? {
            let attributes = [kSecGuestAttributePid: processID] as CFDictionary
            var code: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
                  let code
            else { return nil }
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
                  let staticCode
            else { return nil }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let values = information as? [CFString: Any],
                  let identifier = values[kSecCodeInfoIdentifier] as? String
            else { return nil }
            return CodeSignatureIdentity(
                identifier: identifier,
                teamIdentifier: values[kSecCodeInfoTeamIdentifier] as? String
            )
        }
    }

    public struct XPCClientAuthorizationPolicy: Sendable {
        public let expectedUserID: uid_t
        public let allowedIdentifiers: Set<String>
        public let expectedTeamIdentifier: String?
        public let allowsAdHocSignatures: Bool
        private let checker: any CodeSignatureChecking

        public init(
            expectedUserID: uid_t = getuid(),
            allowedIdentifiers: Set<String> = ["com.yusuf.agentcontrol.mac"],
            expectedTeamIdentifier: String?,
            allowsAdHocSignatures: Bool = false,
            checker: any CodeSignatureChecking = SecurityCodeSignatureChecker()
        ) {
            self.expectedUserID = expectedUserID
            self.allowedIdentifiers = allowedIdentifiers
            self.expectedTeamIdentifier = expectedTeamIdentifier
            self.allowsAdHocSignatures = allowsAdHocSignatures
            self.checker = checker
        }

        public func authorize(_ identity: XPCClientIdentity) -> Bool {
            guard identity.userID == expectedUserID,
                  let signature = checker.signatureIdentity(processID: identity.processID),
                  allowedIdentifiers.contains(signature.identifier)
            else { return false }
            if let expectedTeamIdentifier {
                return signature.teamIdentifier == expectedTeamIdentifier
            }
            return allowsAdHocSignatures && signature.teamIdentifier == nil
        }

        public static func forCurrentHelper(allowsAdHocSignatures: Bool) -> XPCClientAuthorizationPolicy {
            let current = SecurityCodeSignatureChecker().signatureIdentity(processID: getpid())
            return XPCClientAuthorizationPolicy(
                expectedTeamIdentifier: current?.teamIdentifier,
                allowsAdHocSignatures: allowsAdHocSignatures
            )
        }
    }
#endif
