#if os(macOS)
    import Darwin
    import Foundation

    public struct PeerCredentials: Sendable, Equatable {
        public let userID: uid_t
        public let groupID: gid_t

        public init(userID: uid_t, groupID: gid_t) {
            self.userID = userID
            self.groupID = groupID
        }
    }

    public protocol PeerCredentialValidating: Sendable {
        func authorize(_ credentials: PeerCredentials) -> Bool
    }

    public struct SameUserPeerValidator: PeerCredentialValidating {
        public let expectedUserID: uid_t

        public init(expectedUserID: uid_t = getuid()) {
            self.expectedUserID = expectedUserID
        }

        public func authorize(_ credentials: PeerCredentials) -> Bool {
            credentials.userID == expectedUserID
        }
    }
#endif
