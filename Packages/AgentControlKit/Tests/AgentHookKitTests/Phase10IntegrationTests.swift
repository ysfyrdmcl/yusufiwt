#if os(macOS)
    import AgentDomain
    import AgentHookKit
    import AgentProtocol
    import Foundation
    import Testing

    @Suite("Phase 10 integration lifecycle", .serialized)
    struct Phase10IntegrationTests {
        @Test("Terminal context is captured from explicit fields and common terminal environments")
        func terminalContextCapture() throws {
            let now = Date(timeIntervalSince1970: 1_784_320_000)
            let capture = TerminalContextCapture()
            let explicit = try #require(capture.capture(
                fields: [
                    "terminal_bundle_id": .string("com.github.wez.wezterm"),
                    "terminal_pane_id": .string("42"),
                    "cwd": .string("/private/tmp/project")
                ],
                environment: [:],
                correlationToken: "session-token",
                now: now
            ))
            #expect(explicit.applicationBundleID == "com.github.wez.wezterm")
            #expect(explicit.paneIdentifier == "42")
            #expect(explicit.workspaceURI?.path == "/private/tmp/project")
            #expect(explicit.correlationToken == "session-token")

            let inferred = try #require(capture.capture(
                fields: [:],
                environment: ["TERM_PROGRAM": "Apple_Terminal", "TERM_SESSION_ID": "ignored"],
                correlationToken: "terminal",
                now: now
            ))
            #expect(inferred.applicationBundleID == "com.apple.Terminal")
            #expect(capture.capture(fields: [:], environment: [:], correlationToken: "none", now: now) == nil)
        }

        @Test("Atomic multi-file install rolls back an earlier write when a later file is read-only")
        func atomicRollback() async throws {
            let directory = temporaryDirectory("rollback")
            let first = directory.appendingPathComponent("first.json")
            let second = directory.appendingPathComponent("second.json")
            let original = "{\"theme\":\"dark\"}\n"
            try Data(original.utf8).write(to: first)
            try Data(original.utf8).write(to: second)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: second.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: second.path) }

            let manager = IntegrationManagerActor()
            let hook = fixtureHook()
            await #expect(throws: ManagedConfigError.self) {
                try await manager.installAtomically([
                    ManagedConfigOperation(url: first, format: .json, hooks: [hook]),
                    ManagedConfigOperation(url: second, format: .json, hooks: [hook])
                ])
            }
            #expect(try String(contentsOf: first, encoding: .utf8) == original)
        }

        @Test("Provider install, uninstall, and reinstall only change marked AgentControl entries")
        func fullLifecycle() async throws {
            let home = temporaryDirectory("lifecycle")
            let receipts = home.appendingPathComponent("receipts.json")
            let detector = ProviderBinaryDetector(
                runner: Phase10VersionRunner(),
                isExecutable: { _ in true }
            )
            let manager = ManagedProviderIntegrationManager(
                homeDirectory: home,
                hookExecutableURL: URL(fileURLWithPath: "/Applications/AgentControl.app/Contents/MacOS/agentcontrol-hook"),
                detector: detector,
                receiptURL: receipts
            )
            let providers = [HookProvider.codex, .claude, .gemini]
            let configs = [
                HookProvider.codex: home.appendingPathComponent(".codex/hooks.json"),
                .claude: home.appendingPathComponent(".claude/settings.json"),
                .gemini: home.appendingPathComponent(".gemini/settings.json")
            ]
            let userConfig = "{\"theme\":\"dark\",\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"user-hook\"}]}]}}\n"
            for provider in providers {
                let config = try #require(configs[provider])
                try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(userConfig.utf8).write(to: config)
            }

            try await manager.installAtomically(providers)
            for provider in providers {
                let config = try #require(configs[provider])
                let installed = try String(contentsOf: config, encoding: .utf8)
                #expect(installed.contains("agentcontrol.\(provider.rawValue).sessionstart"))
                #expect(installed.contains("user-hook"))
            }

            for provider in providers {
                try await manager.uninstall(provider)
                let config = try #require(configs[provider])
                let removed = try String(contentsOf: config, encoding: .utf8)
                #expect(!removed.contains("agentcontrol.\(provider.rawValue)."))
                #expect(removed.contains("user-hook"))
                #expect(removed.contains("\"theme\":\"dark\""))
            }

            try await manager.installAtomically(providers)
            for provider in providers {
                let config = try #require(configs[provider])
                #expect(try String(contentsOf: config, encoding: .utf8).contains("agentcontrol.\(provider.rawValue).sessionstart"))
            }
        }

        @Test("Backup restore refuses to overwrite an external edit")
        func restoreConflict() async throws {
            let home = temporaryDirectory("restore")
            let detector = ProviderBinaryDetector(runner: Phase10VersionRunner(), isExecutable: { _ in true })
            let manager = ManagedProviderIntegrationManager(
                homeDirectory: home,
                hookExecutableURL: URL(fileURLWithPath: "/app/agentcontrol-hook"),
                detector: detector,
                receiptURL: home.appendingPathComponent("receipts.json")
            )
            let config = home.appendingPathComponent(".codex/hooks.json")
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"user\":true}\n".utf8).write(to: config)
            try await manager.installAtomically([.codex])
            var current = try String(contentsOf: config, encoding: .utf8)
            current = current.replacingOccurrences(of: "{", with: "{\"external\":true,", options: [], range: current.range(of: "{"))
            try Data(current.utf8).write(to: config)
            await #expect(throws: ManagedConfigError.concurrentModification) {
                try await manager.restoreBackup(.codex)
            }
            #expect(try String(contentsOf: config, encoding: .utf8).contains("\"external\":true"))
        }

        private func temporaryDirectory(_ name: String) -> URL {
            let url = URL(fileURLWithPath: "/private/tmp/ac-phase10-\(name)-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        private func fixtureHook() -> HookCommandDefinition {
            HookCommandDefinition(
                event: "SessionStart",
                command: "'/app/agentcontrol-hook' provider-hook codex",
                timeoutSeconds: 1,
                marker: "agentcontrol.phase10.sessionstart"
            )
        }
    }

    private struct Phase10VersionRunner: ProviderCommandRunning {
        func run(executable _: URL, arguments _: [String]) async throws -> ProviderCommandResult {
            ProviderCommandResult(status: 0, standardOutput: "codex 1.2.3")
        }
    }
#endif
