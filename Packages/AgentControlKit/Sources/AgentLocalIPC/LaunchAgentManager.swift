#if os(macOS)
    import Darwin
    import Foundation
    import Security
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
        private let localPlist: URL?
        private let helperURL: URL

        public init(plistName: String = "com.yusuf.agentcontrol.helper.plist") {
            service = SMAppService.agent(plistName: plistName)
            helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AgentControlHelper")
            var code: SecStaticCode?
            var information: CFDictionary?
            let signatureFlags: UInt32 = if SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
                                            let code, SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
                                            let dictionary = information as? [String: Any],
                                            let flags = dictionary[kSecCodeInfoFlags as String] as? NSNumber {
                flags.uint32Value
            } else {
                0
            }
            localPlist = signatureFlags & 0x0002 != 0
                ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(plistName)")
                : nil
        }

        public var state: LaunchAgentState {
            if let localPlist {
                return FileManager.default.fileExists(atPath: localPlist.path) ? .enabled : .notRegistered
            }
            return switch service.status {
            case .notRegistered: .notRegistered
            case .enabled: .enabled
            case .requiresApproval: .requiresApproval
            case .notFound: .notFound
            @unknown default: .notFound
            }
        }

        public func register() throws {
            guard let localPlist else { try service.register(); return }
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw LocalIPCError.unavailable }
            let directory = localPlist.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(localPlist.lastPathComponent)")
            guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundled), format: nil) as? [String: Any]
            else { throw LocalIPCError.malformedPayload }
            plist.removeValue(forKey: "BundleProgram")
            plist["ProgramArguments"] = [helperURL.path]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: localPlist, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localPlist.path)
            _ = try launchctl(["bootout", "gui/\(getuid())/com.yusuf.agentcontrol.helper"])
            guard try launchctl(["bootstrap", "gui/\(getuid())", localPlist.path]) == 0 else { throw LocalIPCError.unavailable }
        }

        public func unregister() async throws {
            guard let localPlist else { try await service.unregister(); return }
            _ = try launchctl(["bootout", "gui/\(getuid())/com.yusuf.agentcontrol.helper"])
            if FileManager.default.fileExists(atPath: localPlist.path) {
                try FileManager.default.removeItem(at: localPlist)
            }
        }

        private func launchctl(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
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

        /// Refreshes the ServiceManagement registration after an in-place app upgrade.
        /// Pending hook spool files are deliberately preserved.
        public func repairRegistration() async throws -> LaunchAgentState {
            if service.state != .notRegistered, service.state != .notFound {
                try await service.unregister()
            }
            try removeOwnedSocketIfPresent()
            try service.register()
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
