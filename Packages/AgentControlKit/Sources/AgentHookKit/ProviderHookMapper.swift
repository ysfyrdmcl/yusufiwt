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
        public let additionalSubmissions: [HelperEventSubmission]
        public let decisionRequests: [HookDecisionRequest]
        public let providerQuestionIDs: [String]
        public let originalToolInput: JSONValue?

        public var decisionRequest: HookDecisionRequest? {
            decisionRequests.first
        }

        public var submissions: [HelperEventSubmission] {
            [submission] + additionalSubmissions
        }

        public init(
            provider: HookProvider,
            eventName: String,
            submission: HelperEventSubmission,
            additionalSubmissions: [HelperEventSubmission] = [],
            decisionRequests: [HookDecisionRequest] = [],
            providerQuestionIDs: [String] = [],
            originalToolInput: JSONValue? = nil
        ) {
            self.provider = provider
            self.eventName = eventName
            self.submission = submission
            self.additionalSubmissions = additionalSubmissions
            self.decisionRequests = decisionRequests
            self.providerQuestionIDs = providerQuestionIDs
            self.originalToolInput = originalToolInput
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
                ?? (provider == .cursor && eventName == "workspaceOpen"
                    ? "workspace:\(firstWorkspaceRoot(fields) ?? environment["PWD"] ?? "/private/tmp")"
                    : nil)
                ?? "process-\(ProcessInfo.processInfo.processIdentifier)"
            let cwd = fields["cwd"]?.stringValue
                ?? firstWorkspaceRoot(fields)
                ?? environment["PWD"]
                ?? "/private/tmp"
            let sessionID = SessionID(StableIdentifier.uuid("session:\(provider.rawValue):\(providerSessionID)"))
            let nodeID = environment["AGENTCONTROL_NODE_ID"].flatMap(UUID.init(uuidString:)).map(NodeID.init)
                ?? NodeID(StableIdentifier.uuid("node:\(ProcessInfo.processInfo.hostName)"))
            let projectID = ProjectID(StableIdentifier.uuid("project:\(cwd)"))
            let versionText = environment["AGENTCONTROL_PROVIDER_VERSION"]
                ?? fields["provider_version"]?.stringValue
                ?? fields["cursor_version"]?.stringValue
            let version = versionText.flatMap(ProviderVersion.init)
            let capabilities = compatibility.capabilities(for: provider, version: version)
            let adapterVersion = version?.description ?? "unknown"
            let occurredAt = parseDate(fields["timestamp"]?.stringValue) ?? now
            let sequence = structuredSequence(fields)
                ?? Int64(occurredAt.timeIntervalSince1970 * 1_000_000)
            let revision = requestRevision(fields)
            let providerEventToken = eventIdentityToken(fields: fields, eventName: eventName)
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
                // Managed hook commands are short-lived processes. Omitting their
                // transient PID keeps provider sequence ordering stable across invocations.
                processID: nil
            )
            let correlationID = EnvelopeID(StableIdentifier.uuid("correlation:\(provider.rawValue):\(providerSessionID)"))
            func envelope(
                eventType: String,
                payload: JSONValue,
                privacyClass: PrivacyClass,
                sequenceOffset: Int64 = 0,
                identity: String? = nil
            ) -> EventEnvelope {
                EventEnvelope(
                    eventID: EventID(StableIdentifier.uuid(
                        "event:\(provider.rawValue):\(providerSessionID):\(eventName):\(identity ?? providerEventToken)"
                    )),
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
                    privacyClass: normalized.privacyClass,
                    sequenceOffset: 0,
                    identity: "base:\(providerEventToken)"
                ),
                initialSession: session
            )
            let requests = normalized.decisions.enumerated().map { index, metadata in
                let submission = HelperEventSubmission(
                    envelope: envelope(
                        eventType: metadata.eventType,
                        payload: metadata.payload,
                        privacyClass: metadata.privacyClass,
                        sequenceOffset: Int64(index),
                        identity: "decision:\(metadata.id.uuidString):\(revision)"
                    ),
                    initialSession: session
                )
                return HookDecisionRequest(
                    requestID: metadata.id,
                    revision: revision,
                    kind: metadata.kind,
                    prompt: metadata.prompt,
                    choices: metadata.choices,
                    maximumAnswerLength: metadata.maximumAnswerLength,
                    expiresAt: now.addingTimeInterval(70),
                    waitTimeoutMilliseconds: 60000,
                    submission: submission
                )
            }
            let statusSubmission = normalized.providerStatus.map { status in
                var payload: [String: JSONValue] = [
                    "id": .string(status.requestID.uuidString.lowercased()),
                    "revision": .number(Double(status.revision)),
                    "status": .string(status.status.rawValue)
                ]
                if let resolutionSource = status.resolutionSource {
                    payload["resolutionSource"] = .string(resolutionSource)
                }
                return HelperEventSubmission(
                    envelope: envelope(
                        eventType: "approval.statusChanged",
                        payload: .object(payload),
                        privacyClass: .privateMetadata,
                        sequenceOffset: 1,
                        identity: "status:\(status.requestID.uuidString):\(status.revision):\(status.status.rawValue)"
                    ),
                    initialSession: session
                )
            }
            return ProviderHookMapping(
                provider: provider,
                eventName: eventName,
                submission: requests.first?.submission ?? baseSubmission,
                additionalSubmissions: requests.isEmpty ? statusSubmission.map { [$0] } ?? [] : [],
                decisionRequests: requests,
                providerQuestionIDs: normalized.decisions.compactMap(\.providerQuestionID),
                originalToolInput: fields["tool_input"] ?? fields["toolInput"]
            )
        }

        public func providerOutput(for response: HelperResponse, mapping: ProviderHookMapping) -> JSONValue {
            if mapping.decisionRequests.count > 1 || !mapping.providerQuestionIDs.isEmpty {
                return providerOutput(for: [response], mapping: mapping)
            }
            return singleProviderOutput(for: response, mapping: mapping)
        }

        public func providerOutput(for responses: [HelperResponse], mapping: ProviderHookMapping) -> JSONValue {
            if mapping.provider == .codex,
               mapping.eventName == "PreToolUse",
               !mapping.providerQuestionIDs.isEmpty {
                return codexQuestionOutput(for: responses, mapping: mapping)
            }
            if mapping.provider == .claude,
               mapping.eventName == "PreToolUse",
               !mapping.providerQuestionIDs.isEmpty {
                return claudeQuestionOutput(for: responses, mapping: mapping)
            }
            guard responses.count == 1, let response = responses.first else { return .object([:]) }
            return singleProviderOutput(for: response, mapping: mapping)
        }

        private func codexQuestionOutput(
            for responses: [HelperResponse],
            mapping: ProviderHookMapping
        ) -> JSONValue {
            guard responses.count == mapping.decisionRequests.count,
                  mapping.providerQuestionIDs.count == responses.count
            else { return .object([:]) }
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

        private func claudeQuestionOutput(
            for responses: [HelperResponse],
            mapping: ProviderHookMapping
        ) -> JSONValue {
            guard responses.count == mapping.decisionRequests.count,
                  mapping.providerQuestionIDs.count == responses.count,
                  case var .object(updatedInput)? = mapping.originalToolInput
            else { return .object([:]) }
            var answers: [String: JSONValue] = [:]
            for index in responses.indices {
                guard case let .decision(result) = responses[index],
                      let values = answerValues(result.decision, request: mapping.decisionRequests[index])
                else { return .object([:]) }
                answers[mapping.providerQuestionIDs[index]] = .string(values.joined(separator: ", "))
            }
            updatedInput["answers"] = .object(answers)
            return .object([
                "hookSpecificOutput": .object([
                    "hookEventName": .string("PreToolUse"),
                    "permissionDecision": .string("allow"),
                    "permissionDecisionReason": .string("User answers collected by yusufiwt."),
                    "updatedInput": .object(updatedInput)
                ])
            ])
        }

        private func singleProviderOutput(for response: HelperResponse, mapping: ProviderHookMapping) -> JSONValue {
            guard case let .decision(result) = response else {
                return neutralProviderOutput(mapping: mapping)
            }
            return decisionProviderOutput(result.decision, mapping: mapping)
        }

        private func neutralProviderOutput(mapping: ProviderHookMapping) -> JSONValue {
            guard mapping.provider == .cursor,
                  ["beforeShellExecution", "beforeMCPExecution"].contains(mapping.eventName)
            else { return .object([:]) }
            return .object([
                "permission": .string("ask"),
                "user_message": .string("yusufiwt is unavailable; review this request in Cursor."),
                "agent_message": .string("Use Cursor's native permission flow.")
            ])
        }

        private func decisionProviderOutput(_ decision: HookDecision, mapping: ProviderHookMapping) -> JSONValue {
            switch decision {
            case .approve:
                return approvalOutput(mapping: mapping, behavior: "allow")
            case .deny:
                return approvalOutput(mapping: mapping, behavior: "deny")
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
            guard let propertyKey = mapping.providerQuestionIDs.first else { return .object([:]) }
            return .object([
                "hookSpecificOutput": .object([
                    "hookEventName": .string("Elicitation"),
                    "action": .string("accept"),
                    "content": .object([propertyKey: answer])
                ])
            ])
        }

        private func approvalOutput(mapping: ProviderHookMapping, behavior: String) -> JSONValue {
            switch mapping.provider {
            case .codex:
                .object([
                    "hookSpecificOutput": .object([
                        "hookEventName": .string(mapping.eventName),
                        "decision": .object([
                            "behavior": .string(behavior),
                            "message": .string(behavior == "deny" ? "Denied in yusufiwt." : "Approved in yusufiwt.")
                        ])
                    ])
                ])
            case .claude:
                claudeApprovalOutput(mapping: mapping, behavior: behavior)
            case .gemini:
                .object([
                    "decision": .string(behavior),
                    "reason": .string(behavior == "deny" ? "Denied in yusufiwt." : "Approved in yusufiwt."),
                    "suppressOutput": .bool(true)
                ])
            case .cursor:
                .object([
                    "permission": .string(behavior),
                    "user_message": .string(behavior == "deny" ? "Denied in yusufiwt." : "Approved in yusufiwt."),
                    "agent_message": .string(behavior == "deny" ? "The user denied this request." : "The user approved this request.")
                ])
            case .generic:
                .object([:])
            }
        }

        private func claudeApprovalOutput(mapping: ProviderHookMapping, behavior: String) -> JSONValue {
            if mapping.eventName == "PreToolUse" {
                var output: [String: JSONValue] = [
                    "hookEventName": .string("PreToolUse"),
                    "permissionDecision": .string(behavior),
                    "permissionDecisionReason": .string(
                        behavior == "deny" ? "Denied in yusufiwt." : "Approved in yusufiwt."
                    )
                ]
                if behavior == "allow" {
                    guard case .object? = mapping.originalToolInput,
                          let originalToolInput = mapping.originalToolInput
                    else { return .object([:]) }
                    output["updatedInput"] = originalToolInput
                }
                return .object(["hookSpecificOutput": .object(output)])
            }
            return .object([
                "hookSpecificOutput": .object([
                    "hookEventName": .string(mapping.eventName),
                    "decision": .object([
                        "behavior": .string(behavior),
                        "message": .string(behavior == "deny" ? "Denied in yusufiwt." : "Approved in yusufiwt.")
                    ])
                ])
            ])
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
               capabilities.supports(.answerQuestions),
               let decisions = requestUserInputDecisions(fields: fields, sessionID: sessionID, now: now),
               let first = decisions.first {
                return NormalizedHookEvent(
                    eventType: first.eventType,
                    payload: first.payload,
                    privacyClass: first.privacyClass,
                    decisions: decisions
                )
            }

            if provider == .claude,
               eventName == "PreToolUse",
               normalizedToken(fields["tool_name"]?.stringValue ?? fields["toolName"]?.stringValue ?? "")
               == "askuserquestion",
               capabilities.supports(.answerQuestions),
               let decisions = claudeAskUserQuestionDecisions(fields: fields, sessionID: sessionID),
               let first = decisions.first {
                return NormalizedHookEvent(
                    eventType: first.eventType,
                    payload: first.payload,
                    privacyClass: first.privacyClass,
                    decisions: decisions
                )
            }

            let providerRequestID = providerRequestIdentifier(
                fields: fields,
                namespace: "\(provider.rawValue):\(sessionID)",
                fallback: "\(sessionID):\(eventName):\(now.timeIntervalSince1970)"
            )
            let requestUUID = StableIdentifier.uuid("approval:\(provider.rawValue):\(providerRequestID)")
            let revision = requestRevision(fields)

            if let providerStatus = providerStatus(
                provider: provider,
                event: eventName,
                fields: fields,
                requestID: requestUUID,
                revision: revision
            ) {
                let state = eventName == "PermissionRequest"
                    ? SessionState.executing
                    : state(for: provider, event: eventName, fields: fields)
                return NormalizedHookEvent(
                    eventType: "session.stateChanged",
                    payload: .object(["state": .string(state.rawValue)]),
                    privacyClass: .privateMetadata,
                    decisions: [],
                    providerStatus: providerStatus
                )
            }

            if isDecisionRequestEvent(provider: provider, event: eventName, fields: fields),
               capabilities.supports(.approveRequests),
               !isAutoReviewed(provider: provider, event: eventName, fields: fields) {
                let kind = decisionKind(provider: provider, event: eventName, fields: fields)
                if kind == .plan {
                    let title = planPrompt(provider: provider, fields: fields)
                    let payload: JSONValue = .object([
                        "title": .string(title),
                        "allowsPlanChanges": .bool(false)
                    ])
                    return NormalizedHookEvent(
                        eventType: "plan.reviewRequested",
                        payload: payload,
                        privacyClass: .sensitive,
                        decisions: [DecisionMetadata(
                            id: requestUUID,
                            kind: .plan,
                            prompt: title,
                            choices: [],
                            maximumAnswerLength: nil,
                            eventType: "plan.reviewRequested",
                            payload: payload,
                            privacyClass: .sensitive,
                            providerQuestionID: nil
                        )]
                    )
                }

                let action = action(from: fields, workspaceRoot: workspaceRoot)
                let assessment = RiskClassifier().classify(RiskInput(action: action, workspaceRoot: workspaceRoot))
                let approval = ApprovalRequest(
                    id: ApprovalRequestID(requestUUID),
                    sessionID: sessionID,
                    providerRequestID: providerRequestID,
                    action: action,
                    risk: assessment,
                    createdAt: now,
                    expiresAt: now.addingTimeInterval(70),
                    revision: revision,
                    status: .received
                )
                let payload = (try? JSONValue.encoding(approval)) ?? .object(["state": .string("waitingApproval")])
                return NormalizedHookEvent(
                    eventType: "approval.requested",
                    payload: payload,
                    privacyClass: .sensitive,
                    decisions: [DecisionMetadata(
                        id: requestUUID,
                        kind: .approval,
                        prompt: approvalPrompt(fields: fields),
                        choices: [],
                        maximumAnswerLength: nil,
                        eventType: "approval.requested",
                        payload: payload,
                        privacyClass: .sensitive,
                        providerQuestionID: nil
                    )]
                )
            }

            if provider == .claude, eventName == "Elicitation" {
                let prompt = fields["message"]?.stringValue ?? "Claude is waiting for input."
                let elicitationToken = fields["elicitation_id"]?.stringValue ?? prompt
                let questionID = QuestionID(StableIdentifier.uuid(
                    "question:claude-elicitation:\(sessionID):\(elicitationToken)"
                ))
                let requestedSchema = fields["requested_schema"]
                let secret = requestedSchemaContainsSecret(requestedSchema)
                if secret {
                    return NormalizedHookEvent(
                        eventType: "session.stateChanged",
                        payload: .object(["state": .string(SessionState.waitingInput.rawValue)]),
                        privacyClass: .privateMetadata,
                        decisions: []
                    )
                }
                let choices = extractChoices(requestedSchema)
                let kind = questionKind(schema: requestedSchema, secret: secret, choices: choices)
                let maximumAnswerLength = extractMaximumLength(requestedSchema)
                // Older Claude builds emitted the value schema directly. Keep a
                // conservative `value` key fallback while preferring the current
                // object-schema property contract.
                let propertyKey = requestedSchemaPropertyKey(requestedSchema) ?? "value"
                let question = AgentQuestion(
                    id: questionID,
                    sessionID: sessionID,
                    kind: kind,
                    prompt: prompt,
                    choices: choices,
                    maximumAnswerLength: maximumAnswerLength
                )
                let payload = (try? JSONValue.encoding(question)) ?? .object(["prompt": .string(prompt)])
                let canAnswer = capabilities.supports(.answerQuestions)
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
                        providerQuestionID: propertyKey
                    )] : []
                )
            }

            let state = state(for: provider, event: eventName, fields: fields)
            let usageMetrics = ProviderUsageMapper().metrics(
                provider: provider.adapterID,
                fields: fields,
                updatedAt: parseDate(fields["timestamp"]?.stringValue) ?? now
            )
            if !usageMetrics.isEmpty,
               let payload = try? JSONValue.encoding(SessionUsageUpdate(
                   metrics: usageMetrics,
                   concurrentState: state
               )) {
                return NormalizedHookEvent(
                    eventType: "session.usageUpdated",
                    payload: payload,
                    privacyClass: .publicMetadata,
                    decisions: []
                )
            }
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

        private func claudeAskUserQuestionDecisions(
            fields: [String: JSONValue],
            sessionID: SessionID
        ) -> [DecisionMetadata]? {
            let toolInput = fields["tool_input"] ?? fields["toolInput"]
            guard case let .array(rawQuestions)? = toolInput?["questions"],
                  (1 ... 4).contains(rawQuestions.count),
                  !rawQuestions.contains(where: isSecretQuestion)
            else { return nil }
            let encodedQuestions = compactJSONString(.array(rawQuestions)) ?? "unavailable"
            let requestToken = fields["tool_use_id"]?.stringValue
                ?? fields["tool_call_id"]?.stringValue
                ?? fields["call_id"]?.stringValue
                ?? StableIdentifier.uuid("claude-ask:\(sessionID):\(encodedQuestions)").uuidString
            var seenPrompts = Set<String>()
            var decisions: [DecisionMetadata] = []
            decisions.reserveCapacity(rawQuestions.count)
            for (index, rawQuestion) in rawQuestions.enumerated() {
                guard let prompt = rawQuestion["question"]?.stringValue,
                      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      seenPrompts.insert(prompt).inserted,
                      let decision = claudeQuestionDecision(
                          rawQuestion: rawQuestion,
                          prompt: prompt,
                          index: index,
                          sessionID: sessionID,
                          requestToken: requestToken
                      )
                else { return nil }
                decisions.append(decision)
            }
            return decisions
        }

        private func claudeQuestionDecision(
            rawQuestion: JSONValue,
            prompt: String,
            index: Int,
            sessionID: SessionID,
            requestToken: String
        ) -> DecisionMetadata? {
            guard let header = rawQuestion["header"]?.stringValue,
                  !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  case let .array(rawOptions)? = rawQuestion["options"],
                  !rawOptions.isEmpty,
                  rawOptions.count <= 8
            else { return nil }
            var choices: [QuestionChoice] = []
            choices.reserveCapacity(rawOptions.count)
            for (choiceIndex, rawOption) in rawOptions.enumerated() {
                guard let label = rawOption["label"]?.stringValue,
                      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                choices.append(QuestionChoice(
                    id: StableIdentifier.uuid(
                        "choice:claude:\(sessionID):\(requestToken):\(index):\(choiceIndex):\(label)"
                    ).uuidString.lowercased(),
                    label: label,
                    description: rawOption["description"]?.stringValue
                ))
            }
            let questionUUID = StableIdentifier.uuid(
                "question:claude:\(sessionID):\(requestToken):\(index):\(prompt)"
            )
            let question = AgentQuestion(
                id: QuestionID(questionUUID),
                sessionID: sessionID,
                kind: rawQuestion["multiSelect"] == .bool(true) ? .multiChoice : .singleChoice,
                header: header,
                prompt: prompt,
                choices: choices,
                isOther: true,
                maximumAnswerLength: 4000
            )
            guard let payload = try? JSONValue.encoding(question) else { return nil }
            return DecisionMetadata(
                id: questionUUID,
                kind: .question,
                prompt: prompt,
                choices: choices,
                maximumAnswerLength: 4000,
                eventType: "question.requested",
                payload: payload,
                privacyClass: .sensitive,
                providerQuestionID: prompt
            )
        }

        private func isSecretQuestion(_ question: JSONValue) -> Bool {
            if question["isSecret"] == .bool(true)
                || question["is_secret"] == .bool(true)
                || question["secret"] == .bool(true)
                || question["kind"]?.stringValue?.lowercased() == "secret" {
                return true
            }
            let text = [question["header"]?.stringValue, question["question"]?.stringValue]
                .compactMap(\.self)
                .joined(separator: " ")
                .lowercased()
            return [
                "password", "passphrase", "api key", "access token", "secret", "credential",
                "private key", "one-time code", "otp", "parola", "şifre"
            ].contains(where: text.contains)
        }

        private func isDecisionRequestEvent(
            provider: HookProvider,
            event: String,
            fields: [String: JSONValue]
        ) -> Bool {
            switch provider {
            case .codex:
                return event == "PermissionRequest"
            case .claude:
                let tool = normalizedToken(fields["tool_name"]?.stringValue ?? fields["toolName"]?.stringValue ?? "")
                return event == "PermissionRequest" || (event == "PreToolUse" && tool == "exitplanmode")
            case .gemini:
                guard event == "BeforeTool" else { return false }
                return geminiToolRequiresDecision(fields)
            case .cursor:
                if event == "beforeShellExecution" || event == "beforeMCPExecution" {
                    return true
                }
                guard event == "preToolUse" else { return false }
                let tool = normalizedToken(
                    fields["tool_name"]?.stringValue ?? fields["toolName"]?.stringValue ?? ""
                )
                return ["write", "delete", "task"].contains(tool)
            case .generic:
                // Generic events are monitor-only. An event name or free-text field
                // containing "approval" is not a structured response contract.
                return false
            }
        }

        private func decisionKind(
            provider: HookProvider,
            event _: String,
            fields: [String: JSONValue]
        ) -> HookDecisionKind {
            let tool = normalizedToken(fields["tool_name"]?.stringValue ?? fields["toolName"]?.stringValue ?? "")
            if provider == .claude, tool == "exitplanmode" {
                return .plan
            }
            if provider == .gemini, tool == "exitplanmode" {
                return .plan
            }
            return .approval
        }

        private func geminiToolRequiresDecision(_ fields: [String: JSONValue]) -> Bool {
            let tool = normalizedToken(fields["tool_name"]?.stringValue ?? fields["toolName"]?.stringValue ?? "")
            let readOnly: Set = [
                "readfile", "listdirectory", "glob", "grep", "searchfilecontent", "readmanyfiles",
                "webfetch", "googlesearch"
            ]
            return !tool.isEmpty && !readOnly.contains(tool)
        }

        private func providerStatus(
            provider: HookProvider,
            event: String,
            fields: [String: JSONValue],
            requestID: UUID,
            revision: Int64
        ) -> ProviderStatusMetadata? {
            if let status = providerLifecycleStatus(provider: provider, event: event, fields: fields) {
                return ProviderStatusMetadata(
                    requestID: requestID,
                    revision: revision,
                    status: status,
                    resolutionSource: status == .applied && isAutoReviewed(provider: provider, event: event, fields: fields)
                        ? "providerAutomation"
                        : nil
                )
            }

            guard provider != .generic else { return nil }
            let status = structuredProviderStatus(provider: provider, event: event, fields: fields)
            return status.map {
                ProviderStatusMetadata(
                    requestID: requestID,
                    revision: revision,
                    status: $0,
                    resolutionSource: isAutoReviewed(provider: provider, event: event, fields: fields)
                        ? "providerAutomation"
                        : nil
                )
            }
        }

        private func providerLifecycleStatus(
            provider: HookProvider,
            event: String,
            fields: [String: JSONValue]
        ) -> ApprovalStatus? {
            if provider == .claude, event == "PermissionDenied" {
                return .providerRejected
            }
            if provider == .cursor, event == "postToolUseFailure",
               normalizedToken(fields["failure_type"]?.stringValue ?? "") == "permissiondenied" {
                return .providerRejected
            }
            if provider == .gemini, event == "AfterTool", fields["tool_response"]?["error"] != nil {
                return .providerRejected
            }
            let isPostAction = switch provider {
            case .codex, .claude: event == "PostToolUse"
            case .gemini: event == "AfterTool"
            case .cursor:
                event == "postToolUse" || event == "afterShellExecution" || event == "afterMCPExecution"
            case .generic: false
            }
            return isPostAction ? .applied : nil
        }

        private func structuredProviderStatus(
            provider: HookProvider,
            event: String,
            fields: [String: JSONValue]
        ) -> ApprovalStatus? {
            let structured = [
                fields["approval_status"]?.stringValue,
                fields["permission_status"]?.stringValue,
                fields["decision_status"]?.stringValue,
                fields["permission_decision"]?.stringValue,
                fields["outcome"]?.stringValue
            ].compactMap(\.self).map(normalizedToken)
            if isAutoReviewed(provider: provider, event: event, fields: fields) {
                return .sentToProvider
            }
            if fields["already_approved"] == .bool(true)
                || fields["user_approved"] == .bool(true)
                || structured.contains(where: { ["approved", "allow", "allowed", "acknowledged"].contains($0) }) {
                return .providerAcknowledged
            }
            if fields["cancelled"] == .bool(true)
                || structured.contains(where: { ["cancelled", "canceled"].contains($0) }) {
                return .cancelledByProvider
            }
            if fields["expired"] == .bool(true) || structured.contains("expired") {
                return .expired
            }
            if fields["denied"] == .bool(true)
                || structured.contains(where: { ["denied", "deny", "rejected"].contains($0) }) {
                return .providerRejected
            }
            return nil
        }

        private func isAutoReviewed(
            provider: HookProvider,
            event: String,
            fields: [String: JSONValue]
        ) -> Bool {
            guard isToolLifecycleEvent(provider: provider, event: event) else { return false }
            if fields["auto_approved"] == .bool(true) || fields["requires_user_action"] == .bool(false) {
                return true
            }
            let mode = normalizedToken(fields["permission_mode"]?.stringValue ?? "")
            if ["bypasspermissions", "yolo"].contains(mode) {
                return true
            }
            guard ["acceptedits", "autoedit"].contains(mode) else { return false }
            let tool = normalizedToken(fields["tool_name"]?.stringValue ?? fields["toolName"]?.stringValue ?? "")
            return ["edit", "write", "applypatch", "writefile", "replace", "multiedit", "notebookedit"]
                .contains(tool)
        }

        private func isToolLifecycleEvent(provider: HookProvider, event: String) -> Bool {
            switch provider {
            case .codex, .claude:
                ["PreToolUse", "PermissionRequest", "PostToolUse", "PermissionDenied"].contains(event)
            case .gemini:
                event == "BeforeTool" || event == "AfterTool"
            case .cursor:
                [
                    "preToolUse", "postToolUse", "postToolUseFailure", "beforeShellExecution",
                    "beforeMCPExecution", "afterShellExecution", "afterMCPExecution"
                ].contains(event)
            case .generic:
                false
            }
        }

        private func state(for provider: HookProvider, event: String, fields: [String: JSONValue]) -> SessionState {
            if let state = cursorTerminalState(provider: provider, event: event, fields: fields) {
                return state
            }
            if let state = lifecycleState(provider: provider, event: event, fields: fields) {
                return state
            }
            if provider == .generic,
               let raw = fields["state"]?.stringValue,
               let state = SessionState(rawValue: raw) {
                return state
            }
            return .running
        }

        private func cursorTerminalState(
            provider: HookProvider,
            event: String,
            fields: [String: JSONValue]
        ) -> SessionState? {
            guard provider == .cursor, ["stop", "sessionEnd"].contains(event) else { return nil }
            switch normalizedToken(fields["status"]?.stringValue ?? fields["reason"]?.stringValue ?? "") {
            case "error", "failed", "failure": return .failed
            case "aborted", "cancelled", "canceled": return .cancelled
            default: return .completed
            }
        }

        private func lifecycleState(
            provider: HookProvider,
            event: String,
            fields: [String: JSONValue]
        ) -> SessionState? {
            switch event {
            case "SessionStart", "Setup", "sessionStart", "workspaceOpen": .starting
            case "UserPromptSubmit", "BeforeAgent", "BeforeModel", "BeforeToolSelection",
                 "UserPromptExpansion", "beforeSubmitPrompt", "afterAgentThought": .thinking
            case "PreToolUse", "BeforeTool", "preToolUse", "beforeShellExecution", "beforeMCPExecution",
                 "beforeReadFile", "beforeTabFileRead", "SubagentStart", "subagentStart":
                .executing
            case "PermissionRequest":
                isAutoReviewed(provider: provider, event: event, fields: fields)
                    ? .executing
                    : .waitingApproval
            case "PostToolUse", "PostToolBatch", "AfterTool", "postToolUse", "afterShellExecution",
                 "afterMCPExecution", "afterFileEdit", "afterTabFileEdit", "afterAgentResponse",
                 "SubagentStop", "subagentStop", "TaskCreated", "TaskCompleted", "MessageDisplay",
                 "InstructionsLoaded", "ConfigChange", "CwdChanged", "PostCompact", "WorktreeRemove":
                .running
            case "Notification":
                // Notifications are audit/observability events; only a structured
                // PermissionRequest/BeforeTool event can create user work.
                .running
            case "Stop", "AfterAgent", "SessionEnd": .completed
            case "StopFailure", "PostToolUseFailure", "postToolUseFailure": .failed
            default: nil
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
            let tool = fields["tool_name"]?.stringValue ?? fields["toolName"]?.stringValue ?? "tool"
            let command = fields["tool_input"]?["command"]?.stringValue
                ?? fields["toolInput"]?["command"]?.stringValue
                ?? fields["command"]?.stringValue
            return command.map { "Allow \(tool): \($0)" } ?? "Allow \(tool)?"
        }

        private func planPrompt(provider: HookProvider, fields: [String: JSONValue]) -> String {
            let providerName = provider.rawValue.prefix(1).uppercased() + provider.rawValue.dropFirst()
            let title = fields["tool_input"]?["title"]?.stringValue
                ?? fields["toolInput"]?["title"]?.stringValue
            return title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? title ?? "Review the proposed plan"
                : "\(providerName) wants to start implementing the proposed plan"
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

        private func requestedSchemaPropertyKey(_ schema: JSONValue?) -> String? {
            guard case let .object(properties)? = schema?["properties"], !properties.isEmpty else { return nil }
            return properties.keys.sorted().first
        }

        private func questionKind(schema: JSONValue?, secret: Bool, choices: [String]) -> QuestionKind {
            if secret {
                return .secret
            }
            let effectiveSchema: JSONValue? = if case let .object(properties)? = schema?["properties"],
                                                 let key = properties.keys.sorted().first {
                properties[key]
            } else {
                schema
            }
            let type = effectiveSchema?["type"]?.stringValue?.lowercased()
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

        private func firstWorkspaceRoot(_ fields: [String: JSONValue]) -> String? {
            guard case let .array(roots)? = fields["workspace_roots"] ?? fields["workspaceRoots"] else { return nil }
            for root in roots {
                if let path = root.stringValue ?? root["path"]?.stringValue ?? root["uri"]?.stringValue {
                    if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
                        return url.path
                    }
                    return path
                }
            }
            return nil
        }

        private func structuredSequence(_ fields: [String: JSONValue]) -> Int64? {
            for key in ["sequence", "event_sequence", "eventSequence", "generation_sequence"] {
                switch fields[key] {
                case let .number(value) where value.rounded() == value:
                    return Int64(exactly: value)
                case let .string(value):
                    if let sequence = Int64(value) {
                        return sequence
                    }
                default:
                    continue
                }
            }
            return nil
        }

        private func requestRevision(_ fields: [String: JSONValue]) -> Int64 {
            for key in ["revision", "request_revision", "requestRevision"] {
                switch fields[key] {
                case let .number(value) where value.rounded() == value:
                    return max(1, Int64(exactly: value) ?? 1)
                case let .string(value):
                    return max(1, Int64(value) ?? 1)
                default:
                    continue
                }
            }
            return 1
        }

        private func providerRequestIdentifier(
            fields: [String: JSONValue],
            namespace: String,
            fallback: String
        ) -> String {
            for key in [
                "tool_use_id", "request_id", "tool_call_id", "call_id", "execution_id", "command_id",
                "invocation_id", "elicitation_id"
            ] {
                if let value = fields[key]?.stringValue, !value.isEmpty {
                    return value
                }
            }
            let input = fields["tool_input"] ?? fields["toolInput"]
            let generation = fields["generation_id"]?.stringValue ?? fields["generationId"]?.stringValue ?? ""
            let tool = fields["tool_name"]?.stringValue ?? fields["toolName"]?.stringValue ?? ""
            let command = input?["command"]?.stringValue ?? fields["command"]?.stringValue ?? ""
            if !generation.isEmpty || !tool.isEmpty || !command.isEmpty {
                return StableIdentifier.uuid(
                    "provider-request:\(namespace):\(generation):\(tool):\(command)"
                ).uuidString
            }
            return StableIdentifier.uuid("provider-request:\(namespace):\(fallback)").uuidString
        }

        private func eventIdentityToken(fields: [String: JSONValue], eventName: String) -> String {
            for key in ["event_id", "hook_event_id", "notification_id", "tool_use_id", "request_id", "tool_call_id", "execution_id"] {
                if let value = fields[key]?.stringValue, !value.isEmpty {
                    return value
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let encoded = (try? encoder.encode(JSONValue.object(fields))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return StableIdentifier.uuid("provider-event:\(eventName):\(encoded)").uuidString
        }

        private func normalizedToken(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
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
        let providerStatus: ProviderStatusMetadata?

        init(
            eventType: String,
            payload: JSONValue,
            privacyClass: PrivacyClass,
            decisions: [DecisionMetadata],
            providerStatus: ProviderStatusMetadata? = nil
        ) {
            self.eventType = eventType
            self.payload = payload
            self.privacyClass = privacyClass
            self.decisions = decisions
            self.providerStatus = providerStatus
        }
    }

    private struct ProviderStatusMetadata: Sendable {
        let requestID: UUID
        let revision: Int64
        let status: ApprovalStatus
        let resolutionSource: String?

        init(
            requestID: UUID,
            revision: Int64,
            status: ApprovalStatus,
            resolutionSource: String? = nil
        ) {
            self.requestID = requestID
            self.revision = revision
            self.status = status
            self.resolutionSource = resolutionSource
        }
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
