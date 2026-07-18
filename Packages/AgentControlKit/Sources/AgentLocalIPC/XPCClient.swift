#if os(macOS)
    import Foundation

    public struct ReconnectBackoff: Sendable, Equatable {
        public let initialNanoseconds: UInt64
        public let maximumNanoseconds: UInt64
        public let multiplier: UInt64

        public init(
            initialNanoseconds: UInt64 = 100_000_000,
            maximumNanoseconds: UInt64 = 5_000_000_000,
            multiplier: UInt64 = 2
        ) {
            self.initialNanoseconds = initialNanoseconds
            self.maximumNanoseconds = maximumNanoseconds
            self.multiplier = max(1, multiplier)
        }

        public func delayNanoseconds(forAttempt attempt: Int) -> UInt64 {
            guard attempt > 0 else { return 0 }
            var delay = initialNanoseconds
            for _ in 1 ..< attempt {
                let multiplied = delay.multipliedReportingOverflow(by: multiplier)
                delay = multiplied.overflow ? maximumNanoseconds : min(multiplied.partialValue, maximumNanoseconds)
            }
            return min(delay, maximumNanoseconds)
        }
    }

    public actor HelperXPCClient {
        private let machServiceName: String
        private let backoff: ReconnectBackoff
        private let eventReceiver = XPCEventReceiver()
        private var connection: NSXPCConnection?

        public init(
            machServiceName: String = LocalIPCContract.machServiceName,
            backoff: ReconnectBackoff = ReconnectBackoff()
        ) {
            self.machServiceName = machServiceName
            self.backoff = backoff
        }

        public func send(_ request: HelperRequest, maximumAttempts: Int = 4) async throws -> HelperResponse {
            var lastError: Error = LocalIPCError.unavailable
            for attempt in 0 ..< max(1, maximumAttempts) {
                do {
                    if connection == nil {
                        try await connect()
                    }
                    return try await sendOnce(request)
                } catch {
                    lastError = error
                    invalidateConnection()
                    let delay = backoff.delayNanoseconds(forAttempt: attempt + 1)
                    if attempt + 1 < maximumAttempts {
                        try await Task.sleep(nanoseconds: delay)
                    }
                }
            }
            throw lastError
        }

        public func notifications() -> AsyncStream<RegistryNotification> {
            eventReceiver.stream()
        }

        public func disconnect() {
            invalidateConnection()
        }

        private func connect() async throws {
            let newConnection = NSXPCConnection(machServiceName: machServiceName)
            newConnection.remoteObjectInterface = XPCInterfaces.service()
            newConnection.exportedInterface = XPCInterfaces.eventSink()
            newConnection.exportedObject = eventReceiver
            newConnection.interruptionHandler = { [weak self] in
                Task { await self?.connectionWasInterrupted() }
            }
            newConnection.invalidationHandler = { [weak self] in
                Task { await self?.connectionWasInterrupted() }
            }
            newConnection.resume()
            connection = newConnection
            let response = try await sendOnce(.negotiate(supportedVersions: [LocalIPCContract.currentVersion]))
            guard case .negotiated = response else {
                invalidateConnection()
                throw LocalIPCError.unsupportedVersion(0)
            }
            try await subscribe()
        }

        private func sendOnce(_ request: HelperRequest) async throws -> HelperResponse {
            guard let connection else { throw LocalIPCError.unavailable }
            let message = try XPCMessage(request: request)
            return try await withCheckedThrowingContinuation { continuation in
                let reply = ThrowingContinuationBox(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                    reply.resume(throwing: LocalIPCError.unavailable)
                }) as? HelperXPCServiceProtocol else {
                    reply.resume(throwing: LocalIPCError.unavailable)
                    return
                }
                proxy.request(message) { response in
                    do {
                        try reply.resume(returning: response.decodeResponse())
                    } catch {
                        reply.resume(throwing: error)
                    }
                }
            }
        }

        private func subscribe() async throws {
            guard let connection else { throw LocalIPCError.unavailable }
            let accepted: Bool = try await withCheckedThrowingContinuation { continuation in
                let reply = ThrowingContinuationBox(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                    reply.resume(throwing: LocalIPCError.unavailable)
                }) as? HelperXPCServiceProtocol else {
                    reply.resume(throwing: LocalIPCError.unavailable)
                    return
                }
                proxy.subscribe { reply.resume(returning: $0) }
            }
            guard accepted else { throw LocalIPCError.unavailable }
        }

        private func connectionWasInterrupted() {
            connection = nil
        }

        private func invalidateConnection() {
            connection?.invalidationHandler = nil
            connection?.interruptionHandler = nil
            connection?.invalidate()
            connection = nil
        }
    }

    final class OneShotGate: @unchecked Sendable {
        private let lock = NSLock()
        private var available = true

        func claim() -> Bool {
            lock.withLock {
                guard available else { return false }
                available = false
                return true
            }
        }
    }

    private final class ThrowingContinuationBox<Value: Sendable>: @unchecked Sendable {
        private let gate = OneShotGate()
        private let continuation: CheckedContinuation<Value, any Error>

        init(_ continuation: CheckedContinuation<Value, any Error>) {
            self.continuation = continuation
        }

        func resume(returning value: sending Value) {
            guard gate.claim() else { return }
            continuation.resume(returning: value)
        }

        func resume(throwing error: any Error) {
            guard gate.claim() else { return }
            continuation.resume(throwing: error)
        }
    }

    private final class XPCEventReceiver: NSObject, HelperXPCEventSinkProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [UUID: AsyncStream<RegistryNotification>.Continuation] = [:]

        func receive(_ message: XPCMessage) {
            guard let response = try? message.decodeResponse(), case let .registryEvent(event) = response else { return }
            lock.withLock {
                for continuation in continuations.values {
                    continuation.yield(event)
                }
            }
        }

        func stream() -> AsyncStream<RegistryNotification> {
            let id = UUID()
            return AsyncStream { continuation in
                lock.withLock { continuations[id] = continuation }
                continuation.onTermination = { [weak self] _ in
                    _ = self?.lock.withLock { self?.continuations.removeValue(forKey: id) }
                }
            }
        }
    }
#endif
