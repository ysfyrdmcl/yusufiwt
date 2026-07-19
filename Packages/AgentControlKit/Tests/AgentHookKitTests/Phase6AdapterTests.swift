import AgentDomain
import AgentHookKit
import AgentLocalIPC
import AgentProtocol
import Foundation
import Testing

// swiftlint:disable type_body_length function_body_length
@Suite("Phase 6 provider hook adapters")
struct Phase6AdapterTests {
    private let now = Date(timeIntervalSince1970: 1_784_320_000)

    @Test("JSONC patching preserves comments and unrelated fields")
    func jsoncPatchPreservesUserContent() throws {
        let original = """
        {
          // Keep this user comment.
          "theme": "dark",
          "hooks": {
            "SessionStart": [
              { "hooks": [{ "type": "command", "command": "user-hook" }] }
            ]
          }
        }
        """
        let hook = fixtureHook(event: "SessionStart")
        let engine = ManagedConfigPatchEngine()
        let installed = try engine.previewInstall(content: original, format: .jsonc, hooks: [hook])
        #expect(installed.updated.contains("// Keep this user comment."))
        #expect(installed.updated.contains("\"theme\": \"dark\""))
        #expect(installed.updated.contains("user-hook"))
        #expect(installed.updated.contains(hook.marker))

        let repaired = try engine.previewInstall(content: installed.updated, format: .jsonc, hooks: [hook])
        #expect(!repaired.hasChanges)
        let removed = try engine.previewUninstall(content: installed.updated, format: .jsonc, hooks: [hook])
        #expect(removed.updated.contains("user-hook"))
        #expect(removed.updated.contains("// Keep this user comment."))
        #expect(!removed.updated.contains(hook.marker))
    }

    @Test("JSON and TOML patchers are idempotent and scoped")
    func patchFormatMatrix() throws {
        let hook = fixtureHook(event: "PermissionRequest")
        let engine = ManagedConfigPatchEngine()
        for (format, original) in [
            (ManagedConfigFormat.json, "{\"unrelated\":true}\n"),
            (ManagedConfigFormat.toml, "theme = 'dark'\n")
        ] {
            let install = try engine.previewInstall(content: original, format: format, hooks: [hook])
            #expect(install.updated.contains(hook.marker))
            #expect(install.updated.contains(format == .json ? "unrelated" : "theme = 'dark'"))
            #expect(try !(engine.previewInstall(content: install.updated, format: format, hooks: [hook])).hasChanges)
            let uninstall = try engine.previewUninstall(content: install.updated, format: format, hooks: [hook])
            #expect(!uninstall.updated.contains(hook.marker))
            #expect(uninstall.updated.contains(format == .json ? "unrelated" : "theme = 'dark'"))
        }
    }

    @Test("JSON repair refreshes owned hook settings without touching user hooks")
    func jsonRepairRefreshesOwnedEntry() throws {
        let oldHook = HookCommandDefinition(
            event: "PermissionRequest",
            command: "'/old/agentcontrol-hook' provider-hook codex",
            timeoutSeconds: 60,
            marker: "agentcontrol.codex.permissionrequest"
        )
        let newHook = HookCommandDefinition(
            event: "PermissionRequest",
            command: "'/new/agentcontrol-hook' provider-hook codex",
            timeoutSeconds: 70,
            marker: oldHook.marker
        )
        let engine = ManagedConfigPatchEngine()
        let installed = try engine.previewInstall(
            content: "{\"hooks\":{\"PermissionRequest\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"user-hook\"}]}]}}\n",
            format: .json,
            hooks: [oldHook]
        )
        let repaired = try engine.previewInstall(content: installed.updated, format: .json, hooks: [newHook])

        #expect(repaired.updated.contains("user-hook"))
        #expect(repaired.updated.contains("/new/agentcontrol-hook"))
        #expect(repaired.updated.contains("\"timeout\":70"))
        #expect(!repaired.updated.contains("/old/agentcontrol-hook"))
        #expect(try !(engine.previewInstall(content: repaired.updated, format: .json, hooks: [newHook])).hasChanges)
    }

    @Test("Installer previews diffs, backs up, and rejects stale previews")
    func installerSafety() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ac-phase6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        try Data("{\"theme\":\"dark\"}\n".utf8).write(to: url)
        let manager = IntegrationManagerActor()
        let hooks = [fixtureHook(event: "SessionStart")]
        let preview = try await manager.preview(at: url, format: .json, hooks: hooks)
        #expect(preview.diff.contains("+++ proposed"))
        let backup = try await manager.apply(preview, at: url)
        #expect(backup != nil)
        #expect(try String(contentsOf: url, encoding: .utf8).contains(hooks[0].marker))

        let stale = try await manager.preview(at: url, format: .json, hooks: [fixtureHook(event: "Stop")])
        try Data("{\"changed\":true}\n".utf8).write(to: url)
        await #expect(throws: ManagedConfigError.concurrentModification) {
            try await manager.apply(stale, at: url)
        }
    }

    @Test("Patcher rejects broken and unsafe configuration targets")
    func patcherSecurityMatrix() async throws {
        let engine = ManagedConfigPatchEngine()
        #expect(throws: ManagedConfigError.malformedConfiguration) {
            try engine.previewInstall(content: "{ broken", format: .json, hooks: [fixtureHook(event: "Stop")])
        }

        let directory = URL(fileURLWithPath: "/private/tmp/ac-phase6-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.json")
        let link = directory.appendingPathComponent("settings.json")
        try Data("{}\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let manager = IntegrationManagerActor()
        await #expect(throws: ManagedConfigError.unsafeSymbolicLink) {
            try await manager.preview(at: link, format: .json, hooks: [fixtureHook(event: "Stop")])
        }
    }

    @Test("Provider installers cover official lifecycle hook matrices")
    func installerMatrices() throws {
        let executable = URL(fileURLWithPath: "/Applications/AgentControl.app/Contents/MacOS/agentcontrol-hook")
        let expected: [HookProvider: Set<String>] = [
            .codex: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop"],
            .claude: [
                "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                "Notification", "Elicitation", "Stop", "SessionEnd"
            ],
            .gemini: ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "Notification", "AfterAgent", "SessionEnd"]
        ]
        for provider in [HookProvider.codex, .claude, .gemini] {
            let installation = try ProviderHookInstallation.userLevel(
                provider: provider,
                hookExecutableURL: executable,
                providerVersion: ProviderVersion(major: 1, minor: 0, patch: 0),
                homeDirectory: URL(fileURLWithPath: "/private/tmp/home")
            )
            #expect(Set(installation.hooks.map(\.event)) == expected[provider])
            #expect(installation.hooks.allSatisfy { $0.command.contains("provider-hook \(provider.rawValue)") })
            #expect(installation.hooks.allSatisfy { $0.command.contains("AGENTCONTROL_PROVIDER_VERSION") })
            if provider == .codex || provider == .claude {
                #expect(installation.hooks.first(where: { $0.event == "PermissionRequest" })?.timeoutSeconds == 70)
                if provider == .codex {
                    #expect(installation.hooks.first(where: { $0.event == "PreToolUse" })?.timeoutSeconds == 70)
                }
                #expect(installation.hooks
                    .filter {
                        $0.event != "PermissionRequest" && $0.event != "Elicitation"
                            && !(provider == .codex && $0.event == "PreToolUse")
                    }
                    .allSatisfy { $0.timeoutSeconds >= 5 })
            }
        }
    }

    @Test("Version detection drives capabilities and unknown majors are monitor-only")
    func versionCapabilityDetection() async throws {
        let executable = URL(fileURLWithPath: "/private/tmp/codex")
        let known = ProviderBinaryDetector(
            runner: FixtureProviderRunner(output: "codex-cli 1.4.2"),
            isExecutable: { _ in true }
        )
        let knownInfo = try await known.detect(provider: .codex, searchPaths: [executable])
        #expect(knownInfo.version == ProviderVersion(major: 1, minor: 4, patch: 2))
        #expect(knownInfo.capabilities.supports(.approveRequests))

        let future = ProviderBinaryDetector(
            runner: FixtureProviderRunner(output: "codex-cli 99.0.0"),
            isExecutable: { _ in true }
        )
        let futureInfo = try await future.detect(provider: .codex, searchPaths: [executable])
        #expect(futureInfo.capabilities.supported == [.monitorSessions])
    }

    @Test("Fixture matrix maps start, approval or progress, and completion")
    func providerFixtureMatrix() throws {
        struct FixtureCase {
            let provider: HookProvider
            let name: String
            let state: SessionState
            let expectsDecision: Bool
        }
        let mapper = ProviderHookMapper()
        let environment = ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0", "PWD": "/private/tmp/work"]
        let cases: [FixtureCase] = [
            FixtureCase(provider: .codex, name: "codex-session-start", state: .starting, expectsDecision: false),
            FixtureCase(provider: .codex, name: "codex-progress", state: .executing, expectsDecision: false),
            FixtureCase(provider: .codex, name: "codex-permission", state: .waitingApproval, expectsDecision: true),
            FixtureCase(provider: .codex, name: "codex-stop", state: .completed, expectsDecision: false),
            FixtureCase(provider: .claude, name: "claude-session-start", state: .starting, expectsDecision: false),
            FixtureCase(provider: .claude, name: "claude-progress", state: .executing, expectsDecision: false),
            FixtureCase(provider: .claude, name: "claude-permission", state: .waitingApproval, expectsDecision: true),
            FixtureCase(provider: .claude, name: "claude-stop", state: .completed, expectsDecision: false),
            FixtureCase(provider: .gemini, name: "gemini-session-start", state: .starting, expectsDecision: false),
            FixtureCase(provider: .gemini, name: "gemini-progress", state: .running, expectsDecision: false),
            FixtureCase(provider: .gemini, name: "gemini-before-tool", state: .waitingApproval, expectsDecision: true),
            FixtureCase(provider: .gemini, name: "gemini-after-agent", state: .completed, expectsDecision: false),
            FixtureCase(provider: .generic, name: "generic-progress", state: .running, expectsDecision: false)
        ]
        for fixture in cases {
            let mapping = try mapper.map(
                provider: fixture.provider,
                input: loadFixture(fixture.name),
                environment: environment,
                now: now
            )
            switch mapping.submission.envelope.domainEvent {
            case let .stateChanged(state): #expect(state == fixture.state)
            case .approvalRequested: #expect(fixture.state == .waitingApproval)
            default: Issue.record("Unexpected mapped event for \(fixture.name)")
            }
            #expect((mapping.decisionRequest != nil) == fixture.expectsDecision)
            if fixture.expectsDecision {
                #expect(mapping.decisionRequest?.waitTimeoutMilliseconds == 60000)
            }
        }
    }

    @Test("Claude question round-trips and secret questions remain local")
    func questionMapping() throws {
        let mapper = ProviderHookMapper()
        let mapping = try mapper.map(
            provider: .claude,
            input: loadFixture("claude-question"),
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0"],
            now: now
        )
        #expect(mapping.decisionRequest?.kind == .question)
        #expect(mapping.decisionRequest?.choices.map(\.label) == ["Debug", "Release"])
        let choiceID = try #require(mapping.decisionRequest?.choices.first?.id)
        let output = mapper.providerOutput(
            for: .decision(HookDecisionResult(requestID: mapping.decisionRequest?.requestID ?? UUID(), revision: 1, decision: .answerChoice(id: choiceID))),
            mapping: mapping
        )
        #expect(output["hookSpecificOutput"]?["action"]?.stringValue == "accept")

        let secret = JSONValue.object([
            "session_id": .string("secret-session"), "cwd": .string("/private/tmp/work"),
            "hook_event_name": .string("Elicitation"), "message": .string("Password"),
            "requested_schema": .object(["type": .string("string"), "format": .string("password")])
        ])
        let secretMapping = try mapper.map(
            provider: .claude,
            input: secret,
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0"],
            now: now
        )
        #expect(secretMapping.decisionRequest == nil)

        let multiInput = JSONValue.object([
            "session_id": .string("multi-session"), "cwd": .string("/private/tmp/work"),
            "hook_event_name": .string("Elicitation"), "message": .string("Targets"),
            "requested_schema": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string"), "enum": .array([.string("mac"), .string("ios")])])
            ])
        ])
        let multi = try mapper.map(
            provider: .claude,
            input: multiInput,
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0"],
            now: now
        )
        #expect(try PendingHookDecision(request: #require(multi.decisionRequest)).question?.kind == .multiChoice)

        let textInput = JSONValue.object([
            "session_id": .string("text-session"), "cwd": .string("/private/tmp/work"),
            "hook_event_name": .string("Elicitation"), "message": .string("Summary"),
            "requested_schema": .object(["type": .string("string"), "maxLength": .number(12)])
        ])
        let text = try mapper.map(
            provider: .claude,
            input: textInput,
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0"],
            now: now
        )
        #expect(text.decisionRequest?.maximumAnswerLength == 12)
    }

    @Test("Unknown versions and auto-review modes never produce allow decisions")
    func monitorOnlyAndFalsePositiveFilters() throws {
        let mapper = ProviderHookMapper()
        let input = try loadFixture("codex-permission")
        let unknown = try mapper.map(
            provider: .codex,
            input: input,
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "99.0.0"],
            now: now
        )
        #expect(unknown.decisionRequest == nil)
        #expect(mapper.providerOutput(for: .neutral(reason: .helperUnavailable), mapping: unknown) == .object([:]))

        guard case var .object(autoFields) = input else { return }
        autoFields["permission_mode"] = .string("dontAsk")
        let automatic = try mapper.map(
            provider: .codex,
            input: .object(autoFields),
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0"],
            now: now
        )
        #expect(automatic.decisionRequest == nil)
    }

    @Test("Decision outputs use provider-specific synchronous schemas")
    func providerDecisionOutputs() throws {
        let mapper = ProviderHookMapper()
        for (provider, fixture) in [
            (HookProvider.codex, "codex-permission"),
            (.claude, "claude-permission"),
            (.gemini, "gemini-before-tool")
        ] {
            let mapping = try mapper.map(
                provider: provider,
                input: loadFixture(fixture),
                environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0"],
                now: now
            )
            let requestID = mapping.decisionRequest?.requestID ?? UUID()
            let output = mapper.providerOutput(
                for: .decision(HookDecisionResult(requestID: requestID, revision: 1, decision: .approve)),
                mapping: mapping
            )
            if provider == .gemini {
                #expect(output["decision"]?.stringValue == "allow")
            } else {
                #expect(output["hookSpecificOutput"]?["decision"]?["behavior"]?.stringValue == "allow")
            }
        }
    }

    private func fixtureHook(event: String) -> HookCommandDefinition {
        HookCommandDefinition(
            event: event,
            command: "'/Applications/AgentControl.app/Contents/MacOS/agentcontrol-hook' provider-hook codex",
            timeoutSeconds: 30,
            marker: "agentcontrol.test.\(event.lowercased())"
        )
    }

    private func loadFixture(_ name: String) throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }
}

// swiftlint:enable type_body_length function_body_length

private struct FixtureProviderRunner: ProviderCommandRunning {
    let output: String

    func run(executable _: URL, arguments _: [String]) async throws -> ProviderCommandResult {
        ProviderCommandResult(status: 0, standardOutput: output)
    }
}
