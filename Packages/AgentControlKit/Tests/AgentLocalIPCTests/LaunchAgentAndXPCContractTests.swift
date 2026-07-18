@testable import AgentLocalIPC
import Darwin
import Foundation
import Testing

@Suite("LaunchAgent and XPC contracts", .serialized)
struct LaunchAgentAndXPCContractTests {
    @Test("LaunchAgent registration reports the resulting service state")
    func registration() async throws {
        let paths = try temporaryPaths()
        let service = LaunchAgentServiceFixture(state: .notRegistered)
        let manager = LaunchAgentManager(service: service, paths: paths)
        #expect(try await manager.register() == .enabled)
        #expect(await manager.status() == .enabled)
    }

    @Test("LaunchAgent unregister is idempotent and cleans owned transient files")
    func uninstall() async throws {
        let paths = try temporaryPaths()
        try paths.prepare()
        let server = UnixSocketServer(socketURL: paths.socketURL) { _ in .neutral(reason: .helperUnavailable) }
        try server.start()
        let service = LaunchAgentServiceFixture(state: .enabled)
        let manager = LaunchAgentManager(service: service, paths: paths)
        try Data("queued".utf8).write(to: paths.spoolDirectory.appendingPathComponent("event.json"))
        try Data("handoff".utf8).write(to: paths.handoffURL)

        #expect(try await manager.unregister() == .notRegistered)
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(!FileManager.default.fileExists(atPath: paths.spoolDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: paths.handoffURL.path))
        #expect(await service.unregisterCount == 1)
        #expect(try await manager.unregister() == .notRegistered)
        #expect(await service.unregisterCount == 1)
        server.stop()
    }

    @Test("XPC secure wrapper rejects oversized data and round trips requests")
    func secureCodingWrapper() throws {
        let message = try XPCMessage(request: .negotiate(supportedVersions: [1]))
        let archived = try NSKeyedArchiver.archivedData(withRootObject: message, requiringSecureCoding: true)
        let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: XPCMessage.self, from: archived)
        let restored = try #require(decoded)
        guard case let .negotiate(versions) = try restored.decodeRequest() else {
            Issue.record("Expected negotiation request")
            return
        }
        #expect(versions == [1])
        #expect(throws: LocalIPCError.oversizedFrame(LocalIPCContract.maximumFrameSize + 1)) {
            try XPCMessage(data: Data(repeating: 0, count: LocalIPCContract.maximumFrameSize + 1))
        }
    }

    @Test("Reconnect delay is exponential and capped")
    func reconnectBackoff() {
        let backoff = ReconnectBackoff(initialNanoseconds: 10, maximumNanoseconds: 50, multiplier: 2)
        #expect(backoff.delayNanoseconds(forAttempt: 0) == 0)
        #expect(backoff.delayNanoseconds(forAttempt: 1) == 10)
        #expect(backoff.delayNanoseconds(forAttempt: 2) == 20)
        #expect(backoff.delayNanoseconds(forAttempt: 3) == 40)
        #expect(backoff.delayNanoseconds(forAttempt: 4) == 50)
    }

    @Test("Callback gate permits exactly one continuation resume")
    func callbackSingleResume() {
        let gate = OneShotGate()
        #expect(gate.claim())
        #expect(!gate.claim())
        #expect(!gate.claim())
    }
}

private final class LaunchAgentServiceFixture: LaunchAgentServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedState: LaunchAgentState
    private var storedUnregisterCount = 0

    init(state: LaunchAgentState) {
        storedState = state
    }

    var state: LaunchAgentState {
        lock.withLock { storedState }
    }

    var unregisterCount: Int {
        get async { lock.withLock { storedUnregisterCount } }
    }

    func register() throws {
        lock.withLock { storedState = .enabled }
    }

    func unregister() async throws {
        lock.withLock {
            storedUnregisterCount += 1
            storedState = .notRegistered
        }
    }
}
