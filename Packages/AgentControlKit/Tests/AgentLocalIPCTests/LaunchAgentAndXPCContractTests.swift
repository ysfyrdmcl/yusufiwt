import AgentDomain
@testable import AgentLocalIPC
import AgentPersistence
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

    @Test("LaunchAgent repair refreshes registration without deleting queued events")
    func repairRegistration() async throws {
        let paths = try temporaryPaths()
        try paths.prepare()
        let server = UnixSocketServer(socketURL: paths.socketURL) { _ in .neutral(reason: .helperUnavailable) }
        try server.start()
        let queuedEvent = paths.spoolDirectory.appendingPathComponent("event.json")
        try Data("queued".utf8).write(to: queuedEvent)
        let service = LaunchAgentServiceFixture(state: .enabled)
        let manager = LaunchAgentManager(service: service, paths: paths)

        #expect(try await manager.repairRegistration() == .enabled)
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(FileManager.default.fileExists(atPath: queuedEvent.path))
        #expect(await service.unregisterCount == 1)
        #expect(await service.registerCount == 1)
        server.stop()
    }

    @Test("XPC secure wrapper round trips current and legacy negotiation contracts")
    func secureCodingWrapper() throws {
        let current = LocalIPCContract.current
        let message = try XPCMessage(request: .negotiateProtocol(supportedVersions: [current]))
        let archived = try NSKeyedArchiver.archivedData(withRootObject: message, requiringSecureCoding: true)
        let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: XPCMessage.self, from: archived)
        let restored = try #require(decoded)
        guard case let .negotiateProtocol(versions) = try restored.decodeRequest() else {
            Issue.record("Expected major/minor negotiation request")
            return
        }
        #expect(versions == [current])

        let response = try XPCMessage(response: .protocolNegotiated(version: current))
        let responseData = try NSKeyedArchiver.archivedData(withRootObject: response, requiringSecureCoding: true)
        let responseObject = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: XPCMessage.self,
            from: responseData
        )
        let decodedResponse = try #require(responseObject)
        guard case let .protocolNegotiated(version) = try decodedResponse.decodeResponse() else {
            Issue.record("Expected major/minor negotiation response")
            return
        }
        #expect(version == current)

        let legacy = try XPCMessage(request: .negotiate(supportedVersions: [current.major]))
        guard case let .negotiate(legacyVersions) = try legacy.decodeRequest() else {
            Issue.record("Expected legacy negotiation request")
            return
        }
        #expect(legacyVersions == [current.major])
        #expect(throws: LocalIPCError.oversizedFrame(LocalIPCContract.maximumFrameSize + 1)) {
            try XPCMessage(data: Data(repeating: 0, count: LocalIPCContract.maximumFrameSize + 1))
        }
    }

    @Test("Missing minor version decodes as major zero-minor compatibility")
    func legacyMinorDefault() throws {
        let decoded = try JSONDecoder().decode(
            LocalIPCVersion.self,
            from: Data(#"{"major":1}"#.utf8)
        )
        #expect(decoded == LocalIPCVersion(major: 1, minor: 0))
        #expect(LocalIPCContract.currentMajorVersion == LocalIPCContract.current.major)
        #expect(LocalIPCContract.currentMinorVersion == LocalIPCContract.current.minor)
        #expect(LocalIPCContract.currentVersion == LocalIPCContract.currentMajorVersion)
    }

    @Test("Usage read models round trip securely and legacy JSON defaults to unavailable")
    func secureUsageCodingAndLegacyDefault() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let metric = SessionUsageMetric(
            provider: AdapterID("codex"), kind: .quotaRemaining,
            remainingPercent: 73, source: "fixture", updatedAt: date
        )
        let item = SessionListItem(
            id: SessionID(UUID()), projectName: "Fixture", adapterID: AdapterID("codex"),
            state: .running, startedAt: date, lastMeaningfulEventAt: date,
            snapshotRevision: 1, usageMetrics: [metric]
        )
        let message = try XPCMessage(response: .sessionList([item]))
        let archived = try NSKeyedArchiver.archivedData(withRootObject: message, requiringSecureCoding: true)
        let unarchived = try NSKeyedUnarchiver.unarchivedObject(ofClass: XPCMessage.self, from: archived)
        let decoded = try #require(unarchived)
        guard case let .sessionList(items) = try decoded.decodeResponse() else {
            Issue.record("Expected a session-list response")
            return
        }
        #expect(items.first?.usageMetrics == [metric])
        #expect(LocalIPCContract.current == LocalIPCVersion(major: 1, minor: 1))

        var legacyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        legacyObject.removeValue(forKey: "usageMetrics")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        #expect(try JSONDecoder().decode(SessionListItem.self, from: legacyData).usageMetrics == [])
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

    @Test("Decision lifecycle diagnostics round trip securely and legacy snapshots decode without provider labels")
    func lifecycleSecureCodingAndLegacyDefault() throws {
        let value = DecisionLifecycleSnapshot(
            requestID: UUID(),
            sessionID: SessionID(UUID()),
            revision: 2,
            kind: .approval,
            provider: "claude",
            projectName: "Fixture",
            state: .userResolvedAwaitingProviderAck,
            resolutionSource: .user,
            decision: .approve,
            expiresAt: .distantFuture,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let message = try XPCMessage(response: .decisionLifecycles([value]))
        let archived = try NSKeyedArchiver.archivedData(withRootObject: message, requiringSecureCoding: true)
        let unarchived = try NSKeyedUnarchiver.unarchivedObject(ofClass: XPCMessage.self, from: archived)
        let restored = try #require(unarchived)
        guard case let .decisionLifecycles(values) = try restored.decodeResponse() else {
            Issue.record("Expected decision lifecycle response")
            return
        }
        #expect(values == [value])

        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        legacy.removeValue(forKey: "provider")
        legacy.removeValue(forKey: "projectName")
        let decoded = try JSONDecoder().decode(
            DecisionLifecycleSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.provider == nil)
        #expect(decoded.projectName == nil)
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
    private var storedRegisterCount = 0

    init(state: LaunchAgentState) {
        storedState = state
    }

    var state: LaunchAgentState {
        lock.withLock { storedState }
    }

    var unregisterCount: Int {
        get async { lock.withLock { storedUnregisterCount } }
    }

    var registerCount: Int {
        get async { lock.withLock { storedRegisterCount } }
    }

    func register() throws {
        lock.withLock {
            storedRegisterCount += 1
            storedState = .enabled
        }
    }

    func unregister() async throws {
        lock.withLock {
            storedUnregisterCount += 1
            storedState = .notRegistered
        }
    }
}
