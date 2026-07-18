#if os(macOS)
    import Darwin
    import Foundation

    public final class HelperXPCListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        private let listener: NSXPCListener
        private let runtime: HelperRuntime
        private let authorizationPolicy: XPCClientAuthorizationPolicy

        public init(
            runtime: HelperRuntime,
            authorizationPolicy: XPCClientAuthorizationPolicy,
            machServiceName: String = LocalIPCContract.machServiceName
        ) {
            self.runtime = runtime
            self.authorizationPolicy = authorizationPolicy
            listener = NSXPCListener(machServiceName: machServiceName)
            super.init()
            listener.delegate = self
        }

        public func start() {
            listener.resume()
        }

        public func stop() {
            listener.invalidate()
        }

        public func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            let identity = XPCClientIdentity(
                processID: connection.processIdentifier,
                userID: connection.effectiveUserIdentifier
            )
            guard authorizationPolicy.authorize(identity) else { return false }
            let service = HelperXPCService(runtime: runtime, connection: connection)
            connection.exportedInterface = XPCInterfaces.service()
            connection.exportedObject = service
            connection.remoteObjectInterface = XPCInterfaces.eventSink()
            connection.invalidationHandler = { service.stop() }
            connection.interruptionHandler = { service.stop() }
            connection.resume()
            return true
        }
    }

    private final class HelperXPCService: NSObject, HelperXPCServiceProtocol, @unchecked Sendable {
        private let runtime: HelperRuntime
        private weak var connection: NSXPCConnection?
        private let lock = NSLock()
        private var eventTask: Task<Void, Never>?

        init(runtime: HelperRuntime, connection: NSXPCConnection) {
            self.runtime = runtime
            self.connection = connection
        }

        func request(_ message: XPCMessage, withReply reply: @escaping (XPCMessage) -> Void) {
            let replyBox = XPCReplyBox(reply)
            Task {
                let response: HelperResponse
                do {
                    response = try await runtime.handle(message.decodeRequest())
                } catch {
                    response = .failure(code: "xpc.malformed_request", safeMessage: "The local request was rejected.")
                }
                guard let result = try? XPCMessage(response: response) else { return }
                replyBox.call(result)
            }
        }

        func subscribe(withReply reply: @escaping (Bool) -> Void) {
            guard let sink = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? HelperXPCEventSinkProtocol else {
                reply(false)
                return
            }
            let sinkBox = XPCEventSinkBox(sink)
            let task = Task { [runtime] in
                let stream = await runtime.notifications()
                for await event in stream {
                    guard !Task.isCancelled,
                          let message = try? XPCMessage(response: .registryEvent(event))
                    else { break }
                    sinkBox.receive(message)
                }
            }
            lock.withLock {
                eventTask?.cancel()
                eventTask = task
            }
            reply(true)
        }

        func stop() {
            lock.withLock {
                eventTask?.cancel()
                eventTask = nil
            }
        }
    }

    private final class XPCReplyBox<Value>: @unchecked Sendable {
        private let reply: (Value) -> Void

        init(_ reply: @escaping (Value) -> Void) {
            self.reply = reply
        }

        func call(_ value: Value) {
            reply(value)
        }
    }

    private final class XPCEventSinkBox: @unchecked Sendable {
        private let sink: HelperXPCEventSinkProtocol

        init(_ sink: HelperXPCEventSinkProtocol) {
            self.sink = sink
        }

        func receive(_ message: XPCMessage) {
            sink.receive(message)
        }
    }
#endif
