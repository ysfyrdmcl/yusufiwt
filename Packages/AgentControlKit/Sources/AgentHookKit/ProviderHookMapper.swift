// swiftlint:disable file_length
#if os(macOS)
    import AgentDomain
    import AgentLocalIPC
    import AgentProtocol
    import Foundation

    public struct ProviderHookMapping: Sendable {
        public let provider: HookProvider
        public let eventName: String
        public let submission: HelperEventSubmission
        public let decisionRequests: [HookDecisionRequest]
        public let providerQuestionIDs: [String]

        public var decisionRequest: HookDecisionRequest? {
            decisionRequests.first
        }

        public init(
            provider: HookProvider,
            eventName: String,
            submission: HelperEventSubmission,
            decisionRequests: [HookDecisionRequest] = [],
            providerQuestionIDs: [String] = []
        ) {
            self.provider = provider
            self.eventName = eventName
            self.submission = submission
            self.decisionRequests = decisionRequests
            self.providerQuestionIDs = providerQuestionIDs
        }
    }

    public enum ProviderHookMappingError: Error, Sendable, Equatable {
        case missingEventName
        case malformedInput
    }

    // swiftlint:disable:next type_body_length
    public struct ProviderHookMapper: Sendable {
        private let compatibility: ProviderCompatibilityPolicy

        public init(compatibility: ProviderCompatibilityPolicy = ProviderCompatibilityPolicy()) {
            self.compatibility = compatibility
        }

        // swiftlint:disable:next function_body_length
        public func map(
            provider: HookProvider,
            input: JSONValue,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            now: Date = Date()
        ) throws -> ProviderHookMapping {
            guard case let .object(fields) = input else { throw ProviderHookMappingError.malformedInput }
            let eventName = fields["hook_event_name"]?.stringValue
                ?? fields["event"]?.stringValue
                ?? fields["event_name"]?.stringValue
            guard let eventName, !eventName.isEmpty else { throw ProviderHookMappingError.missingEventName }

            let providerSessionID = fields["session_id"]?.stringValue
                ?? fields["sessionId"]?.stringValue
                ?? fields["conversation_id"]?.stringValue
                ?? environment["AGENTCONTROL_CORRELATION_ID"]
                ?? "process-\(ProcessInfo.processInfo.processIdentifier)"
            let cwd = fields["cwd"]?.stringValue ?? environment["PWD"] ?? "/private/tmp"
            let sessionID = SessionID(StableIdentifier.uuid("session:\(provider.rawValue):\(providerSessionID)"))
            let nodeID = environment["AGENTCONTROL_NODE_ID"].flatMap(UUID.init(uuidString:)).map(NodeID.init)
                ?? NodeID(StableIdentifier.uuid("node:\(ProcessInfo.processInfo.hostName)"))
            let projectID = ProjectID(StableIdentifier.uuid("project:\(cwd)"))
            let versionText = environment["AGENTCONTROL_PROVIDER_VERSION"] ?? fields["provider_version"]?.stringValue
            let version = versionText.flatMap(ProviderVersion.init)
            let capabilities = compatibility.capabilities(for: provider, version: version)
            let adapterVersion = version?.description ?? "unknown"
            let sequence = Int64(now.timeIntervalSince1970 * 1_000_000)
            let terminalContext = TerminalContextCapture().capture(
                fields: fields,
                environment: environment,
                correlationToken: providerSessionID,
                now: now
            )

            let normalized = normalize(
                provider: provider,
                eventName: eventName,
                fields: fields,
                sessionID: sessionID,
                workspaceRoot: URL(fileURLWithPath: cwd, isDirectory: true),
                capabilities: capabilities,
                now: now
            )
            let source = EventSource(
                adapterID: provider.adapterID,
                adapterVersion: adapterVersion,
                nodeID: nodeID,
                processID: Int32(ProcessInfo.processInfo.processIdentifier)
            )
            let correlationID = EnvelopeID(StableIdentifier.uuid("correlation:\(provider.rawValue):\(providerSessionID)"))
            let occurredAt = parseDate(fields["timestamp"]?.stringValue) ?? now
            func envelope(
                eventType: String,
                payload: JSONValue,
                privacyClass: PrivacyClass,
                sequenceOffset: Int64 = 0
            ) -> EventEnvelope {
                EventEnvelope(
                    eventID: EventID(UUID()),
                    eventType: eventType,
                    source: source,
                    sessionID: sessionID,
                    providerSessionID: providerSessionID,
                    sequence: sequence + sequenceOffset,
                    occurredAt: occurredAt,
                    receivedAt: now,
                    payload: payload,
                    privacyClass: privacyClass,
                    correlationID: correlationID,
                    schemaHash: "agentcontrol-hook-v1-\(provider.rawValue)"
                )
            }
            let session = AgentSession(
                id: sessionID,
                nodeID: nodeID,
                adapterID: provider.adapterID,
                externalSessionID: providerSessionID,
                project: ProjectReference(
                    id: projectID,
                    name: URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? "Terminal session" : URL(fileURLWithPath: cwd).lastPathComponent,
                    rootURL: URL(fileURLWithPath: cwd, isDirectory: true)
                ),
                terminalContext: terminalContext,
                parentSessionID: nil,
                state: .discovered,
                startedAt: now,
                endedAt: nil,
                lastMeaningfulEventAt: now,
                snapshotRevision: 0
            )
            let baseSubmission = HelperEventSubmission(
                envelope: envelope(
                    eventType: normalized.eventType,
                    payload: normalized.payload,
                    privacyClass: normalized.privacyClass
                ),
                initialSession: session
            )
            let requests = normalized.decisions.enumerated().map { index, metadata in
                let submission = HelperEventSubmission(
                    envelope: envelope(
                        eventType: metadata.eventType,
                        payload: metadata.payload,
                        privacyClass: metadata.privacyClass,
                        sequenceOffset: Int64(index)
                    ),
                    initialSession: session
                )
                return HookDecisionRequest(
                    requestID: metadata.id,
                    revision: 1,
                    kind: metadata.kind,
                    prompt: metadata.prompt,
                    choices: metadata.choices,
                    maximumAnswerLength: metadata.maximumAnswerLength,
                    expiresAt: now.addingTimeInterval(70),
                    waitTimeoutMilliseconds: 60000,
                    submission: submission
                )
            }
            return ProviderHookMapping(
                provider: provider,
                eventName: eventName,
                submission: requests.first?.submission ?? baseSubmission,
                decisionRequests: requests,
                providerQuestionIDs: normalized.decisions.compactMap(\.providerQuestionID)
            )
        }

        public func providerOutput(for response: HelperResponse, mapping: ProviderHookMapping) -> JSONValue {
            if mapping.decisionRequests.count > 1 || !mapping.providerQuestionIDs.isEmpty {
                return providerOutput(for: [response], mapping: mapping)
            }
            return singleProviderOutput(for: response, mapping: mapping)
        }

        public func providerOutput(for responses: [HelperResponse], mapping: ProviderHookMapping) -> JSONValue {
            guard mapping.provider == .codex,
                  mapping.eventName == "PreToolUse",
                  !mapping.providerQuestionIDs.isEmpty,
                  responses.count == mapping.decisionRequests.count,
                  mapping.providerQuestionIDs.count == responses.count
            else {
                guard responses.count == 1, let response = responses.first else { return .object([:]) }
                return singleProviderOutput(for: response, mapping: mapping)
            }

            var answers: [String: JSONValue] = [:]
            for index in responses.indices {
                guard case let .decision(result) = responses[index],
                      let values = answerValues(result.decision, request: mapping.decisionRequests[index])
                else { return .object([:]) }
                answers[mapping.providerQuestionIDs[index]] = .object([
                    "answers": .array(values.map(JSONValue.string))
                ])
            }
            let result = JSONValue.object(["answers": .object(answers)])
            guard let encoded = compactJSONString(result) else { return .object([:]) }
            let reason = "User answers collected by yusufiwt. Do not call request_user_input again. "
                + "Continue the plan using exactly this result: \(encoded)"
            return .object([
                "hookSpecificOutput": .object([
                    "hookEventName": .string("PreToolUse"),
                    "permissionDecision": .string("deny"),
                    "permissionDecisionReason": .string(reason)
                ])
            ])
        }

        private func singleProviderOutput(for response: HelperResponse, mapping: ProviderHookMapping) -> JSONValue {
            guard case let .decision(result) = response else { return .object([:]) }
            switch result.decision {
            case .approve:
                return approvalOutput(provider: mapping.provider, event: mapping.eventName, behavior: "allow")
            case .deny:
                return approvalOutput(provider: mapping.provider, event: mapping.eventName, behavior: "deny")
            case let .answerChoice(id):
                guard let answer = mapping.decisionRequest?.choices.first(where: { $0.id == id })?.label else {
                    return .object([:])
                }
                return elicitationOutput(answer: .string(answer), mapping: mapping)
            case let .answerChoices(ids):
                let labels = ids.compactMap { id in mapping.decisionRequest?.choices.first(where: { $0.id == id })?.label }
                guard labels.count == ids.count else { return .object([:]) }
                return elicitationOutput(answer: .array(labels.map(JSONValue.string)), mapping: mapping)
            case let .answerText(answer):
                return elicitationOutput(answer: .string(answer), mapping: mapping)
            case let .confirm(answer):
                return elicitationOutput(answer: .bool(answer), mapping: mapping)
            case .requestPlanChanges:
                return .object([:])
            }
        }

        private func answerValues(_ decision: HookDecision, request: HookDecisionRequest) -> [String]? {
            switch decision {
            case let .answerChoice(id):
                return request.choices.first(where: { $0.id == id }).map { [$0.label] }
            case let .answerChoices(ids):
                let labels = ids.compactMap { id in request.choices.first(where: { $0.id == id })?.label }
                return labels.count == ids.count ? labels : nil
            case let .answerText(value):
                return [value]
            case let .confirm(value):
                return [value ? "true" : "false"]
            case .approve, .deny, .requestPlanChanges:
                return nil
            }
        }

        private func compactJSONString(_ value: JSONValue) -> String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        }

        private func elicitationOutput(answer: JSONValue, mapping: ProviderHookMapping) -> JSONValue {
            guard mapping.provider == .claude, mapping.eventName == "Elicitation" else { return .object([:]) }
            return .object([
                "hookSpecificOutput": .object([
                    "hookEventName": .string("Elicitation"),
                    "action": .string("accept"),
                    "content": .object(["value": answer])
                ])
            ])
        }

        private func approvalOutput(provider: HookProvider, event: String, behavior: String) -> JSONValue {
            switch provider {
            case .codex, .claude:
                .object([
                    "hookSpecificOutput": .object([
                        "hookEventName": .string(event),
                        "decision": .object([
                            "behavior": .string(behavior),
                            "message": .string(behavior == "deny" ? "Denied in yusufiwt." : "Approved in yusufiwt.")
                        ])
                    ])
                ])
            case .gemini:
                .object([
                    "decision": .string(behavior),
                    "reason": .string(behavior == "deny" ? "Denied in yusufiwt." : "Approved in yusufiwt."),
                    "suppressOutput": .bool(true)
                ])
            case .generic:
                .object([:])
            }
        }

        // swiftlint:disable:next function_body_length function_parameter_count
        private func normalize(
            provider: HookProvider,
            eventName: String,
            fields: [String: JSONValue],
            sessionID: SessionID,
            workspaceRoot: URL,
            capabilities: CapabilityMatrix,
            now: Date
        ) -> NormalizedHookEvent {
            if provider == .codex,
               eventName == "PreToolUse",
               (fields["tool_name"]?.stringValue ?? fields["toolName"]?.stringValue) == "request_user_input",
               let decisions = requestUserInputDecisions(fields: fields, sessionID: sessionID, now: now),
               let first = decisions.first {
                return NormalizedHookEvent(
                    eventType: first.eventType,
                    payload: first.payload,
                    privacyClass: first.privacyClass,
                    decisions: decisions
                )
            }

            if isApprovalEvent(provider: provider, event: eventName, fields: fields) {
                let action = action(from: fields, workspaceRoot: workspaceRoot)
                let providerRequestID = fields["tool_use_id"]?.stringValue
                    ?? fields["request_id"]?.stringValue
                    ?? fields["tool_call_id"]?.stringValue
                    ?? StableIdentifier.uuid("request:\(sessionID):\(eventName):\(now.timeIntervalSince1970)").uuidString
                let requestUUID = StableIdentifier.uuid("approval:\(provider.rawValue):\(providerRequestID)")
                let assessment = RiskClassifier().classify(RiskInput(action: action, workspaceRoot: workspaceRoot))
                let approval = ApprovalRequest(
                    id: ApprovalRequestID(requestUUID),
                    sessionID: sessionID,
                    providerRequestID: providerRequestID,
                    action: action,
                    risk: assessment,
                    createdAt: now,
                    expiresAt: now.addingTimeInterval(70),
                    revision: 1,
                    status: .received
                )
                let payload = (try? JSONValue.encoding(approval)) ?? .object(["state": .string("waitingApproval")])
                let decisionAllowed = capabilities.supports(.approveRequests) && !isAutoReviewed(fields)
                return NormalizedHookEvent(
                    eventType: "approval.requested",
                    payload: payload,
                    privacyClass: .sensitive,
                    decisions: decisionAllowed ? [DecisionMetadata(
                        id: requestUUID,
                        kind: .approval,
                        prompt: approvalPrompt(fields: fields),
                        choices: [],
                        maximumAnswerLength: nil,
                        eventType: "approval.requested",
                        payload: payload,
                        privacyClass: .sensitive,
                        providerQuestionID: nil
                    )] : []
                )
            }

            if provider == .claude, eventName == "Elicitation" {
                let prompt = fields["message"]?.stringValue ?? "Claude is waiting for input."
                let questionID = QuestionID(StableIdentifier.uuid("question:\(sessionID):\(prompt)"))
                let requestedSchema = fields["requested_schema"]
                let secret = requestedSchemaContainsSecret(requestedSchema)
                let choices = extractChoices(requestedSchema)
                let kind = questionKind(schema: requestedSchema, secret: secret, choices: choices)
                let maximumAnswerLength = extractMaximumLength(requestedSchema)
                let question = AgentQuestion(
                    id: questionID,
                    sessionID: sessionID,
                    kind: kind,
                    prompt: prompt,
                    choices: choices,
                    maximumAnswerLength: maximumAnswerLength
                )
                let payload = (try? JSONValue.encoding(question)) ?? .object(["prompt": .string(prompt)])
                let canAnswer = capabilities.supports(.answerQuestions) && !secret
                return NormalizedHookEvent(
                    eventType: "question.requested",
                    payload: payload,
                    privacyClass: secret ? .secret : .sensitive,
                    decisions: canAnswer ? [DecisionMetadata(
                        id: questionID.rawValue,
                        kind: .question,
                        prompt: prompt,
                        choices: question.choices,
                        maximumAnswerLength: maximumAnswerLength,
                        eventType: "question.requested",
                        payload: payload,
                        privacyClass: .sensitive,
                        providerQuestionID: nil
                    )] : []
                )
            }

            let state = state(for: provider, event: eventName, fields: fields)
            return NormalizedHookEvent(
                eventType: "session.stateChanged",
                payload: .object(["state": .string(state.rawValue)]),
                privacyClass: .privateMetadata,
                decisions: []
            )
        }

        private func requestUserInputDecisions(
            fields: [String: JSONValue],
            sessionID: SessionID,
            now: Date
        ) -> [DecisionMetadata]? {
            let toolInput = fields["tool_input"] ?? fields["toolInput"]
            guard case let .array(rawQuestions)? = toolInput?["questions"],
                  (1 ... 3).contains(rawQuestions.count)
            else { return nil }
            guard !rawQuestions.contains(where: isSecretQuestion) else { return nil }

            let requestToken = fields["tool_use_id"]?.stringValue
                ?? fields["tool_call_id"]?.stringValue
                ?? fields["call_id"]?.stringValue
                ?? String(Int64(now.timeIntervalSince1970 * 1_000_000))
            var seenQuestionIDs = Set<String>()
            var decisions: [DecisionMetadata] = []
            decisions.reserveCapacity(rawQuestions.count)
            for (questionIndex, rawQuestion) in rawQuestions.enumerated() {
                guard let decision = requestUserInputDecision(
                    rawQuestion,
                    index: questionIndex,
                    sessionID: sessionID,
                    requestToken: requestToken,
                    seenQuestionIDs: &seenQuestionIDs
                ) else { return nil }
                decisions.append(decision)
            }
            return decisions
        }

        private func requestUserInputDecision(
            _ rawQuestion: JSONValue,
            index: Int,
            sessionID: SessionID,
            requestToken: String,
            seenQuestionIDs: inout Set<String>
        ) -> DecisionMetadata? {
            guard let providerQuestionID = rawQuestion["id"]?.stringValue,
                  !providerQuestionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seenQuestionIDs.insert(providerQuestionID).inserted,
                  let header = rawQuestion["header"]?.stringValue,
                  !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let prompt = rawQuestion["question"]?.stringValue,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let choices = requestUserInputChoices(
                      rawQuestion["options"],
                      sessionID: sessionID,
                      requestToken: requestToken,
                      providerQuestionID: providerQuestionID
                  )
            else { return nil }
            let isOther: Bool = switch rawQuestion["isOther"] ?? rawQuestion["is_other"] {
            case let .bool(value): value
            default: !choices.isEmpty
            }
            let questionUUID = StableIdentifier.uuid(
                "question:codex:\(sessionID):\(requestToken):\(providerQuestionID):\(index)"
            )
            let question = AgentQuestion(
                id: QuestionID(questionUUID), sessionID: sessionID,
                kind: choices.isEmpty ? .freeText : .singleChoice,
                header: header, prompt: prompt, choices: choices,
                isOther: isOther, maximumAnswerLength: 4000
            )
            guard let payload = try? JSONValue.encoding(question) else { return nil }
            return DecisionMetadata(
                id: questionUUID, kind: .question, prompt: prompt, choices: choices,
                maximumAnswerLength: 4000, eventType: "question.requested", payload: payload,
                privacyClass: .sensitive, providerQuestionID: providerQuestionID
            )
        }

        private func requestUserInputChoices(
            _ value: JSONValue?,
            sessionID: SessionID,
            requestToken: String,
            providerQuestionID: String
        ) -> [QuestionChoice]? {
            let rawOptions: [JSONValue]
            switch value {
            case let .array(values): rawOptions = values
            case .none, .null: rawOptions = []
            default: return nil
            }
            guard rawOptions.count <= 3 else { return nil }
            var choices: [QuestionChoice] = []
            for (index, rawOption) in rawOptions.enumerated() {
                guard let label = rawOption["label"]?.stringValue,
                      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                let choiceID = StableIdentifier.uuid(
                    "choice:codex:\(sessionID):\(requestToken):\(providerQuestionID):\(index):\(label)"
                ).uuidString.lowercased()
                choices.append(QuestionChoice(
                    id: choiceID, label: label, description: rawOption["description"]?.stringValue
                ))
            }
            return choices
        }

        private func isSecretQuestion(_ question: JSONValue) -> Bool {
            question["isSecret"] == .bool(true)
                || question["is_secret"] == .bool(true)
                || question["secret"] == .bool(true)
                || question["kind"]?.stringValue?.lowercased() == "secret"
        }

        private func isApprovalEvent(provider: HookProvider, event: String, fields: [String: JSONValue]) -> Bool {
            switch provider {
            case .codex, .claude: event == "PermissionRequest"
            case .gemini: event == "BeforeTool" && fields["requires_approval"] == .bool(true)
            case .generic: event.lowercased().contains("approval")
            }
        }

        private func isAutoReviewed(_ fields: [String: JSONValue]) -> Bool {
            let mode = fields["permission_mode"]?.stringValue?.lowercased() ?? ""
            return ["acceptedits", "dontask", "bypasspermissions", "yolo", "auto_edit"].contains(mode)
                || fields["auto_approved"] == .bool(true)
        }

        private func state(for provider: HookProvider, event: String, fields: [String: JSONValue]) -> SessionState {
            switch event {
            case "SessionStart": return .starting
            case "UserPromptSubmit", "BeforeAgent": return .thinking
            case "PreToolUse", "BeforeTool": return .executing
            case "PostToolUse", "AfterTool": return .running
            case "Notification":
                let type = fields["notification_type"]?.stringValue?.lowercased() ?? ""
                return type.contains("permission") ? .waitingApproval : .running
            case "Stop", "AfterAgent", "SessionEnd": return .completed
            case "StopFailure": return .failed
            default:
                if provider == .generic, let raw = fields["state"]?.stringValue, let state = SessionState(rawValue: raw) {
                    return state
                }
                return .running
            }
        }

        private func action(from fields: [String: JSONValue], workspaceRoot: URL) -> AgentAction {
            let toolName = fields["tool_name"]?.stringValue ?? fields["toolName"]?.stringValue ?? "unknown"
            let input = fields["tool_input"] ?? fields["toolInput"]
            if let command = input?["command"]?.stringValue ?? fields["command"]?.stringValue {
                return .executeCommand(ParsedCommand(
                    executable: URL(fileURLWithPath: "/bin/zsh"),
                    arguments: ["-lc", command],
                    workingDirectory: workspaceRoot
                ))
            }
            if ["Edit", "Write", "apply_patch", "write_file", "replace"].contains(toolName) {
                let path = input?["file_path"]?.stringValue ?? input?["path"]?.stringValue ?? workspaceRoot.path
                return .modifyFiles(FileChangeSummary(paths: [URL(fileURLWithPath: path)], operation: .write))
            }
            let readOnly = ["Read", "Glob", "Grep", "read_file", "list_directory"].contains(toolName)
            return .useTool(ToolInvocationSummary(name: toolName, isReadOnly: readOnly))
        }

        private func approvalPrompt(fields: [String: JSONValue]) -> String {
            let tool = fields["tool_name"]?.stringValue ?? "tool"
            let command = fields["tool_input"]?["command"]?.stringValue
            return command.map { "Allow \(tool): \($0)" } ?? "Allow \(tool)?"
        }

        private func requestedSchemaContainsSecret(_ schema: JSONValue?) -> Bool {
            guard let schema else { return false }
            switch schema {
            case let .object(values):
                return values.contains { key, value in
                    ["password", "secret", "token"].contains(where: key.lowercased().contains)
                        || requestedSchemaContainsSecret(value)
                }
            case let .array(values): return values.contains(where: { requestedSchemaContainsSecret($0) })
            case let .string(value): return value.lowercased() == "password"
            case .number, .bool, .null: return false
            }
        }

        private func extractChoices(_ schema: JSONValue?) -> [String] {
            guard let schema else { return [] }
            if case let .array(values)? = schema["enum"] {
                return values.compactMap(\.stringValue)
            }
            if case let .object(properties)? = schema["properties"] {
                for property in properties.values {
                    let choices = extractChoices(property)
                    if !choices.isEmpty {
                        return choices
                    }
                }
            }
            if let items = schema["items"] {
                return extractChoices(items)
            }
            return []
        }

        private func questionKind(schema: JSONValue?, secret: Bool, choices: [String]) -> QuestionKind {
            if secret {
                return .secret
            }
            let type = schema?["type"]?.stringValue?.lowercased()
            if type == "boolean" {
                return .confirmation
            }
            if type == "array", !choices.isEmpty {
                return .multiChoice
            }
            if !choices.isEmpty {
                return .singleChoice
            }
            return .freeText
        }

        private func extractMaximumLength(_ schema: JSONValue?) -> Int? {
            guard let schema else { return nil }
            if case let .number(value)? = schema["maxLength"], value.rounded() == value, value > 0 {
                return min(Int(value), 100_000)
            }
            if case let .object(properties)? = schema["properties"] {
                return properties.values.compactMap(extractMaximumLength).min()
            }
            return nil
        }

        private func parseDate(_ value: String?) -> Date? {
            value.flatMap { ISO8601DateFormatter().date(from: $0) }
        }
    }

    private struct NormalizedHookEvent: Sendable {
        let eventType: String
        let payload: JSONValue
        let privacyClass: PrivacyClass
        let decisions: [DecisionMetadata]
    }

    private struct DecisionMetadata: Sendable {
        let id: UUID
        let kind: HookDecisionKind
        let prompt: String
        let choices: [QuestionChoice]
        let maximumAnswerLength: Int?
        let eventType: String
        let payload: JSONValue
        let privacyClass: PrivacyClass
        let providerQuestionID: String?
    }

    private enum StableIdentifier {
        static func uuid(_ value: String) -> UUID {
            var first: UInt64 = 14_695_981_039_346_656_037
            var second: UInt64 = 1_099_511_628_211
            for byte in value.utf8 {
                first = (first ^ UInt64(byte)) &* 1_099_511_628_211
                second = (second &* 1_099_511_628_211) ^ UInt64(byte)
            }
            var bytes = withUnsafeBytes(of: first.bigEndian, Array.init) + withUnsafeBytes(of: second.bigEndian, Array.init)
            bytes[6] = (bytes[6] & 0x0F) | 0x50
            bytes[8] = (bytes[8] & 0x3F) | 0x80
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
    }
#endif
