import AgentLocalIPC
import Darwin
import Foundation
import Testing

@Suite("Unix socket integration", .serialized)
struct UnixSocketIntegrationTests {
    @Test("Same-user client reaches helper and socket mode is 0600")
    func roundTripAndMode() async throws {
        let paths = try temporaryPaths()
        let stack = try await makeTestRuntime(paths: paths)
        let server = UnixSocketServer(socketURL: paths.socketURL) { request in await stack.runtime.handle(request) }
        try server.start()
        await stack.runtime.setSocketAcceptingConnections(true)
        defer { server.stop() }

        let client = UnixSocketClient(socketURL: paths.socketURL)
        let response = try client.send(.heartbeat)
        guard case let .heartbeat(heartbeat) = response else {
            Issue.record("Expected heartbeat response")
            return
        }
        #expect(heartbeat.sequence == 1)
        var info = stat()
        #expect(lstat(paths.socketURL.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        await stack.runtime.gracefulShutdown()
    }

    @Test("Burst requests are accepted with bounded serialized backpressure")
    func burst() async throws {
        let paths = try temporaryPaths()
        let stack = try await makeTestRuntime(paths: paths)
        let server = UnixSocketServer(socketURL: paths.socketURL) { request in await stack.runtime.handle(request) }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketClient(socketURL: paths.socketURL)

        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 100 {
                group.addTask {
                    guard case .health = try await client.sendAsync(.health, timeoutMilliseconds: 15000) else { return false }
                    return true
                }
            }
            var successes = 0
            for try await result in group where result {
                successes += 1
            }
            #expect(successes == 100)
        }
        await stack.runtime.gracefulShutdown()
    }

    @Test("Unavailable helper returns neutral fallback instead of approval")
    func neutralFallback() throws {
        let client = try UnixSocketClient(socketURL: temporaryPaths().socketURL)
        #expect(client.sendOrNeutral(.heartbeat).neutralReason == .helperUnavailable)
    }
}

private extension HelperResponse {
    var neutralReason: NeutralFallbackReason? {
        if case let .neutral(reason) = self {
            return reason
        }
        return nil
    }
}
