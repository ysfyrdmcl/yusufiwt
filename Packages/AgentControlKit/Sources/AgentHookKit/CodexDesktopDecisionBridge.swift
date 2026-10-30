#if os(macOS)
    import AgentDomain
    import AgentLocalIPC
    import AgentProtocol
    import Foundation

    /// Adapts native app-server requests to the same broker used by the Notch decision rows.
    public struct CodexDesktopDecisionBridge: Sendable {
        private let client: AgentControlHookClient

        public init(client: AgentControlHookClient) {
            self.client = client
        }

        public func handle(_ data: Data, respond: @escaping @Sendable (Data) -> ApprovalStatus) async -> Bool {
            guard let rpc = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let id = rpc["id"], let idData = try? JSONEncoder().encode(id), let method = rpc["method"]?.stringValue,
                  let params = rpc["params"], let threadID = params["threadId"]?.stringValue,
                  let turnID = params["turnId"]?.stringValue,
                  let itemID = params["itemId"]?.stringValue,
                  case .health = await client.doctor() else { return false }
            let isQuestion = method == "item/tool/requestUserInput"
            guard isQuestion || method == "item/commandExecution/requestApproval"
                || method == "item/fileChange/requestApproval" else { return false }
            // These specific RPC methods are response contracts, independent of hook-version detection.
            let fields: JSONValue = .object([
                "hook_event_name": .string(isQuestion ? "PreToolUse" : "PermissionRequest"),
                "session_id": .string(threadID),
                "cwd": params["cwd"] ?? .string("/private/tmp"),
                "tool_use_id": .string("\(turnID):\(itemID):\(idData.base64EncodedString())"),
                "tool_name": .string(isQuestion ? "request_user_input" : (method == "item/fileChange/requestApproval" ? "apply_patch" : "shell")),
                "tool_input": isQuestion ? params : .object([
                    "command": params["command"] ?? .null,
                    "file_path": params["grantRoot"] ?? .null
                ]),
                "prompt": params["reason"] ?? .string(isQuestion ? "Codex question" : "Codex approval")
            ])
            guard let mapping = try? ProviderHookMapper().map(
                provider: .codex, input: fields, environment: [:],
                capabilities: CapabilityMatrix(supported: [.monitorSessions, .approveRequests, .denyRequests, .answerQuestions])
            ), !mapping.decisionRequests.isEmpty else { return false }
            let responses = await withTaskGroup(of: (Int, HelperResponse).self) { group in
                for (index, request) in mapping.decisionRequests.enumerated() {
                    group.addTask { await (index, client.requestDecision(request)) }
                }
                var values: [(Int, HelperResponse)] = []
                for await value in group {
                    values.append(value)
                }
                return values.sorted { $0.0 < $1.0 }.map(\.1)
            }
            guard let result = Self.nativeResult(responses, mapping: mapping, isQuestion: isQuestion),
                  let response = try? JSONEncoder().encode(JSONValue.object(["id": id, "result": result])) else {
                await finish(mapping, status: .expired)
                return false
            }
            let status = respond(response)
            await finish(mapping, status: status)
            return true
        }

        private static func nativeResult(
            _ responses: [HelperResponse], mapping: ProviderHookMapping, isQuestion: Bool
        ) -> JSONValue? {
            if !isQuestion {
                guard responses.count == 1, case let .decision(value) = responses[0] else { return nil }
                switch value.decision {
                case .approve: return .object(["decision": .string("accept")])
                case .deny: return .object(["decision": .string("decline")])
                default: return nil
                }
            }
            var answers: [String: JSONValue] = [:]
            for (index, response) in responses.enumerated() {
                guard case let .decision(value) = response else { return nil }
                let request = mapping.decisionRequests[index]
                guard let values = ProviderHookMapper().answerValues(value.decision, request: request) else { return nil }
                answers[mapping.providerQuestionIDs[index]] = .object(["answers": .array(values.map(JSONValue.string))])
            }
            return .object(["answers": .object(answers)])
        }

        private func finish(_ mapping: ProviderHookMapping, status: ApprovalStatus) async {
            for request in mapping.decisionRequests {
                let original = request.submission.envelope
                let now = Date()
                let envelope = EventEnvelope(
                    eventID: EventID(UUID()),
                    eventType: request.kind == .approval ? "approval.statusChanged" : "decision.statusChanged",
                    source: original.source, sessionID: original.sessionID,
                    providerSessionID: original.providerSessionID,
                    sequence: Int64(now.timeIntervalSince1970 * 1_000_000), occurredAt: now, receivedAt: now,
                    payload: .object(["id": .string(request.requestID.uuidString.lowercased()),
                                      "revision": .number(Double(request.revision)), "status": .string(status.rawValue)]),
                    privacyClass: .privateMetadata, correlationID: original.correlationID, schemaHash: original.schemaHash
                )
                _ = await client.emit(HelperEventSubmission(envelope: envelope, initialSession: request.submission.initialSession))
            }
        }
    }
#endif
