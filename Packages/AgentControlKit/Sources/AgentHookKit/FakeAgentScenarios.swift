#if os(macOS)
    import AgentDomain
    import AgentLocalIPC
    import AgentProtocol
    import Foundation

    public enum FakeAgentScenario: String, CaseIterable, Sendable {
        case running
        case progress
        case approval
        case question
        case plan
        case subagent
        case completion
        case failure
        case malformed
        case duplicate
        case outOfOrder = "out-of-order"
    }

    public enum FakeAgentStep: Sendable {
        case emit(HelperEventSubmission)
        case requestDecision(HookDecisionRequest)
    }

    public struct FakeAgentScenarioBuilder: Sendable {
        public let nodeID: NodeID
        public let projectID: ProjectID
        public let sessionID: SessionID
        public let baseDate: Date

        public init(
            nodeID: NodeID = NodeID(UUID()),
            projectID: ProjectID = ProjectID(UUID()),
            sessionID: SessionID = SessionID(UUID()),
            baseDate: Date = Date()
        ) {
            self.nodeID = nodeID
            self.projectID = projectID
            self.sessionID = sessionID
            self.baseDate = baseDate
        }

        public func steps(for scenario: FakeAgentScenario, decisionTimeoutMilliseconds: Int = 25000) -> [FakeAgentStep] {
            switch scenario {
            case .running:
                [.emit(state(.running, sequence: 1))]
            case .progress:
                [.emit(state(.running, sequence: 1)), .emit(event(type: "session.progress", sequence: 2, payload: .object(["percent": .number(50)])))]
            case .approval:
                [.requestDecision(decision(
                    kind: .approval,
                    type: "approval.requested",
                    prompt: "Allow reading Package.swift?",
                    sequence: 1,
                    timeout: decisionTimeoutMilliseconds
                ))]
            case .question:
                [.requestDecision(decision(
                    kind: .question,
                    type: "question.requested",
                    prompt: "Choose a build configuration",
                    choices: ["Debug", "Release"],
                    sequence: 1,
                    timeout: decisionTimeoutMilliseconds
                ))]
            case .plan:
                [.requestDecision(decision(
                    kind: .plan,
                    type: "plan.reviewRequested",
                    prompt: "Approve the proposed implementation plan?",
                    sequence: 1,
                    timeout: decisionTimeoutMilliseconds
                ))]
            case .subagent:
                [.emit(subagent(sequence: 1))]
            case .completion, .failure:
                terminalSteps(for: scenario)
            case .malformed:
                [.emit(malformedSubmission())]
            case .duplicate:
                duplicateSteps()
            case .outOfOrder:
                [.emit(state(.running, sequence: 2)), .emit(state(.thinking, sequence: 1))]
            }
        }

        private func terminalSteps(for scenario: FakeAgentScenario) -> [FakeAgentStep] {
            let terminalState: SessionState = scenario == .completion ? .completed : .failed
            return [.emit(state(.running, sequence: 1)), .emit(state(terminalState, sequence: 2))]
        }

        private func state(_ state: SessionState, sequence: Int64) -> HelperEventSubmission {
            event(type: "session.stateChanged", sequence: sequence, payload: .object(["state": .string(state.rawValue)]))
        }

        private func event(type: String, sequence: Int64, payload: JSONValue) -> HelperEventSubmission {
            let date = baseDate.addingTimeInterval(Double(sequence))
            return HelperEventSubmission(
                envelope: EventEnvelope(
                    eventID: EventID(UUID()),
                    eventType: type,
                    source: EventSource(adapterID: AdapterID("fake-agent"), adapterVersion: "1.0", nodeID: nodeID),
                    sessionID: sessionID,
                    providerSessionID: "fake-\(sessionID.description)",
                    sequence: sequence,
                    occurredAt: date,
                    receivedAt: date,
                    payload: payload,
                    privacyClass: .privateMetadata,
                    correlationID: EnvelopeID(UUID()),
                    schemaHash: "fake-agent-v1"
                ),
                initialSession: initialSession()
            )
        }

        private func decision(
            kind: HookDecisionKind,
            type: String,
            prompt: String,
            choices: [String] = [],
            sequence: Int64,
            timeout: Int
        ) -> HookDecisionRequest {
            let submission = event(
                type: type,
                sequence: sequence,
                payload: decisionPayload(kind: kind, prompt: prompt, choices: choices)
            )
            return HookDecisionRequest(
                requestID: UUID(),
                revision: 1,
                kind: kind,
                prompt: prompt,
                choices: choices,
                expiresAt: baseDate.addingTimeInterval(120),
                waitTimeoutMilliseconds: timeout,
                submission: submission
            )
        }

        private func decisionPayload(kind: HookDecisionKind, prompt: String, choices: [String]) -> JSONValue {
            switch kind {
            case .approval:
                let request = ApprovalRequest(
                    id: ApprovalRequestID(UUID()),
                    sessionID: sessionID,
                    providerRequestID: UUID().uuidString.lowercased(),
                    action: .useTool(ToolInvocationSummary(name: "read_file", isReadOnly: true)),
                    risk: RiskAssessment(level: .low, reasons: ["fake-agent-fixture"]),
                    createdAt: baseDate,
                    expiresAt: baseDate.addingTimeInterval(120),
                    revision: 1,
                    status: .received
                )
                return (try? JSONValue.encoding(request)) ?? .object(["prompt": .string(prompt)])
            case .question:
                let question = AgentQuestion(
                    id: QuestionID(UUID()),
                    sessionID: sessionID,
                    kind: choices.isEmpty ? .text : .choice,
                    prompt: prompt,
                    choices: choices
                )
                return (try? JSONValue.encoding(question)) ?? .object(["prompt": .string(prompt)])
            case .plan:
                return .object(["title": .string(prompt), "kind": .string(kind.rawValue)])
            }
        }

        private func subagent(sequence: Int64) -> HelperEventSubmission {
            let childID = SessionID(UUID())
            let date = baseDate.addingTimeInterval(Double(sequence))
            let child = AgentSession(
                id: childID,
                nodeID: nodeID,
                adapterID: AdapterID("fake-agent"),
                externalSessionID: "fake-child",
                project: initialSession().project,
                terminalContext: nil,
                parentSessionID: sessionID,
                state: .discovered,
                startedAt: baseDate,
                endedAt: nil,
                lastMeaningfulEventAt: baseDate,
                snapshotRevision: 0
            )
            let envelope = EventEnvelope(
                eventID: EventID(UUID()),
                eventType: "session.stateChanged",
                source: EventSource(adapterID: AdapterID("fake-agent"), adapterVersion: "1.0", nodeID: nodeID),
                sessionID: childID,
                sequence: sequence,
                occurredAt: date,
                receivedAt: date,
                payload: .object(["state": .string(SessionState.running.rawValue)]),
                privacyClass: .privateMetadata,
                correlationID: EnvelopeID(UUID()),
                schemaHash: "fake-agent-v1"
            )
            return HelperEventSubmission(envelope: envelope, initialSession: child)
        }

        private func malformedSubmission() -> HelperEventSubmission {
            let valid = state(.running, sequence: 1)
            let wrongSession = AgentSession(
                id: SessionID(UUID()),
                nodeID: nodeID,
                adapterID: valid.initialSession.adapterID,
                externalSessionID: nil,
                project: valid.initialSession.project,
                terminalContext: nil,
                parentSessionID: nil,
                state: .discovered,
                startedAt: baseDate,
                endedAt: nil,
                lastMeaningfulEventAt: baseDate,
                snapshotRevision: 0
            )
            return HelperEventSubmission(envelope: valid.envelope, initialSession: wrongSession)
        }

        private func duplicateSteps() -> [FakeAgentStep] {
            let submission = state(.running, sequence: 1)
            return [.emit(submission), .emit(submission)]
        }

        private func initialSession() -> AgentSession {
            AgentSession(
                id: sessionID,
                nodeID: nodeID,
                adapterID: AdapterID("fake-agent"),
                externalSessionID: "fake-\(sessionID.description)",
                project: ProjectReference(
                    id: projectID,
                    name: "Fake Agent Project",
                    rootURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                ),
                terminalContext: nil,
                parentSessionID: nil,
                state: .discovered,
                startedAt: baseDate,
                endedAt: nil,
                lastMeaningfulEventAt: baseDate,
                snapshotRevision: 0
            )
        }
    }
#endif
