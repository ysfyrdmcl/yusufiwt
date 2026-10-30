#if os(macOS)
    import AgentDomain
    import Foundation

    /// Connects to the relay belonging to the desktop's actual stdio process.
    public struct CodexDesktopControl: Sendable {
        public let socketURL: URL

        public init(socketURL: URL? = nil) {
            self.socketURL = socketURL ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/yusufiwt-control/desktop.sock")
        }

        public var isAvailable: Bool {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: socketURL.path),
                  attributes[.type] as? FileAttributeType == .typeSocket,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  case .protocolNegotiated = UnixSocketClient(socketURL: socketURL).sendOrNeutral(
                      .negotiateProtocol(supportedVersions: LocalIPCContract.supportedVersions), timeoutMilliseconds: 250
                  ) else { return false }
            return true
        }

        public func interrupt(threadID: String) async throws -> Bool {
            guard let uuid = UUID(uuidString: threadID) else { throw LocalIPCError.malformedPayload }
            let result = try await UnixSocketClient(socketURL: socketURL).sendAsync(
                .interruptCodexSession(SessionID(uuid)), timeoutMilliseconds: 7000
            )
            guard case let .codexInterruptRequested(sent) = result else { throw LocalIPCError.unavailable }
            return sent
        }
    }
#endif
