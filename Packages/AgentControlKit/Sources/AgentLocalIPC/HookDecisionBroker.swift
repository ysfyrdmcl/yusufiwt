#if os(macOS)
    import Foundation

    public actor HookDecisionBroker {
        private struct Waiter {
            let request: HookDecisionRequest
            let continuation: CheckedContinuation<HelperResponse, Never>
            let timeoutTask: Task<Void, Never>
        }

        private var waiters: [UUID: Waiter] = [:]
        private let now: @Sendable () -> Date

        public init(now: @escaping @Sendable () -> Date = { Date() }) {
            self.now = now
        }

        public func wait(for request: HookDecisionRequest) async -> HelperResponse {
            guard request.waitTimeoutMilliseconds > 0 else {
                return .neutral(reason: .timeout)
            }
            if let expiresAt = request.expiresAt, expiresAt <= now() {
                return .neutral(reason: .timeout)
            }
            if let existing = waiters.removeValue(forKey: request.requestID) {
                existing.timeoutTask.cancel()
                existing.continuation.resume(returning: .neutral(reason: .timeout))
            }

            let timeout = min(request.waitTimeoutMilliseconds, 60000)
            return await withCheckedContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(timeout))
                    guard !Task.isCancelled else { return }
                    await self?.timeOut(requestID: request.requestID)
                }
                waiters[request.requestID] = Waiter(
                    request: request,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        }

        public func pending() -> [PendingHookDecision] {
            waiters.values
                .map { PendingHookDecision(request: $0.request) }
                .sorted { $0.requestID.uuidString < $1.requestID.uuidString }
        }

        public func resolve(_ resolution: HookDecisionResolution) -> DecisionResolutionDisposition {
            guard let waiter = waiters[resolution.requestID] else { return .notFound }
            guard waiter.request.revision == resolution.revision else { return .revisionMismatch }
            if let expiresAt = waiter.request.expiresAt, expiresAt <= now() {
                finish(requestID: resolution.requestID, response: .neutral(reason: .timeout))
                return .expired
            }
            guard Self.isValid(resolution.decision, for: waiter.request) else { return .invalidDecision }
            finish(
                requestID: resolution.requestID,
                response: .decision(HookDecisionResult(
                    requestID: resolution.requestID,
                    revision: resolution.revision,
                    decision: resolution.decision
                ))
            )
            return .accepted
        }

        public func cancelAll(reason: NeutralFallbackReason) {
            let requestIDs = Array(waiters.keys)
            for requestID in requestIDs {
                finish(requestID: requestID, response: .neutral(reason: reason))
            }
        }

        private func timeOut(requestID: UUID) {
            finish(requestID: requestID, response: .neutral(reason: .timeout))
        }

        private func finish(requestID: UUID, response: HelperResponse) {
            guard let waiter = waiters.removeValue(forKey: requestID) else { return }
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: response)
        }

        private static func isValid(_ decision: HookDecision, for request: HookDecisionRequest) -> Bool {
            switch (request.kind, decision) {
            case (.approval, .approve), (.approval, .deny), (.plan, .approve), (.plan, .deny):
                true
            case let (.question, .answer(value)):
                request.choices.isEmpty || request.choices.contains(value)
            case (.question, .deny):
                true
            default:
                false
            }
        }
    }
#endif
