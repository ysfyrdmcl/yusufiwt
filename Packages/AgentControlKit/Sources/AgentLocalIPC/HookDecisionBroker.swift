#if os(macOS)
    import AgentDomain
    import AgentProtocol
    import Foundation

    // Lifecycle and replay handling are intentionally colocated for atomicity.
    // swiftlint:disable file_length
    // swiftlint:disable:next type_body_length
    public actor HookDecisionBroker {
        private struct Waiter {
            let request: HookDecisionRequest
            var continuations: [CheckedContinuation<HelperResponse, Never>]
            let timeoutTask: Task<Void, Never>
        }

        private struct LifecycleRecord {
            let request: HookDecisionRequest
            var state: DecisionLifecycleState
            var resolutionSource: DecisionResolutionSource?
            var decision: HookDecision?
            var updatedAt: Date

            var snapshot: DecisionLifecycleSnapshot {
                DecisionLifecycleSnapshot(
                    requestID: request.requestID,
                    sessionID: request.submission.envelope.sessionID,
                    revision: request.revision,
                    kind: request.kind,
                    provider: request.submission.initialSession.adapterID.rawValue,
                    projectName: request.submission.initialSession.project.name,
                    state: state,
                    resolutionSource: resolutionSource,
                    decision: decision,
                    expiresAt: request.expiresAt,
                    updatedAt: updatedAt
                )
            }
        }

        private var waiters: [UUID: Waiter] = [:]
        private var records: [UUID: LifecycleRecord] = [:]
        private let now: @Sendable () -> Date
        private let recordRetentionSeconds: TimeInterval
        private let providerAcknowledgmentTimeoutSeconds: TimeInterval

        public init(
            now: @escaping @Sendable () -> Date = { Date() },
            recordRetentionSeconds: TimeInterval = 60 * 60,
            providerAcknowledgmentTimeoutSeconds: TimeInterval = 5 * 60
        ) {
            self.now = now
            self.recordRetentionSeconds = max(60, recordRetentionSeconds)
            self.providerAcknowledgmentTimeoutSeconds = max(30, providerAcknowledgmentTimeoutSeconds)
        }

        // The decision replay/supersession matrix is kept atomic inside the actor.
        // swiftlint:disable:next cyclomatic_complexity function_body_length
        public func wait(for request: HookDecisionRequest) async -> HelperResponse {
            expireRequests()
            guard request.waitTimeoutMilliseconds > 0 else {
                record(request, state: .expired)
                return .neutral(reason: .timeout)
            }
            if let expiresAt = request.expiresAt, expiresAt <= now() {
                record(request, state: .expired)
                return .neutral(reason: .timeout)
            }

            if let record = records[request.requestID] {
                if request.revision < record.request.revision {
                    return .neutral(reason: .timeout)
                }
                if request.revision == record.request.revision {
                    let sameInvocation = request.submission.envelope.eventID
                        == record.request.submission.envelope.eventID
                    if sameInvocation, let decision = record.decision,
                       record.state == .userResolvedAwaitingProviderAck
                       || record.state == .automaticallyResolvedAwaitingProviderAck
                       || record.state == .providerAcknowledged
                       || record.state == .applied
                       || record.state == .deniedApplied {
                        return .decision(HookDecisionResult(
                            requestID: request.requestID,
                            revision: request.revision,
                            decision: decision
                        ))
                    }
                    if sameInvocation, record.state.isFinal {
                        return .neutral(reason: .timeout)
                    }
                    if !sameInvocation {
                        // Some provider hooks lack a first-class call ID and must
                        // reuse a session/tool fingerprint. A new normalized event
                        // is a new invocation, not permission to replay the old answer.
                        supersede(requestID: request.requestID)
                    }
                } else {
                    supersede(requestID: request.requestID)
                }
            }

            return await withCheckedContinuation { continuation in
                if var existing = waiters[request.requestID], existing.request.revision == request.revision {
                    // The same provider event can be retried while the first hook invocation is
                    // still blocked. Join the existing waiter instead of cancelling it.
                    existing.continuations.append(continuation)
                    waiters[request.requestID] = existing
                    return
                }

                if waiters[request.requestID] != nil {
                    supersede(requestID: request.requestID)
                }
                let timeout = effectiveTimeoutMilliseconds(for: request)
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(timeout))
                    guard !Task.isCancelled else { return }
                    await self?.timeOut(requestID: request.requestID, revision: request.revision)
                }
                waiters[request.requestID] = Waiter(
                    request: request,
                    continuations: [continuation],
                    timeoutTask: timeoutTask
                )
                record(request, state: .awaitingUser)
            }
        }

        public func pending() -> [PendingHookDecision] {
            expireRequests()
            return waiters.values
                .filter { records[$0.request.requestID]?.state == .awaitingUser }
                .map { PendingHookDecision(request: $0.request) }
                .sorted {
                    ($0.expiresAt ?? .distantFuture, $0.requestID.uuidString)
                        < ($1.expiresAt ?? .distantFuture, $1.requestID.uuidString)
                }
        }

        public func lifecycles() -> [DecisionLifecycleSnapshot] {
            expireRequests()
            pruneRecords()
            return records.values.map(\.snapshot).sorted {
                ($0.updatedAt, $0.requestID.uuidString) > ($1.updatedAt, $1.requestID.uuidString)
            }
        }

        public func resolve(_ resolution: HookDecisionResolution) -> DecisionResolutionDisposition {
            expireRequests()
            guard let waiter = waiters[resolution.requestID] else {
                guard let record = records[resolution.requestID] else { return .notFound }
                guard record.request.revision == resolution.revision else { return .revisionMismatch }
                // Exact replay of a previously accepted resolution is idempotent. A
                // conflicting second answer is never forwarded to the provider.
                return record.decision == resolution.decision ? .accepted : .notFound
            }
            guard waiter.request.revision == resolution.revision else { return .revisionMismatch }
            if let expiresAt = waiter.request.expiresAt, expiresAt <= now() {
                finish(
                    requestID: resolution.requestID,
                    response: .neutral(reason: .timeout),
                    state: .expired
                )
                return .expired
            }
            guard Self.isValid(resolution.decision, for: waiter.request) else { return .invalidDecision }
            finish(
                requestID: resolution.requestID,
                response: .decision(HookDecisionResult(
                    requestID: resolution.requestID,
                    revision: resolution.revision,
                    decision: resolution.decision
                )),
                state: .userResolvedAwaitingProviderAck,
                source: .user,
                decision: resolution.decision
            )
            return .accepted
        }

        public func recordAutomaticResolution(
            _ decision: HookDecision,
            for request: HookDecisionRequest
        ) -> HookDecisionResult {
            expireRequests()
            if let existing = records[request.requestID], existing.request.revision > request.revision {
                return HookDecisionResult(
                    requestID: existing.request.requestID,
                    revision: existing.request.revision,
                    decision: existing.decision ?? decision
                )
            }
            record(
                request,
                state: .automaticallyResolvedAwaitingProviderAck,
                source: .automation,
                decision: decision
            )
            return HookDecisionResult(requestID: request.requestID, revision: request.revision, decision: decision)
        }

        // Every provider status is mapped explicitly to prevent false applied states.
        // swiftlint:disable:next cyclomatic_complexity
        public func observeProviderStatus(
            requestID: UUID,
            revision: Int64?,
            status: ApprovalStatus
        ) {
            expireRequests()
            guard var record = records[requestID] else { return }
            if let revision, revision != record.request.revision {
                return
            }
            guard !record.state.isFinal else { return }

            let nextState: DecisionLifecycleState? = switch status {
            case .providerAcknowledged:
                switch record.decision {
                case .deny?: .deniedApplied
                case .some: .applied
                case nil: .providerAcknowledged
                }
            case .applied: .applied
            case .deniedApplied: .deniedApplied
            case .expired: .expired
            case .superseded: .superseded
            case .cancelledByProvider: .cancelled
            case .providerRejected:
                // A provider-side denial confirms a local deny, but rejects a
                // local allow. Keeping this distinction prevents false "applied" UX.
                record.decision == .deny ? .deniedApplied : .providerRejected
            case .policyRejected, .deliveryFailed: .providerRejected
            case .received, .classified, .presented, .userDecisionPending,
                 .signedDecisionReceived, .policyValidated, .sentToProvider:
                nil
            }
            guard let nextState else { return }
            if waiters[requestID] != nil, nextState != .providerAcknowledged {
                finish(
                    requestID: requestID,
                    response: .neutral(reason: .timeout),
                    state: nextState,
                    source: record.resolutionSource,
                    decision: record.decision
                )
                return
            }
            record.state = nextState
            record.updatedAt = now()
            records[requestID] = record
        }

        public func statusSubmission(
            requestID: UUID,
            status: ApprovalStatus,
            at date: Date
        ) -> HelperEventSubmission? {
            guard let record = records[requestID] else { return nil }
            let request = record.request
            let original = request.submission.envelope
            let eventType = request.kind == .approval ? "approval.statusChanged" : "decision.statusChanged"
            let payload: JSONValue = .object([
                "id": .string(requestID.uuidString.lowercased()),
                "revision": .number(Double(request.revision)),
                "status": .string(status.rawValue)
            ])
            let envelope = EventEnvelope(
                eventID: EventID(Self.stableUUID(
                    "decision-status:\(requestID.uuidString):\(request.revision):\(status.rawValue)"
                )),
                eventType: eventType,
                source: original.source,
                sessionID: original.sessionID,
                providerSessionID: original.providerSessionID,
                sequence: original.sequence + 1000 + Self.sequenceOffset(for: status),
                occurredAt: date,
                receivedAt: date,
                payload: payload,
                privacyClass: .privateMetadata,
                correlationID: original.correlationID,
                schemaHash: original.schemaHash
            )
            return HelperEventSubmission(envelope: envelope, initialSession: request.submission.initialSession)
        }

        public func cancelAll(reason: NeutralFallbackReason) {
            let requestIDs = Array(waiters.keys)
            for requestID in requestIDs {
                finish(
                    requestID: requestID,
                    response: .neutral(reason: reason),
                    state: .cancelled
                )
            }
        }

        private func timeOut(requestID: UUID, revision: Int64) {
            guard waiters[requestID]?.request.revision == revision else { return }
            finish(requestID: requestID, response: .neutral(reason: .timeout), state: .expired)
        }

        private func supersede(requestID: UUID) {
            guard waiters[requestID] != nil else {
                if var record = records[requestID], !record.state.isFinal {
                    record.state = .superseded
                    record.updatedAt = now()
                    records[requestID] = record
                }
                return
            }
            finish(requestID: requestID, response: .neutral(reason: .timeout), state: .superseded)
        }

        private func finish(
            requestID: UUID,
            response: HelperResponse,
            state: DecisionLifecycleState,
            source: DecisionResolutionSource? = nil,
            decision: HookDecision? = nil
        ) {
            guard let waiter = waiters.removeValue(forKey: requestID) else {
                if var record = records[requestID] {
                    record.state = state
                    record.resolutionSource = source ?? record.resolutionSource
                    record.decision = decision ?? record.decision
                    record.updatedAt = now()
                    records[requestID] = record
                }
                return
            }
            waiter.timeoutTask.cancel()
            record(waiter.request, state: state, source: source, decision: decision)
            for continuation in waiter.continuations {
                continuation.resume(returning: response)
            }
        }

        private func record(
            _ request: HookDecisionRequest,
            state: DecisionLifecycleState,
            source: DecisionResolutionSource? = nil,
            decision: HookDecision? = nil
        ) {
            records[request.requestID] = LifecycleRecord(
                request: request,
                state: state,
                resolutionSource: source,
                decision: decision,
                updatedAt: now()
            )
        }

        private func expireRequests() {
            let instant = now()
            let expired = waiters.values.compactMap { waiter -> UUID? in
                guard let expiry = waiter.request.expiresAt, expiry <= instant else { return nil }
                return waiter.request.requestID
            }
            for requestID in expired {
                finish(requestID: requestID, response: .neutral(reason: .timeout), state: .expired)
            }
            let expiredRecords = records.compactMap { requestID, record -> UUID? in
                guard waiters[requestID] == nil,
                      !record.state.isFinal
                else { return nil }
                let expiry: Date? = switch record.state {
                case .awaitingUser:
                    record.request.expiresAt
                case .userResolvedAwaitingProviderAck, .automaticallyResolvedAwaitingProviderAck,
                     .providerAcknowledged:
                    record.updatedAt.addingTimeInterval(providerAcknowledgmentTimeoutSeconds)
                case .applied, .deniedApplied, .expired, .cancelled, .superseded, .providerRejected:
                    nil
                }
                guard let expiry, expiry <= instant else { return nil }
                return requestID
            }
            for requestID in expiredRecords {
                guard var record = records[requestID] else { continue }
                record.state = .expired
                record.updatedAt = instant
                records[requestID] = record
            }
        }

        private func pruneRecords() {
            let cutoff = now().addingTimeInterval(-recordRetentionSeconds)
            records = records.filter { _, record in
                !record.state.isFinal || record.updatedAt >= cutoff
            }
        }

        private func effectiveTimeoutMilliseconds(for request: HookDecisionRequest) -> Int {
            var timeout = min(max(request.waitTimeoutMilliseconds, 1), 60000)
            if let expiry = request.expiresAt {
                let untilExpiry = max(1, Int(expiry.timeIntervalSince(now()) * 1000))
                timeout = min(timeout, untilExpiry)
            }
            return timeout
        }

        private static func sequenceOffset(for status: ApprovalStatus) -> Int64 {
            Int64(ApprovalStatus.allCases.firstIndex(of: status) ?? 0)
        }

        private static func stableUUID(_ value: String) -> UUID {
            var first: UInt64 = 14_695_981_039_346_656_037
            var second: UInt64 = 1_099_511_628_211
            for byte in value.utf8 {
                first = (first ^ UInt64(byte)) &* 1_099_511_628_211
                second = (second &* 1_099_511_628_211) ^ UInt64(byte)
            }
            var bytes = withUnsafeBytes(of: first.bigEndian, Array.init)
                + withUnsafeBytes(of: second.bigEndian, Array.init)
            bytes[6] = (bytes[6] & 0x0F) | 0x50
            bytes[8] = (bytes[8] & 0x3F) | 0x80
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }

        private static func isValid(_ decision: HookDecision, for request: HookDecisionRequest) -> Bool {
            switch (request.kind, decision) {
            case (.approval, .approve), (.approval, .deny), (.plan, .approve), (.plan, .deny):
                true
            case let (.plan, .requestPlanChanges(value)):
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 4000
            case let (.question, .answerChoice(id)):
                request.effectiveQuestionKind == .singleChoice && request.choices.contains { $0.id == id }
            case let (.question, .answerChoices(ids)):
                request.effectiveQuestionKind == .multiChoice && !ids.isEmpty && Set(ids).count == ids.count
                    && ids.allSatisfy { id in request.choices.contains { $0.id == id } }
            case let (.question, .answerText(value)):
                (request.effectiveQuestionKind == .freeText
                    || (request.effectiveQuestionKind == .singleChoice && request.questionAllowsOther))
                    && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && value.count <= (request.maximumAnswerLength ?? 4000)
            case (.question, .confirm):
                request.effectiveQuestionKind == .confirmation
            case (.question, .deny):
                true
            default:
                false
            }
        }
    }

    private extension HookDecisionRequest {
        var question: AgentQuestion? {
            guard kind == .question,
                  let data = try? JSONEncoder().encode(submission.envelope.payload)
            else { return nil }
            return try? JSONDecoder().decode(AgentQuestion.self, from: data)
        }

        var questionKind: QuestionKind? {
            question?.kind
        }

        var questionAllowsOther: Bool {
            question?.isOther == true
        }

        var effectiveQuestionKind: QuestionKind {
            questionKind ?? (choices.isEmpty ? .freeText : .singleChoice)
        }
    }
#endif
