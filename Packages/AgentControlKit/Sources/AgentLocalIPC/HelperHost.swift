#if os(macOS)
    import AgentPersistence
    import Foundation

    public final class HelperHost: @unchecked Sendable {
        public let runtime: HelperRuntime
        public let socketServer: UnixSocketServer
        public let xpcListener: HelperXPCListener

        private init(runtime: HelperRuntime, socketServer: UnixSocketServer, xpcListener: HelperXPCListener) {
            self.runtime = runtime
            self.socketServer = socketServer
            self.xpcListener = xpcListener
        }

        public static func make(
            paths: AgentControlPaths,
            cipher: any SensitiveFieldCipher,
            authorizationPolicy: XPCClientAuthorizationPolicy
        ) async throws -> HelperHost {
            try paths.prepare()
            let database = try DatabaseActor(configuration: DatabaseConfiguration(url: paths.databaseURL), cipher: cipher)
            let registry = SessionRegistryActor(database: database)
            _ = try await registry.restoreActiveSnapshots()
            let spool = HookSpool(directory: paths.spoolDirectory)
            try await spool.prepare()
            let runtime = HelperRuntime(database: database, registry: registry, spool: spool, paths: paths)
            let socket = UnixSocketServer(socketURL: paths.socketURL) { [runtime] request in
                await runtime.handle(request)
            }
            let xpc = HelperXPCListener(runtime: runtime, authorizationPolicy: authorizationPolicy)
            return HelperHost(runtime: runtime, socketServer: socket, xpcListener: xpc)
        }

        public func start() async throws {
            _ = try await runtime.importSpool()
            try socketServer.start()
            await runtime.setSocketAcceptingConnections(true)
            xpcListener.start()
        }

        public func stop() async {
            xpcListener.stop()
            socketServer.stop()
            await runtime.gracefulShutdown()
        }
    }
#endif
