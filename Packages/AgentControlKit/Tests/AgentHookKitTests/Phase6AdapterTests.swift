import AgentDomain
import AgentHookKit
import AgentLocalIPC
import AgentProtocol
import Foundation
import Testing

// swiftlint:disable file_length type_body_length function_body_length
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

    @Test("Managed markers with shared prefixes remain distinct")
    func sharedMarkerPrefixesRemainDistinct() throws {
        let selection = HookCommandDefinition(
            event: "BeforeToolSelection", command: "hook", timeoutSeconds: 1,
            marker: "agentcontrol.gemini.beforetoolselection", usesNameField: true
        )
        let tool = HookCommandDefinition(
            event: "BeforeTool", command: "hook", timeoutSeconds: 60,
            marker: "agentcontrol.gemini.beforetool", usesNameField: true
        )
        let engine = ManagedConfigPatchEngine()
        let installed = try engine.previewInstall(content: "{}\n", format: .json, hooks: [selection, tool])
        #expect(installed.updated.contains(selection.marker))
        #expect(installed.updated.contains(tool.marker))
        #expect(try !(engine.previewInstall(
            content: installed.updated, format: .json, hooks: [selection, tool]
        )).hasChanges)
        let removed = try engine.previewUninstall(content: installed.updated, format: .json, hooks: [tool])
        #expect(removed.updated.contains(selection.marker))
        #expect(!removed.updated.contains("\"name\":\"\(tool.marker)\""))
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
            .codex: [
                "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop"
            ],
            .claude: [
                "SessionStart", "Setup", "UserPromptSubmit", "UserPromptExpansion", "MessageDisplay",
                "PreToolUse", "PermissionRequest", "PostToolUse", "PermissionDenied", "PostToolUseFailure",
                "PostToolBatch", "Notification", "Elicitation", "ElicitationResult", "SubagentStart",
                "SubagentStop", "TaskCreated", "PreCompact", "PostCompact", "ConfigChange",
                "InstructionsLoaded", "CwdChanged", "WorktreeRemove", "TeammateIdle", "TaskCompleted",
                "Stop", "StopFailure", "SessionEnd"
            ],
            .gemini: [
                "SessionStart", "BeforeAgent", "BeforeModel", "BeforeToolSelection", "BeforeTool", "AfterTool",
                "AfterModel", "Notification", "PreCompress", "AfterAgent", "SessionEnd"
            ],
            .cursor: [
                "sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure",
                "subagentStart", "subagentStop",
                "beforeShellExecution", "beforeMCPExecution", "afterShellExecution", "afterMCPExecution",
                "beforeReadFile", "afterFileEdit", "beforeTabFileRead", "afterTabFileEdit",
                "afterAgentResponse", "afterAgentThought", "preCompact", "stop", "sessionEnd", "workspaceOpen"
            ]
        ]
        for provider in [HookProvider.codex, .claude, .gemini, .cursor] {
            let installation = try ProviderHookInstallation.userLevel(
                provider: provider,
                hookExecutableURL: executable,
                providerVersion: ProviderVersion(major: 1, minor: 0, patch: 0),
                homeDirectory: URL(fileURLWithPath: "/private/tmp/home")
            )
            #expect(Set(installation.hooks.map(\.event)) == expected[provider])
            if provider == .claude {
                #expect(!installation.hooks.map(\.event).contains("WorktreeCreate"))
                #expect(!installation.hooks.map(\.event).contains("FileChanged"))
            }
            #expect(installation.hooks.allSatisfy { $0.command.contains("provider-hook \(provider.rawValue)") })
            #expect(installation.hooks.allSatisfy { $0.command.contains("AGENTCONTROL_PROVIDER_VERSION") })
            if provider == .codex || provider == .claude {
                #expect(installation.hooks.first(where: { $0.event == "PermissionRequest" })?.timeoutSeconds == 70)
                #expect(installation.hooks.first(where: { $0.event == "PreToolUse" })?.timeoutSeconds == 70)
                #expect(installation.hooks
                    .filter {
                        $0.event != "PermissionRequest" && $0.event != "Elicitation"
                            && !(provider == .codex && $0.event == "PreToolUse")
                    }
                    .allSatisfy { $0.timeoutSeconds >= 5 })
            } else if provider == .cursor {
                #expect(installation.configURL.path.hasSuffix("/.cursor/hooks.json"))
                #expect(installation.hooks.allSatisfy { $0.layout == .direct })
                let preToolUse = installation.hooks.first(where: { $0.event == "preToolUse" })
                #expect(preToolUse?.matcher == "Write|Delete|Task")
                #expect(preToolUse?.timeoutSeconds == 70)
                #expect(preToolUse?.failClosed == true)
                #expect(installation.hooks.first(where: { $0.event == "beforeShellExecution" })?.failClosed == true)
                #expect(installation.hooks.first(where: { $0.event == "beforeMCPExecution" })?.failClosed == true)
            }
        }
    }

    @Test("Cursor direct hook format preserves user config and scopes uninstall")
    func cursorDirectHookPatching() throws {
        let installation = try ProviderHookInstallation.userLevel(
            provider: .cursor,
            hookExecutableURL: URL(fileURLWithPath: "/Applications/AgentControl.app/Contents/MacOS/agentcontrol-hook"),
            providerVersion: ProviderVersion(major: 3, minor: 7, patch: 12),
            homeDirectory: URL(fileURLWithPath: "/private/tmp/home")
        )
        let original = "{\"theme\":\"dark\",\"hooks\":{\"sessionStart\":[{\"command\":\"user-hook\"}]}}\n"
        let engine = ManagedConfigPatchEngine()
        let installed = try engine.previewInstall(content: original, format: .json, hooks: installation.hooks)
        let data = try #require(installed.updated.data(using: .utf8))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let beforeShell = try #require(hooks["beforeShellExecution"] as? [[String: Any]])
        let owned = try #require(beforeShell.first)
        #expect(owned["command"] is String)
        #expect(owned["hooks"] == nil)
        #expect(owned["failClosed"] as? Bool == true)
        #expect((owned["command"] as? String)?.contains("agentcontrol.cursor.beforeshellexecution") == true)
        #expect(installed.updated.contains("user-hook"))
        #expect(try !(engine.previewInstall(content: installed.updated, format: .json, hooks: installation.hooks)).hasChanges)

        let removed = try engine.previewUninstall(content: installed.updated, format: .json, hooks: installation.hooks)
        #expect(removed.updated.contains("user-hook"))
        #expect(removed.updated.contains("\"theme\":\"dark\""))
        #expect(!removed.updated.contains("agentcontrol.cursor."))
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
        #expect(knownInfo.capabilities.supports(.answerQuestions))

        let future = ProviderBinaryDetector(
            runner: FixtureProviderRunner(output: "codex-cli 99.0.0"),
            isExecutable: { _ in true }
        )
        let futureInfo = try await future.detect(provider: .codex, searchPaths: [executable])
        #expect(futureInfo.capabilities.supported == [.monitorSessions])

        let cursor = ProviderBinaryDetector(
            runner: FixtureProviderRunner(output: "[0719/152915.401980:ERROR] codesign warning\n3.7.12\narm64"),
            isExecutable: { _ in true }
        )
        let cursorInfo = try await cursor.detect(provider: .cursor, searchPaths: [executable])
        #expect(cursorInfo.version == ProviderVersion(major: 3, minor: 7, patch: 12))
        #expect(cursorInfo.capabilities.supports(.approveRequests))
        #expect(!cursorInfo.capabilities.supports(.answerQuestions))
        #expect(!cursorInfo.capabilities.supports(.reviewPlans))
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
        guard case var .object(rewordedFields) = try loadFixture("claude-question") else {
            Issue.record("Claude elicitation fixture must be an object")
            return
        }
        rewordedFields["message"] = .string("Choose the build configuration")
        let reworded = try mapper.map(
            provider: .claude,
            input: .object(rewordedFields),
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0"],
            now: now
        )
        #expect(reworded.decisionRequest?.requestID == mapping.decisionRequest?.requestID)
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

    @Test("Claude AskUserQuestion round-trips original input and exact answers")
    func claudeAskUserQuestion() throws {
        let mapper = ProviderHookMapper()
        let input = try loadFixture("claude-ask-user-question")
        let mapping = try mapper.map(
            provider: .claude,
            input: input,
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "2.1.210"],
            now: now
        )
        #expect(mapping.decisionRequests.count == 2)
        #expect(mapping.providerQuestionIDs == ["Which framework?", "Which targets?"])
        #expect(try PendingHookDecision(request: #require(mapping.decisionRequests.first)).question?.kind
            == .singleChoice)
        #expect(PendingHookDecision(request: mapping.decisionRequests[1]).question?.kind == .multiChoice)

        let framework = try #require(mapping.decisionRequests[0].choices.first?.id)
        let targets = mapping.decisionRequests[1].choices.map(\.id)
        let output = mapper.providerOutput(for: [
            .decision(HookDecisionResult(
                requestID: mapping.decisionRequests[0].requestID,
                revision: 1,
                decision: .answerChoice(id: framework)
            )),
            .decision(HookDecisionResult(
                requestID: mapping.decisionRequests[1].requestID,
                revision: 1,
                decision: .answerChoices(ids: targets)
            ))
        ], mapping: mapping)
        let specific = try #require(output["hookSpecificOutput"])
        #expect(specific["hookEventName"]?.stringValue == "PreToolUse")
        #expect(specific["permissionDecision"]?.stringValue == "allow")
        #expect(specific["updatedInput"]?["questions"] == input["tool_input"]?["questions"])
        #expect(specific["updatedInput"]?["answers"]?["Which framework?"]?.stringValue == "React")
        #expect(specific["updatedInput"]?["answers"]?["Which targets?"]?.stringValue == "macOS, iOS")

        guard case var .object(secretFields) = input,
              case var .object(secretToolInput)? = secretFields["tool_input"],
              case var .array(secretQuestions)? = secretToolInput["questions"],
              case var .object(firstQuestion) = secretQuestions[0]
        else {
            Issue.record("Claude AskUserQuestion fixture shape changed")
            return
        }
        firstQuestion["question"] = .string("Enter the API key")
        secretQuestions[0] = .object(firstQuestion)
        secretToolInput["questions"] = .array(secretQuestions)
        secretFields["tool_input"] = .object(secretToolInput)
        let secret = try mapper.map(
            provider: .claude,
            input: .object(secretFields),
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "2.1.210"],
            now: now
        )
        #expect(secret.decisionRequests.isEmpty)
        #expect(secret.providerQuestionIDs.isEmpty)
        #expect(secret.submission.envelope.domainEvent == .stateChanged(.executing))
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
        let dontAsk = try mapper.map(
            provider: .codex,
            input: .object(autoFields),
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0"],
            now: now
        )
        #expect(dontAsk.decisionRequest != nil)

        autoFields["permission_mode"] = .string("acceptEdits")
        let acceptEditsOnShell = try mapper.map(
            provider: .codex,
            input: .object(autoFields),
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0"],
            now: now
        )
        #expect(acceptEditsOnShell.decisionRequest != nil)

        autoFields["tool_name"] = .string("Edit")
        autoFields["tool_input"] = .object(["file_path": .string("/private/tmp/work/App.swift")])
        let automaticEdit = try mapper.map(
            provider: .codex,
            input: .object(autoFields),
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0"],
            now: now
        )
        #expect(automaticEdit.decisionRequest == nil)
        #expect(automaticEdit.additionalSubmissions.count == 1)

        autoFields.removeValue(forKey: "permission_mode")
        autoFields["already_approved"] = .bool(true)
        let alreadyApproved = try mapper.map(
            provider: .codex,
            input: .object(autoFields),
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0"],
            now: now
        )
        #expect(alreadyApproved.decisionRequest == nil)
        #expect(alreadyApproved.submission.envelope.domainEvent == .stateChanged(.executing))

        let unrelated = try mapper.map(
            provider: .codex,
            input: .object([
                "session_id": .string("unrelated-status"),
                "hook_event_name": .string("SessionStart"),
                "permission_mode": .string("acceptEdits"),
                "auto_approved": .bool(true)
            ]),
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0", "PWD": "/private/tmp/work"],
            now: now
        )
        #expect(unrelated.additionalSubmissions.isEmpty)
        #expect(unrelated.submission.envelope.domainEvent == .stateChanged(.starting))
    }

    @Test("Decision outputs use provider-specific synchronous schemas")
    func providerDecisionOutputs() throws {
        let mapper = ProviderHookMapper()
        for (provider, fixture) in [
            (HookProvider.codex, "codex-permission"),
            (.claude, "claude-permission"),
            (.gemini, "gemini-before-tool"),
            (.cursor, "cursor-before-shell")
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
            } else if provider == .cursor {
                #expect(output["permission"]?.stringValue == "allow")
            } else {
                #expect(output["hookSpecificOutput"]?["decision"]?["behavior"]?.stringValue == "allow")
            }
        }
    }

    @Test("Cursor fixtures preserve lifecycle, decisions, usage, and provider acknowledgment")
    func cursorFixtureLifecycle() throws {
        let mapper = ProviderHookMapper()
        let environment = ["AGENTCONTROL_PROVIDER_VERSION": "3.7.12", "PWD": "/private/tmp/work"]
        let start = try mapper.map(
            provider: .cursor, input: loadFixture("cursor-session-start"), environment: environment, now: now
        )
        #expect(start.submission.envelope.domainEvent == .stateChanged(.starting))

        let beforeShell = try mapper.map(
            provider: .cursor, input: loadFixture("cursor-before-shell"), environment: environment, now: now
        )
        let repeated = try mapper.map(
            provider: .cursor, input: loadFixture("cursor-before-shell"), environment: environment, now: now
        )
        #expect(beforeShell.decisionRequest?.kind == .approval)
        #expect(beforeShell.decisionRequest?.requestID == repeated.decisionRequest?.requestID)
        #expect(beforeShell.submission.envelope.eventID == repeated.submission.envelope.eventID)
        #expect(mapper.providerOutput(
            for: .neutral(reason: .helperUnavailable), mapping: beforeShell
        )["permission"]?.stringValue == "ask")

        let afterShell = try mapper.map(
            provider: .cursor, input: loadFixture("cursor-after-shell"), environment: environment, now: now
        )
        #expect(afterShell.decisionRequest == nil)
        #expect(afterShell.additionalSubmissions.count == 1)
        guard case let .approvalStatusChanged(afterID, afterStatus) = afterShell.additionalSubmissions[0].envelope.domainEvent else {
            Issue.record("Cursor afterShellExecution did not map to an acknowledgment")
            return
        }
        #expect(afterID.rawValue == beforeShell.decisionRequest?.requestID)
        #expect(afterStatus == .applied)

        let beforeMCP = try mapper.map(
            provider: .cursor, input: loadFixture("cursor-before-mcp"), environment: environment, now: now
        )
        #expect(beforeMCP.decisionRequest?.kind == .approval)
        #expect(beforeMCP.decisionRequest?.requestID != beforeShell.decisionRequest?.requestID)

        let beforeWrite = try mapper.map(
            provider: .cursor, input: loadFixture("cursor-pre-tool-write"), environment: environment, now: now
        )
        #expect(beforeWrite.decisionRequest?.kind == .approval)
        let writeOutput = mapper.providerOutput(
            for: .decision(.init(
                requestID: beforeWrite.decisionRequest?.requestID ?? UUID(),
                revision: 1,
                decision: .approve
            )),
            mapping: beforeWrite
        )
        #expect(writeOutput["permission"]?.stringValue == "allow")
        let afterWrite = try mapper.map(
            provider: .cursor, input: loadFixture("cursor-post-tool-write"), environment: environment, now: now
        )
        guard case let .approvalStatusChanged(writeID, writeStatus) =
            try #require(afterWrite.additionalSubmissions.first).envelope.domainEvent
        else {
            Issue.record("Cursor postToolUse did not acknowledge the structured write")
            return
        }
        #expect(writeID.rawValue == beforeWrite.decisionRequest?.requestID)
        #expect(writeStatus == .applied)

        let compact = try mapper.map(
            provider: .cursor, input: loadFixture("cursor-pre-compact"), environment: environment, now: now
        )
        guard case let .usageUpdated(update) = compact.submission.envelope.domainEvent else {
            Issue.record("Cursor preCompact did not map structured context usage")
            return
        }
        #expect(update.metrics.first?.kind == .contextRemaining)
        #expect(update.metrics.first?.remainingPercent == 75)

        let completed = try mapper.map(
            provider: .cursor, input: loadFixture("cursor-stop-completed"), environment: environment, now: now
        )
        let failed = try mapper.map(
            provider: .cursor, input: loadFixture("cursor-stop-error"), environment: environment, now: now
        )
        #expect(completed.submission.envelope.domainEvent == .stateChanged(.completed))
        #expect(failed.submission.envelope.domainEvent == .stateChanged(.failed))
    }

    @Test("Cursor generic shell and read hooks avoid duplicate or read-everything prompts")
    func cursorGenericHooksAreScoped() throws {
        let mapper = ProviderHookMapper()
        let environment = ["AGENTCONTROL_PROVIDER_VERSION": "3.7.12", "PWD": "/private/tmp/work"]
        for event in ["preToolUse", "beforeReadFile"] {
            let mapping = try mapper.map(
                provider: .cursor,
                input: .object([
                    "conversation_id": .string("cursor-monitor-only"),
                    "hook_event_name": .string(event),
                    "tool_name": .string(event == "preToolUse" ? "Shell" : "Read"),
                    "tool_input": .object(["path": .string("/private/tmp/work/Package.swift")])
                ]),
                environment: environment,
                now: now
            )
            #expect(mapping.decisionRequest == nil)
            #expect(mapping.submission.envelope.domainEvent == .stateChanged(.executing))
        }
    }

    @Test("Plan, automatic, denial, cancellation, and expiry events are never actionable twice")
    func resolvedEventMatrix() throws {
        let mapper = ProviderHookMapper()
        let environment = ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0", "PWD": "/private/tmp/work"]
        for (provider, fixture) in [
            (HookProvider.claude, "claude-plan-review"),
            (.gemini, "gemini-plan-review")
        ] {
            let mapping = try mapper.map(
                provider: provider, input: loadFixture(fixture), environment: environment, now: now
            )
            #expect(mapping.decisionRequest?.kind == .plan)
            if provider == .claude {
                let output = mapper.providerOutput(
                    for: .decision(HookDecisionResult(
                        requestID: mapping.decisionRequest?.requestID ?? UUID(),
                        revision: 1,
                        decision: .approve
                    )),
                    mapping: mapping
                )
                #expect(output["hookSpecificOutput"]?["hookEventName"]?.stringValue == "PreToolUse")
                #expect(output["hookSpecificOutput"]?["permissionDecision"]?.stringValue == "allow")
                #expect(output["hookSpecificOutput"]?["decision"] == nil)
                #expect(output["hookSpecificOutput"]?["updatedInput"]?["plan"]?.stringValue
                    == "Implement the requested changes and run the test suite.")
            }
        }

        let automatic = try mapper.map(
            provider: .codex, input: loadFixture("codex-auto-approved"), environment: environment, now: now
        )
        #expect(automatic.decisionRequest == nil)
        #expect(automatic.additionalSubmissions.count == 1)
        guard case let .approvalStatusChanged(_, automaticStatus) =
            automatic.additionalSubmissions[0].envelope.domainEvent
        else {
            Issue.record("Auto-approved event did not emit an audit status")
            return
        }
        #expect(automaticStatus == .applied)
        #expect(automatic.additionalSubmissions[0].envelope.payload["resolutionSource"]?.stringValue
            == "providerAutomation")

        for (provider, fixture) in [
            (HookProvider.claude, "claude-permission-denied"),
            (.gemini, "gemini-after-tool-denied"),
            (.cursor, "cursor-permission-denied")
        ] {
            let mapping = try mapper.map(
                provider: provider, input: loadFixture(fixture), environment: environment, now: now
            )
            #expect(mapping.decisionRequest == nil)
            guard case let .approvalStatusChanged(_, status) =
                try #require(mapping.additionalSubmissions.first).envelope.domainEvent
            else {
                Issue.record("Provider denial did not emit an acknowledgment")
                continue
            }
            #expect(status == .providerRejected)
        }

        let structuredDenial = try mapper.map(
            provider: .claude,
            input: .object([
                "session_id": .string("structured-denial"),
                "cwd": .string("/private/tmp/work"),
                "hook_event_name": .string("Notification"),
                "request_id": .string("structured-request"),
                "outcome": .string("denied")
            ]),
            environment: environment,
            now: now
        )
        guard case let .approvalStatusChanged(_, denialStatus) =
            try #require(structuredDenial.additionalSubmissions.first).envelope.domainEvent
        else {
            Issue.record("Structured provider denial did not emit a status")
            return
        }
        #expect(denialStatus == .providerRejected)

        for (field, expected) in [
            ("cancelled", ApprovalStatus.cancelledByProvider),
            ("expired", ApprovalStatus.expired)
        ] {
            var fields: [String: JSONValue] = [
                "session_id": .string("resolved-session"),
                "cwd": .string("/private/tmp/work"),
                "hook_event_name": .string("Notification"),
                "request_id": .string("resolved-request")
            ]
            fields[field] = .bool(true)
            let mapping = try mapper.map(
                provider: .claude, input: .object(fields), environment: environment, now: now
            )
            #expect(mapping.decisionRequest == nil)
            guard case let .approvalStatusChanged(_, status) =
                try #require(mapping.additionalSubmissions.first).envelope.domainEvent
            else {
                Issue.record("Resolved provider event did not emit a status")
                continue
            }
            #expect(status == expected)
        }
    }

    @Test("Fallback provider request IDs are scoped to their provider session")
    func fallbackRequestIdentityIsSessionScoped() throws {
        let mapper = ProviderHookMapper()
        let environment = ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0", "PWD": "/private/tmp/work"]
        let input = try loadFixture("gemini-before-tool")
        let first = try mapper.map(provider: .gemini, input: input, environment: environment, now: now)
        guard case var .object(otherSessionFields) = input else {
            Issue.record("Gemini fixture must be an object")
            return
        }
        otherSessionFields["session_id"] = .string("different-gemini-session")
        let second = try mapper.map(
            provider: .gemini,
            input: .object(otherSessionFields),
            environment: environment,
            now: now
        )
        #expect(first.decisionRequest?.requestID != second.decisionRequest?.requestID)
        let repeated = try mapper.map(provider: .gemini, input: input, environment: environment, now: now)
        #expect(first.decisionRequest?.requestID == repeated.decisionRequest?.requestID)
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
