#if os(macOS)
    import Darwin
    import Foundation

    public final class UnixSocketServer: @unchecked Sendable {
        public typealias Handler = @Sendable (HelperRequest) async -> HelperResponse

        private let socketURL: URL
        private let peerValidator: any PeerCredentialValidating
        private let handler: Handler
        private let lock = NSLock()
        private let connectionQueue = DispatchQueue(label: "com.yusuf.agentcontrol.socket.connections")
        private var listeningDescriptor: Int32 = -1
        private var source: DispatchSourceRead?

        public init(
            socketURL: URL,
            peerValidator: any PeerCredentialValidating = SameUserPeerValidator(),
            handler: @escaping Handler
        ) {
            self.socketURL = socketURL
            self.peerValidator = peerValidator
            self.handler = handler
        }

        public var isRunning: Bool {
            lock.withLock { listeningDescriptor >= 0 }
        }

        public func start() throws {
            try lock.withLock {
                guard listeningDescriptor < 0 else { return }
                try validateAndRemoveExistingSocket()
                let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard descriptor >= 0 else { throw LocalIPCError.socketFailure(code: errno) }
                do {
                    try bind(descriptor)
                    guard chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else {
                        throw LocalIPCError.socketFailure(code: errno)
                    }
                    guard Darwin.listen(descriptor, 128) == 0 else { throw LocalIPCError.socketFailure(code: errno) }
                    let flags = fcntl(descriptor, F_GETFL)
                    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                        throw LocalIPCError.socketFailure(code: errno)
                    }
                    listeningDescriptor = descriptor
                    let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: connectionQueue)
                    readSource.setEventHandler { [weak self] in self?.acceptAvailableConnections() }
                    readSource.setCancelHandler { Darwin.close(descriptor) }
                    source = readSource
                    readSource.resume()
                } catch {
                    Darwin.close(descriptor)
                    try? removeOwnedSocket()
                    throw error
                }
            }
        }

        public func stop() {
            lock.withLock {
                guard listeningDescriptor >= 0 else { return }
                listeningDescriptor = -1
                source?.cancel()
                source = nil
                try? removeOwnedSocket()
            }
        }

        private func acceptAvailableConnections() {
            let descriptor = lock.withLock { listeningDescriptor }
            guard descriptor >= 0 else { return }
            while true {
                let client = Darwin.accept(descriptor, nil, nil)
                if client < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return
                }
                configureClient(client)
                guard let credentials = peerCredentials(client), peerValidator.authorize(credentials) else {
                    Darwin.close(client)
                    continue
                }
                connectionQueue.async { [weak self] in self?.readAndHandle(client) }
            }
        }

        private func readAndHandle(_ descriptor: Int32) {
            do {
                let header = try readExactly(SocketFrameCodec.headerSize, from: descriptor, timeoutMilliseconds: 5000)
                let payloadSize = Int(header.uint32BigEndian(at: 8))
                guard payloadSize <= LocalIPCContract.maximumFrameSize else {
                    throw LocalIPCError.oversizedFrame(payloadSize)
                }
                let payload = try readExactly(payloadSize, from: descriptor, timeoutMilliseconds: 5000)
                let frame = try SocketFrameCodec.decode(header + payload)
                guard frame.messageType == .request else { throw LocalIPCError.malformedPayload }
                let request = try JSONDecoder().decode(HelperRequest.self, from: frame.payload)
                Task { [weak self] in
                    guard let self else {
                        Darwin.close(descriptor)
                        return
                    }
                    let response = await handler(request)
                    write(response, to: descriptor)
                    Darwin.close(descriptor)
                }
            } catch {
                write(HelperResponse.failure(code: "ipc.invalid_request", safeMessage: "The local request was rejected."), to: descriptor)
                Darwin.close(descriptor)
            }
        }

        private func write(_ response: HelperResponse, to descriptor: Int32) {
            guard let payload = try? JSONEncoder().encode(response),
                  let frame = try? SocketFrameCodec.encode(SocketFrame(messageType: .response, payload: payload))
            else { return }
            _ = try? writeAll(frame, to: descriptor, timeoutMilliseconds: 5000)
        }

        private func bind(_ descriptor: Int32) throws {
            let path = Array(socketURL.path.utf8CString)
            var address = sockaddr_un()
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw LocalIPCError.unsafeSocketPath }
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: path.map { UInt8(bitPattern: $0) })
            }
            let length = socklen_t(MemoryLayout<sa_family_t>.size + path.count)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, length)
                }
            }
            guard result == 0 else { throw LocalIPCError.socketFailure(code: errno) }
        }

        private func configureClient(_ descriptor: Int32) {
            var enabled: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        }

        private func peerCredentials(_ descriptor: Int32) -> PeerCredentials? {
            var userID: uid_t = 0
            var groupID: gid_t = 0
            guard getpeereid(descriptor, &userID, &groupID) == 0 else { return nil }
            return PeerCredentials(userID: userID, groupID: groupID)
        }

        private func validateAndRemoveExistingSocket() throws {
            var info = stat()
            guard lstat(socketURL.path, &info) == 0 else {
                if errno == ENOENT {
                    return
                }
                throw LocalIPCError.socketFailure(code: errno)
            }
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                throw LocalIPCError.unsafeSocketPath
            }
            guard Darwin.unlink(socketURL.path) == 0 else { throw LocalIPCError.socketFailure(code: errno) }
        }

        private func removeOwnedSocket() throws {
            var info = stat()
            guard lstat(socketURL.path, &info) == 0 else { return }
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                throw LocalIPCError.unsafeSocketPath
            }
            guard Darwin.unlink(socketURL.path) == 0 else { throw LocalIPCError.socketFailure(code: errno) }
        }
    }

    func readExactly(_ count: Int, from descriptor: Int32, timeoutMilliseconds: Int32) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            try waitForDescriptor(descriptor, events: Int16(POLLIN), timeoutMilliseconds: timeoutMilliseconds)
            var buffer = [UInt8](repeating: 0, count: min(16384, count - result.count))
            let bytesRead = Darwin.read(descriptor, &buffer, buffer.count)
            if bytesRead == 0 {
                throw LocalIPCError.truncatedFrame
            }
            if bytesRead < 0 {
                if errno == EINTR || errno == EAGAIN {
                    continue
                }
                throw LocalIPCError.socketFailure(code: errno)
            }
            result.append(contentsOf: buffer.prefix(bytesRead))
        }
        return result
    }

    func writeAll(_ data: Data, to descriptor: Int32, timeoutMilliseconds: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < data.count {
                try waitForDescriptor(descriptor, events: Int16(POLLOUT), timeoutMilliseconds: timeoutMilliseconds)
                let written = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN {
                        continue
                    }
                    throw LocalIPCError.socketFailure(code: errno)
                }
                offset += written
            }
        }
    }

    func waitForDescriptor(_ descriptor: Int32, events: Int16, timeoutMilliseconds: Int32) throws {
        var item = pollfd(fd: descriptor, events: events, revents: 0)
        let result = Darwin.poll(&item, 1, timeoutMilliseconds)
        guard result > 0 else {
            if result == 0 {
                throw LocalIPCError.timeout
            }
            throw LocalIPCError.socketFailure(code: errno)
        }
    }

    extension Data {
        func uint32BigEndian(at index: Int) -> UInt32 {
            (UInt32(self[index]) << 24) |
                (UInt32(self[index + 1]) << 16) |
                (UInt32(self[index + 2]) << 8) |
                UInt32(self[index + 3])
        }
    }
#endif
