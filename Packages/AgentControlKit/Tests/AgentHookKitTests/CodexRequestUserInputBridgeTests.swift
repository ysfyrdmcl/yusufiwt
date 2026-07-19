import AgentDomain
import AgentHookKit
import AgentLocalIPC
import AgentProtocol
import Foundation
import Testing

@Suite("Codex request_user_input bridge")
struct CodexRequestUserInputBridgeTests {
    private let now = Date(timeIntervalSince1970: 1_784_320_000)

    @Test("Every question maps separately and returns exact answers")
    func mappingAndOutput() throws {
        let mapper = ProviderHookMapper()
        let mapping = try mapper.map(
            provider: .codex,
            input: requestInput(),
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0"],
            now: now
        )
        #expect(mapping.decisionRequests.count == 2)
        #expect(mapping.providerQuestionIDs == ["scope", "tone"])
        let scope = try PendingHookDecision(request: #require(mapping.decisionRequests.first))
        #expect(scope.question?.header == "Scope")
        #expect(scope.question?.isOther == true)
        #expect(scope.choices.first?.description == "Only the reported behavior.")
        #expect(PendingHookDecision(request: mapping.decisionRequests[1]).question?.kind == .freeText)

        let focusedID = try #require(mapping.decisionRequests[0].choices.first?.id)
        let responses: [HelperResponse] = [
            .decision(HookDecisionResult(
                requestID: mapping.decisionRequests[0].requestID,
                revision: 1,
                decision: .answerChoice(id: focusedID)
            )),
            .decision(HookDecisionResult(
                requestID: mapping.decisionRequests[1].requestID,
                revision: 1,
                decision: .answerText("Concise")
            ))
        ]
        let output = mapper.providerOutput(for: responses, mapping: mapping)
        #expect(output["hookSpecificOutput"]?["hookEventName"]?.stringValue == "PreToolUse")
        #expect(output["hookSpecificOutput"]?["permissionDecision"]?.stringValue == "deny")
        let reason = try #require(output["hookSpecificOutput"]?["permissionDecisionReason"]?.stringValue)
        #expect(reason.contains("Do not call request_user_input again"))
        #expect(reason.contains(#"{"answers":{"scope":{"answers":["Focused"]},"tone":{"answers":["Concise"]}}}"#))
    }

    @Test("Single-choice Other accepts free text")
    func otherAnswer() async throws {
        let mapping = try ProviderHookMapper().map(
            provider: .codex,
            input: requestInput(),
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0"],
            now: now
        )
        let request = try #require(mapping.decisionRequests.first)
        let brokerNow = now
        let broker = HookDecisionBroker(now: { brokerNow })
        async let result = broker.wait(for: request)
        try await Task.sleep(for: .milliseconds(10))
        #expect(await broker.resolve(.init(
            requestID: request.requestID,
            revision: request.revision,
            decision: .answerText("Custom response")
        )) == .accepted)
        #expect(await result.decisionValue?.decision == .answerText("Custom response"))
    }

    @Test("Secret questions stay native")
    func secretFallback() throws {
        let input = JSONValue.object([
            "session_id": .string("codex-secret"),
            "hook_event_name": .string("PreToolUse"),
            "tool_name": .string("request_user_input"),
            "tool_input": .object([
                "questions": .array([
                    .object([
                        "id": .string("token"),
                        "header": .string("Token"),
                        "question": .string("Enter the token"),
                        "isSecret": .bool(true),
                        "options": .array([])
                    ])
                ])
            ])
        ])
        let mapping = try ProviderHookMapper().map(
            provider: .codex,
            input: input,
            environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0", "PWD": "/private/tmp/work"],
            now: now
        )
        #expect(mapping.decisionRequests.isEmpty)
        #expect(mapping.providerQuestionIDs.isEmpty)
        if case let .stateChanged(state) = mapping.submission.envelope.domainEvent {
            #expect(state == .executing)
        } else {
            Issue.record("Secret request_user_input should remain a normal PreToolUse event")
        }
    }

    private func requestInput() -> JSONValue {
        .object([
            "session_id": .string("codex-plan"),
            "cwd": .string("/private/tmp/work"),
            "hook_event_name": .string("PreToolUse"),
            "tool_name": .string("request_user_input"),
            "tool_use_id": .string("tool-1"),
            "tool_input": .object([
                "questions": .array([
                    .object([
                        "id": .string("scope"),
                        "header": .string("Scope"),
                        "question": .string("How broad should the change be?"),
                        "options": .array([
                            .object([
                                "label": .string("Focused"),
                                "description": .string("Only the reported behavior.")
                            ]),
                            .object([
                                "label": .string("Broad"),
                                "description": .string("Include adjacent cleanup.")
                            ])
                        ])
                    ]),
                    .object([
                        "id": .string("tone"),
                        "header": .string("Tone"),
                        "question": .string("Describe the preferred tone."),
                        "options": .array([])
                    ])
                ])
            ])
        ])
    }
}

private extension HelperResponse {
    var decisionValue: HookDecisionResult? {
        guard case let .decision(value) = self else { return nil }
        return value
    }
}
