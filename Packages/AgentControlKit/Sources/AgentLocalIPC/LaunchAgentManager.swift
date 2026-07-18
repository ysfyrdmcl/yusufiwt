#if os(macOS)
    import Darwin
    import Foundation
    import ServiceManagement

    public enum LaunchAgentState: String, Sendable, Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
    }

    public protocol LaunchAgentServicing: Sendable {
        var state: LaunchAgentState { get }
        func register() throws
        func unregister() async throws
    }

    public final class SystemLaunchAgentService: LaunchAgentServicing, @unchecked Sendable {
        private let service: SMAppService

        public init(plistName: String = "com.yusuf.agentcontrol.helper.plist") {
            service = SMAppService.agent(plistName: plistName)
        }

        public var state: LaunchAgentState {
            switch service.status {
            case .notRegistered: .notRegistered
            case .enabled: .enabled
            case .requiresApproval: .requiresApproval
            case .notFound: .notFound
            @unknown default: .notFound
            }
        }

        public func register() throws {
            try service.register()
        }

        public func unregister() async throws {
            try await service.unregister()
        }
    }

    public actor LaunchAgentManager {
        private let service: any LaunchAgentServicing
        private let paths: AgentControlPaths

        public init(service: any LaunchAgentServicing = SystemLaunchAgentService(), paths: AgentControlPaths) {
            self.service = service
            self.paths = paths
        }

        public func status() -> LaunchAgentState {
            service.state
        }

        public func register() throws -> LaunchAgentState {
            try service.register()
            return service.state
        }

        public func unregister() async throws -> LaunchAgentState {
            if service.state != .notRegistered, service.state != .notFound {
                try await service.unregister()
            }
            try removeOwnedSocketIfPresent()
            try? FileManager.default.removeItem(at: paths.handoffURL)
            try removeOwnedSpoolIfPresent()
            return service.state
        }

        private func removeOwnedSocketIfPresent() throws {
            var info = stat()
            guard lstat(paths.socketURL.path, &info) == 0 else { return }
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                throw LocalIPCError.unsafeSocketPath
            }
            guard Darwin.unlink(paths.socketURL.path) == 0 else { throw LocalIPCError.socketFailure(code: errno) }
        }

        private func removeOwnedSpoolIfPresent() throws {
            var info = stat()
            guard lstat(paths.spoolDirectory.path, &info) == 0 else { return }
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
                  info.st_mode & (S_IRWXG | S_IRWXO) == 0
            else { throw LocalIPCError.unsafeSocketPath }
            try FileManager.default.removeItem(at: paths.spoolDirectory)
        }
    }
#endif
