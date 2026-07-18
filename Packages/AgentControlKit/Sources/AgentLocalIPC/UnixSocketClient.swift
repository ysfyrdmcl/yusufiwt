#if os(macOS)
    import Darwin
    import Foundation

    public struct UnixSocketClient: Sendable {
        private let socketURL: URL

        public init(socketURL: URL) {
            self.socketURL = socketURL
        }

        public func send(_ request: HelperRequest, timeoutMilliseconds: Int32 = 5000) throws -> HelperResponse {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw LocalIPCError.socketFailure(code: errno) }
            defer { Darwin.close(descriptor) }
            try connect(descriptor)
            let payload = try JSONEncoder().encode(request)
            let frame = try SocketFrameCodec.encode(SocketFrame(messageType: .request, payload: payload))
            try writeAll(frame, to: descriptor, timeoutMilliseconds: timeoutMilliseconds)
            let header = try readExactly(SocketFrameCodec.headerSize, from: descriptor, timeoutMilliseconds: timeoutMilliseconds)
            let size = Int(header.uint32BigEndian(at: 8))
            guard size <= LocalIPCContract.maximumFrameSize else { throw LocalIPCError.oversizedFrame(size) }
            let responsePayload = try readExactly(size, from: descriptor, timeoutMilliseconds: timeoutMilliseconds)
            let responseFrame = try SocketFrameCodec.decode(header + responsePayload)
            guard responseFrame.messageType == .response else { throw LocalIPCError.malformedPayload }
            return try JSONDecoder().decode(HelperResponse.self, from: responseFrame.payload)
        }

        public func sendOrNeutral(_ request: HelperRequest, timeoutMilliseconds: Int32 = 5000) -> HelperResponse {
            do {
                return try send(request, timeoutMilliseconds: timeoutMilliseconds)
            } catch LocalIPCError.timeout {
                return .neutral(reason: .timeout)
            } catch {
                return .neutral(reason: .helperUnavailable)
            }
        }

        public func sendAsync(
            _ request: HelperRequest,
            timeoutMilliseconds: Int32 = 5000
        ) async throws -> HelperResponse {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try continuation.resume(returning: send(request, timeoutMilliseconds: timeoutMilliseconds))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        private func connect(_ descriptor: Int32) throws {
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
                    Darwin.connect(descriptor, $0, length)
                }
            }
            guard result == 0 else { throw LocalIPCError.unavailable }
        }
    }
#endif
