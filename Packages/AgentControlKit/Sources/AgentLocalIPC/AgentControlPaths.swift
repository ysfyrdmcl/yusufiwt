#if os(macOS)
    import Darwin
    import Foundation

    public struct AgentControlPaths: Sendable, Equatable {
        public let baseDirectory: URL
        public let databaseURL: URL
        public let socketURL: URL
        public let spoolDirectory: URL
        public let handoffURL: URL

        public init(baseDirectory: URL) {
            self.baseDirectory = baseDirectory
            databaseURL = baseDirectory.appendingPathComponent("agent-control.sqlite")
            socketURL = baseDirectory.appendingPathComponent("ipc/helper.sock")
            spoolDirectory = baseDirectory.appendingPathComponent("spool", isDirectory: true)
            handoffURL = baseDirectory.appendingPathComponent("update-handoff.json")
        }

        public static func userDefault(fileManager: FileManager = .default) throws -> AgentControlPaths {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("AgentControl", isDirectory: true)
            if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.yusuf.agentcontrol") {
                let groupBase = group.appendingPathComponent("Library/Application Support/AgentControl", isDirectory: true)
                let groupPaths = AgentControlPaths(baseDirectory: groupBase)
                let address = sockaddr_un()
                if groupPaths.socketURL.path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) {
                    return groupPaths
                }
            }
            return AgentControlPaths(baseDirectory: appSupport)
        }

        public func prepare(fileManager: FileManager = .default) throws {
            for directory in [baseDirectory, socketURL.deletingLastPathComponent(), spoolDirectory] {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                guard chmod(directory.path, S_IRWXU) == 0 else { throw LocalIPCError.socketFailure(code: errno) }
                var info = stat()
                guard lstat(directory.path, &info) == 0,
                      info.st_uid == getuid(),
                      info.st_mode & S_IFMT == S_IFDIR,
                      info.st_mode & (S_IRWXG | S_IRWXO) == 0
                else { throw LocalIPCError.unsafeSocketPath }
            }
        }
    }
#endif
