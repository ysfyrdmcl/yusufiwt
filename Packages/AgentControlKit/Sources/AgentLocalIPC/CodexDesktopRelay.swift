#if os(macOS)
    import AgentDomain
    import Darwin
    import Foundation

    /// Owns the desktop's original stdio child and exposes interruption and interactive decisions over local IPC.
    public final class CodexDesktopRelay: @unchecked Sendable {
        private let process = Process()
        private let childInput = Pipe()
        private let childOutput = Pipe()
        private let inputLock = NSLock()
        private let outputLock = NSLock()
        private var interactiveRequests: [Data: (turnID: String, key: String)] = [:]
        public typealias DecisionHandler = @Sendable (Data, @escaping @Sendable (Data) -> ApprovalStatus) async -> Bool
        private let decisionHandler: DecisionHandler?
        private let pendingLock = NSLock()
        private var pending: [String: Reply] = [:]
        private let prefix = "yusufiwt-\(UUID().uuidString)-"
        private let finished = DispatchSemaphore(value: 0)

        private final class Reply: @unchecked Sendable {
            let semaphore = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var data: Data?
        }

        public init(decisionHandler: DecisionHandler? = nil) { self.decisionHandler = decisionHandler }

        public func stop() {
            finished.signal()
        }

        public func run(
            executableURL: URL, arguments: [String], socketURL: URL,
            input: FileHandle = .standardInput, output: FileHandle = .standardOutput,
            handleTerminationSignals: Bool = false
        ) throws -> Int32 {
            let lockFD = try acquireLock(socketURL: socketURL)
            defer { Darwin.close(lockFD) }
            let server = makeServer(socketURL: socketURL)
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardInput = childInput
            process.standardOutput = childOutput
            process.standardError = FileHandle.standardError
            try process.run()
            // Install after spawn so the child retains its normal signal handling.
            let signals: [DispatchSourceSignal] = handleTerminationSignals ? [SIGTERM, SIGINT].map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { [self] in stop() }
                source.resume()
                return source
            } : []
            defer {
                for source in signals {
                    source.cancel()
                }
                if handleTerminationSignals {
                    signal(SIGTERM, SIG_DFL)
                    signal(SIGINT, SIG_DFL)
                }
                inputLock.withLock { interactiveRequests.removeAll() }
                server.stop()
                try? childInput.fileHandleForWriting.close()
                if process.isRunning {
                    process.terminate()
                }
            }
            try server.start()
            startPumps(input: input, output: output)
            finished.wait()
            return process.isRunning ? 0 : process.terminationStatus
        }

        private func acquireLock(socketURL: URL) throws -> Int32 {
            let directory = socketURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
                  info.st_mode & 0o077 == 0 else { throw LocalIPCError.unsafeSocketPath }
            let lockFD = Darwin.open(directory.appendingPathComponent("desktop.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lockFD >= 0 else { throw LocalIPCError.unavailable }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(lockFD)
                throw LocalIPCError.unavailable
            }
            return lockFD
        }

        private func makeServer(socketURL: URL) -> UnixSocketServer {
            UnixSocketServer(socketURL: socketURL) { [self] request in
                switch request {
                case let .negotiateProtocol(versions):
                    guard let version = LocalIPCContract.negotiate(supportedVersions: versions) else {
                        return .failure(code: "desktop.protocol", safeMessage: "Unsupported protocol")
                    }
                    return .protocolNegotiated(version: version)
                case let .interruptCodexSession(identifier):
                    // This private endpoint receives the native Codex thread UUID.
                    do {
                        return try .codexInterruptRequested(interrupt(threadID: identifier.rawValue.uuidString.lowercased()))
                    } catch {
                        return .failure(code: "desktop.interrupt", safeMessage: "Codex interruption failed")
                    }
                default:
                    return .failure(code: "desktop.unsupported", safeMessage: "Unsupported desktop control command")
                }
            }
        }

        private func startPumps(input: FileHandle, output: FileHandle) {
            DispatchQueue.global().async { [self] in
                defer { finished.signal() }
                do {
                    try Self.lines(input) { [self] line in
                        try inputLock.withLock { try childInput.fileHandleForWriting.write(contentsOf: line + Data([10])) }
                    }
                } catch { /* Closing desktop input ends its child. */ }
            }
            DispatchQueue.global().async { [self] in
                defer { finished.signal() }
                do {
                    try Self.lines(childOutput.fileHandleForReading) { [self] line in
                        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                           let id = object["id"] as? String, id.hasPrefix(prefix) {
                            if let reply = pendingLock.withLock({ pending.removeValue(forKey: id) }) {
                                reply.lock.withLock { reply.data = line }
                                reply.semaphore.signal()
                            }
                        } else {
                            if !routeDecision(line, output: output) {
                                try outputLock.withLock { try output.write(contentsOf: line + Data([10])) }
                            }
                        }
                    }
                } catch { /* Closing child output ends the relay. */ }
            }
        }

        private func routeDecision(_ line: Data, output: FileHandle) -> Bool {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let method = object["method"] as? String else { return false }
            let params = object["params"] as? [String: Any] ?? [:]
            if method == "serverRequest/resolved", let id = params["requestId"],
               let key = Self.decisionKey(id) {
                inputLock.withLock { interactiveRequests = interactiveRequests.filter { $0.value.key != key } }
                pendingLock.withLock { pending[key] }?.semaphore.signal()
            }
            if method == "turn/completed", let turn = params["turn"] as? [String: Any],
               let turnID = turn["id"] as? String {
                inputLock.withLock { interactiveRequests = interactiveRequests.filter { $0.value.turnID != turnID } }
            }
            guard let decisionHandler, let id = object["id"],
                  ["item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                   "item/tool/requestUserInput"].contains(method),
                  let turnID = params["turnId"] as? String,
                  let key = Self.decisionKey(id) else { return false }
            inputLock.withLock { interactiveRequests[line] = (turnID, key) }
            Task { [self] in
                let requestData = enrichDecision(line)
                let handled = await decisionHandler(requestData) { [self] response in
                    let acknowledgment = Reply()
                    pendingLock.withLock { pending[key] = acknowledgment }
                    defer { _ = pendingLock.withLock { pending.removeValue(forKey: key) } }
                    let sent: ApprovalStatus = inputLock.withLock {
                        guard interactiveRequests.removeValue(forKey: line) != nil else { return .cancelledByProvider }
                        do {
                            try childInput.fileHandleForWriting.write(contentsOf: response + Data([10]))
                            return .sentToProvider
                        } catch { return .deliveryFailed }
                    }
                    guard sent == .sentToProvider else { return sent }
                    return acknowledgment.semaphore.wait(timeout: .now() + 3) == .success
                        ? .providerAcknowledged : .sentToProvider
                }
                inputLock.withLock {
                    guard interactiveRequests.removeValue(forKey: line) != nil, !handled else { return }
                    // The helper declined or timed out: restore the native desktop prompt.
                    try? outputLock.withLock { try output.write(contentsOf: line + Data([10])) }
                }
            }
            return true
        }

        private func enrichDecision(_ line: Data) -> Data {
            guard var object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  var params = object["params"] as? [String: Any], params["cwd"] == nil,
                  let threadID = params["threadId"] as? String,
                  let result = try? request(method: "thread/read", params: ["threadId": threadID, "includeTurns": false]),
                  let thread = result["thread"] as? [String: Any], let cwd = thread["cwd"] as? String else { return line }
            params["cwd"] = cwd
            object["params"] = params
            return (try? JSONSerialization.data(withJSONObject: object)) ?? line
        }

        private static func decisionKey(_ id: Any) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed]) else { return nil }
            return "decision-" + data.base64EncodedString()
        }

        private func interrupt(threadID: String) throws -> Bool {
            let result = try request(method: "thread/read", params: ["threadId": threadID, "includeTurns": true])
            guard let thread = result["thread"] as? [String: Any],
                  let actualID = thread["id"] as? String, UUID(uuidString: actualID) == UUID(uuidString: threadID),
                  let turns = thread["turns"] as? [[String: Any]],
                  let turn = turns.last, turn["status"] as? String == "inProgress",
                  let turnID = turn["id"] as? String else { return false }
            _ = try request(method: "turn/interrupt", params: ["threadId": actualID, "turnId": turnID])
            return true
        }

        private func request(method: String, params: [String: Any]) throws -> [String: Any] {
            let id = prefix + UUID().uuidString
            let reply = Reply()
            pendingLock.withLock { pending[id] = reply }
            defer { _ = pendingLock.withLock { pending.removeValue(forKey: id) } }
            var data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
            data.append(10)
            try inputLock.withLock { try childInput.fileHandleForWriting.write(contentsOf: data) }
            guard reply.semaphore.wait(timeout: .now() + 3) == .success,
                  let response = reply.lock.withLock({ reply.data }),
                  let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  object["error"] == nil, let result = object["result"] as? [String: Any]
            else { throw LocalIPCError.unavailable }
            return result
        }

        private static func lines(_ handle: FileHandle, consume: (Data) throws -> Void) throws {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    guard line.count <= 16 * 1024 * 1024 else { throw LocalIPCError.oversizedFrame(line.count) }
                    buffer.removeSubrange(...end)
                    try consume(line)
                }
                guard buffer.count <= 16 * 1024 * 1024 else { throw LocalIPCError.oversizedFrame(buffer.count) }
            }
        }
    }
#endif
