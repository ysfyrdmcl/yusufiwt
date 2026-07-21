#if os(macOS)
    import AgentLocalIPC
    import Foundation

    public struct AgentControlHookClient: Sendable {
        public let configuration: HookConfiguration

        public init(configuration: HookConfiguration) {
            self.configuration = configuration
        }

        public func emit(_ submission: HelperEventSubmission, notification: Bool = false) async -> HelperResponse {
            let timeout = notification ? configuration.statusTimeoutMilliseconds : max(configuration.statusTimeoutMilliseconds, 1000)
            let response = await send(.submitEvent(submission), timeoutMilliseconds: timeout)
            if response.shouldSpool {
                do {
                    let data = try JSONEncoder().encode(submission)
                    let spool = HookSpool(directory: configuration.spoolDirectory)
                    try await spool.enqueue(data)
                    return .eventAccepted(.spooled)
                } catch {
                    return .failure(code: "hook.spool_failed", safeMessage: "The event could not be delivered or queued.")
                }
            }
            return response
        }

        public func requestDecision(_ request: HookDecisionRequest) async -> HelperResponse {
            var timeout = configuration.decisionTimeoutMilliseconds
            if request.waitTimeoutMilliseconds > 0 {
                let boundedRequestTimeout = min(request.waitTimeoutMilliseconds, 60000)
                timeout = min(timeout, Int32(boundedRequestTimeout + 250))
            }
            let deadline = Date().addingTimeInterval(Double(timeout) / 1000)
            var response: HelperResponse
            repeat {
                let remaining = max(1, min(
                    timeout,
                    Int32(max(1, deadline.timeIntervalSinceNow * 1000))
                ))
                response = await send(.requestDecision(request), timeoutMilliseconds: remaining)
                guard response.neutralReason == .helperUnavailable,
                      deadline.timeIntervalSinceNow > 0,
                      request.expiresAt.map({ $0 > Date() }) ?? true
                else { break }
                try? await Task.sleep(for: .milliseconds(100))
            } while !Task.isCancelled
            // A synchronous decision cannot be answered after its provider hook has
            // already fallen back. Replaying its submission as a normal event would
            // create permanent, non-actionable `waitingApproval` state after restart.
            // Ordinary telemetry still uses `emit` and remains safely spoolable.
            return response
        }

        public func doctor() async -> HelperResponse {
            await send(.health, timeoutMilliseconds: max(configuration.statusTimeoutMilliseconds, 1000))
        }

        public func send(_ request: HelperRequest, timeoutMilliseconds: Int32) async -> HelperResponse {
            let client = UnixSocketClient(socketURL: configuration.socketURL)
            do {
                return try await client.sendAsync(request, timeoutMilliseconds: timeoutMilliseconds)
            } catch LocalIPCError.timeout {
                return .neutral(reason: .timeout)
            } catch {
                return .neutral(reason: .helperUnavailable)
            }
        }
    }

    private extension HelperResponse {
        var neutralReason: NeutralFallbackReason? {
            guard case let .neutral(reason) = self else { return nil }
            return reason
        }

        var shouldSpool: Bool {
            guard let neutralReason else { return false }
            return neutralReason == .helperUnavailable || neutralReason == .timeout
        }
    }
#endif
