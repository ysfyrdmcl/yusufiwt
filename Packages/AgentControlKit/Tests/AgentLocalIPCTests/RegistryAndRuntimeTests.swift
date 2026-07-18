import AgentDomain
import AgentLocalIPC
import AgentPersistence
import Foundation
import Testing

@Suite("Helper registry and runtime", .serialized)
struct RegistryAndRuntimeTests {
    @Test("Event persists without an app client and duplicate is not reapplied")
    func persistenceWithoutApp() async throws {
        let paths = try temporaryPaths()
        let stack = try await makeTestRuntime(paths: paths)
        let submission = try LocalIPCFixture().submission()

        #expect(await stack.runtime.handle(.submitEvent(submission)).eventDisposition == .appended)
        #expect(await stack.runtime.handle(.submitEvent(submission)).eventDisposition == .duplicate)
        #expect(try await stack.database.eventCount() == 1)
        #expect(await stack.registry.session(id: submission.envelope.sessionID)?.state == .running)
        await stack.runtime.gracefulShutdown()
    }

    @Test("Active snapshot is restored after helper restart")
    func restartRestore() async throws {
        let paths = try temporaryPaths()
        let fixture = try LocalIPCFixture()
        let first = try await makeTestRuntime(paths: paths)
        #expect(try await first.registry.ingest(fixture.submission()) == .appended)
        try await first.database.checkpoint()
        await first.database.close()

        let secondDatabase = try DatabaseActor(configuration: DatabaseConfiguration(url: paths.databaseURL))
        let secondRegistry = SessionRegistryActor(database: secondDatabase)
        #expect(try await secondRegistry.restoreActiveSnapshots() == 1)
        #expect(await secondRegistry.session(id: fixture.sessionID)?.state == .running)
        await secondDatabase.close()
    }

    @Test("Health, heartbeat, protocol negotiation, and update handoff are typed")
    func controlEndpoints() async throws {
        let paths = try temporaryPaths()
        let stack = try await makeTestRuntime(paths: paths)
        await stack.runtime.setSocketAcceptingConnections(true)

        let health = await stack.runtime.handle(.health)
        #expect(health.healthValue?.databaseHealthy == true)
        #expect(health.healthValue?.socketAcceptingConnections == true)
        #expect(await stack.runtime.handle(.negotiate(supportedVersions: [1])).negotiatedVersion == 1)
        #expect(await stack.runtime.handle(.negotiate(supportedVersions: [99])).neutralReason == .unsupportedProtocol)
        #expect(await stack.runtime.handle(.heartbeat).heartbeatSequence == 1)
        #expect(await stack.runtime.handle(.heartbeat).heartbeatSequence == 2)

        let handoff = await stack.runtime.handle(.prepareForUpdate)
        #expect(handoff.handoffValue != nil)
        #expect(FileManager.default.fileExists(atPath: paths.handoffURL.path))
        await stack.runtime.gracefulShutdown()
    }

    @Test("Spool retries failed imports and removes successful items")
    func spoolImport() async throws {
        let paths = try temporaryPaths()
        try paths.prepare()
        let spool = HookSpool(directory: paths.spoolDirectory)
        try await spool.prepare()
        try await spool.enqueue(Data("event".utf8))

        let failed = try await spool.importPending { _ in throw LocalIPCError.malformedPayload }
        #expect(failed == SpoolImportReport(imported: 0, failed: 1, remaining: 1))
        let recorder = ImportRecorder()
        let succeeded = try await spool.importPending { data in await recorder.record(data) }
        #expect(succeeded == SpoolImportReport(imported: 1, failed: 0, remaining: 0))
        #expect(await recorder.values == [Data("event".utf8)])
    }
}

private actor ImportRecorder {
    private(set) var values: [Data] = []

    func record(_ data: Data) {
        values.append(data)
    }
}

private extension HelperResponse {
    var eventDisposition: EventAppendDisposition? {
        if case let .eventAccepted(value) = self {
            return value
        }
        return nil
    }

    var healthValue: HelperHealth? {
        if case let .health(value) = self {
            return value
        }
        return nil
    }

    var negotiatedVersion: UInt16? {
        if case let .negotiated(version) = self {
            return version
        }
        return nil
    }

    var neutralReason: NeutralFallbackReason? {
        if case let .neutral(reason) = self {
            return reason
        }
        return nil
    }

    var heartbeatSequence: UInt64? {
        if case let .heartbeat(value) = self {
            return value.sequence
        }
        return nil
    }

    var handoffValue: UpdateHandoff? {
        if case let .updateHandoff(value) = self {
            return value
        }
        return nil
    }
}
