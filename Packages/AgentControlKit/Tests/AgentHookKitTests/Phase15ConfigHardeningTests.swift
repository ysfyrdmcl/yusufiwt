#if os(macOS)
    import AgentHookKit
    import Foundation
    import Testing

    @Suite("Phase 15 managed-config hardening", .serialized)
    struct Phase15ConfigHardeningTests {
        private let safeHook = HookCommandDefinition(
            event: "PreToolUse",
            matcher: "Bash",
            command: "/usr/local/bin/agentcontrol-hook",
            timeoutSeconds: 10,
            marker: "agentcontrol.phase15"
        )

        @Test("Target and parent symlinks fail closed")
        func rejectsSymlinks() async throws {
            let root = URL(fileURLWithPath: "/private/tmp/agentcontrol-phase15-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let real = root.appendingPathComponent("real.json")
            try Data("{}\n".utf8).write(to: real)
            let targetLink = root.appendingPathComponent("linked.json")
            try FileManager.default.createSymbolicLink(at: targetLink, withDestinationURL: real)

            let manager = IntegrationManagerActor()
            await #expect(throws: ManagedConfigError.unsafeSymbolicLink) {
                try await manager.preview(at: targetLink, format: .json, hooks: [safeHook])
            }

            let realDirectory = root.appendingPathComponent("real-directory", isDirectory: true)
            try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
            let directoryLink = root.appendingPathComponent("linked-directory", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: realDirectory)
            await #expect(throws: ManagedConfigError.unsafeSymbolicLink) {
                try await manager.install(
                    at: directoryLink.appendingPathComponent("new.json"),
                    format: .json,
                    hooks: [safeHook]
                )
            }
        }

        @Test("Identifiers and TOML values cannot inject configuration")
        func rejectsConfigInjection() throws {
            let patcher = ManagedConfigPatchEngine()
            let injectedIdentifier = HookCommandDefinition(
                event: "PreToolUse]]\nelevated=true\n[[hooks.bad",
                command: "hook", timeoutSeconds: 10, marker: "agentcontrol.phase15"
            )
            #expect(throws: ManagedConfigError.invalidManagedEntry) {
                try patcher.previewInstall(content: "", format: .toml, hooks: [injectedIdentifier])
            }

            let command = "hook'\n[[hooks.elevated]]\nenabled=true"
            let hook = HookCommandDefinition(
                event: "PreToolUse", matcher: "Bash'\nenabled=true", command: command,
                timeoutSeconds: 10, marker: "agentcontrol.phase15"
            )
            let result = try patcher.previewInstall(content: "", format: .toml, hooks: [hook]).updated
            #expect(!result.contains("\n[[hooks.elevated]]"))
            #expect(result.contains("\\n[[hooks.elevated]]"))
            #expect(result.contains("command = \""))
        }

        @Test("Directories and invalid hook bounds are rejected")
        func rejectsUnsafeTypesAndBounds() async throws {
            let root = URL(fileURLWithPath: "/private/tmp/agentcontrol-phase15-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let manager = IntegrationManagerActor()
            await #expect(throws: ManagedConfigError.self) {
                try await manager.preview(at: root, format: .json, hooks: [safeHook])
            }

            let invalid = HookCommandDefinition(
                event: "PreToolUse", command: "", timeoutSeconds: 120_001, marker: "agentcontrol.phase15"
            )
            #expect(throws: ManagedConfigError.invalidManagedEntry) {
                try ManagedConfigPatchEngine().previewInstall(content: "{}", format: .json, hooks: [invalid])
            }
        }
    }
#endif
