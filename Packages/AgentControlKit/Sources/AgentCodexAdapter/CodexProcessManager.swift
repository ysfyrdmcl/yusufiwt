import Foundation
#if os(macOS)
    import Darwin
#endif

public enum CodexTransportEndpoint: Equatable, Sendable {
    case stdio
    case unixSocket(URL)

    var launchArguments: [String] {
        switch self {
        case .stdio: ["app-server", "--stdio"]
        case let .unixSocket(url): ["app-server", "--listen", "unix://\(url.path)"]
        }
    }
}

public struct CodexAppServerConfiguration: Sendable, Equatable {
    public let binaryURL: URL
    public let endpoint: CodexTransportEndpoint
    public let maximumRestartAttempts: Int

    public init(binaryURL: URL, endpoint: CodexTransportEndpoint = .stdio, maximumRestartAttempts: Int = 2) {
        self.binaryURL = binaryURL
        self.endpoint = endpoint
        self.maximumRestartAttempts = max(0, maximumRestartAttempts)
    }
}

public enum CodexProcessState: Equatable, Sendable {
    case stopped
    case starting
    case running(processID: Int32)
    case crashed(status: Int32, restartAttempt: Int)
}

public enum CodexTransportEvent: Sendable, Equatable {
    case message(CodexRPCMessage)
    case malformedLine
    case standardError(String)
    case processExited(status: Int32)
}

private final class CodexProcessBox: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    var transportHandle: FileHandle?
}

public actor CodexAppServerProcessManager {
    private let configuration: CodexAppServerConfiguration
    private let codec: CodexJSONLCodec
    private var box: CodexProcessBox?
    private var generation: UInt64 = 0
    private var restartAttempt = 0
    private var continuations: [UUID: AsyncStream<CodexTransportEvent>.Continuation] = [:]

    public private(set) var state: CodexProcessState = .stopped

    public init(configuration: CodexAppServerConfiguration, codec: CodexJSONLCodec = CodexJSONLCodec()) {
        self.configuration = configuration
        self.codec = codec
    }

    public func events() -> AsyncStream<CodexTransportEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func start() throws {
        guard box == nil else { throw CodexAdapterError.processAlreadyRunning }
        state = .starting
        generation &+= 1
        let currentGeneration = generation
        let processBox = CodexProcessBox()
        processBox.process.executableURL = configuration.binaryURL
        processBox.process.arguments = configuration.endpoint.launchArguments
        processBox.process.standardInput = processBox.input
        processBox.process.standardOutput = processBox.output
        processBox.process.standardError = processBox.error
        do {
            try processBox.process.run()
            switch configuration.endpoint {
            case .stdio:
                processBox.transportHandle = processBox.output.fileHandleForReading
            case let .unixSocket(url):
                processBox.transportHandle = try Self.connectUnixSocket(url)
            }
        } catch {
            if processBox.process.isRunning {
                processBox.process.terminate()
            }
            state = .stopped
            throw CodexAdapterError.processLaunchFailed
        }
        box = processBox
        state = .running(processID: processBox.process.processIdentifier)
        guard let transportHandle = processBox.transportHandle else {
            throw CodexAdapterError.transportClosed
        }
        read(transportHandle, generation: currentGeneration, isError: false)
        read(processBox.error.fileHandleForReading, generation: currentGeneration, isError: true)
        Task.detached { [weak self, processBox] in
            processBox.process.waitUntilExit()
            await self?.processExited(status: processBox.process.terminationStatus, generation: currentGeneration)
        }
    }

    public func send(_ message: CodexRPCMessage) throws {
        guard let box, let transportHandle = box.transportHandle, case .running = state else {
            throw CodexAdapterError.processNotRunning
        }
        do {
            let writeHandle = configuration.endpoint == .stdio ? box.input.fileHandleForWriting : transportHandle
            try writeHandle.write(contentsOf: codec.encode(message))
        } catch {
            throw CodexAdapterError.transportClosed
        }
    }

    public func stop() {
        generation &+= 1
        guard let box else {
            state = .stopped
            return
        }
        box.input.fileHandleForWriting.closeFile()
        if configuration.endpoint != .stdio {
            box.transportHandle?.closeFile()
        }
        if box.process.isRunning {
            box.process.terminate()
        }
        self.box = nil
        restartAttempt = 0
        state = .stopped
    }

    @discardableResult
    public func restartAfterCrash() throws -> Bool {
        guard case .crashed = state, restartAttempt < configuration.maximumRestartAttempts else { return false }
        restartAttempt += 1
        box = nil
        try start()
        return true
    }

    private func read(_ handle: FileHandle, generation: UInt64, isError: Bool) {
        Task.detached { [weak self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    break
                }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(through: newline)
                    buffer.removeSubrange(...newline)
                    await self?.receive(Data(line), generation: generation, isError: isError)
                }
            }
            if !buffer.isEmpty {
                await self?.receive(buffer, generation: generation, isError: isError)
            }
        }
    }

    private func receive(_ line: Data, generation: UInt64, isError: Bool) {
        guard generation == self.generation else { return }
        if isError {
            let text = String(bytes: line.prefix(2048), encoding: .utf8) ?? ""
            broadcast(.standardError(text))
            return
        }
        do {
            try broadcast(.message(codec.decode(line: line)))
        } catch {
            broadcast(.malformedLine)
        }
    }

    private func processExited(status: Int32, generation: UInt64) {
        guard generation == self.generation, box != nil else { return }
        box = nil
        state = .crashed(status: status, restartAttempt: restartAttempt)
        broadcast(.processExited(status: status))
    }

    private func broadcast(_ event: CodexTransportEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private static func connectUnixSocket(_ url: URL) throws -> FileHandle {
        #if os(macOS)
            let path = Array(url.path.utf8CString)
            let template = sockaddr_un()
            guard path.count <= MemoryLayout.size(ofValue: template.sun_path) else {
                throw CodexAdapterError.transportClosed
            }
            for _ in 0 ..< 100 {
                let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard descriptor >= 0 else { throw CodexAdapterError.transportClosed }
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutableBytes(of: &address.sun_path) { destination in
                    destination.copyBytes(from: path.map { UInt8(bitPattern: $0) })
                }
                let length = socklen_t(MemoryLayout<sa_family_t>.size + path.count)
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(descriptor, $0, length)
                    }
                }
                if connected == 0 {
                    var enabled: Int32 = 1
                    _ = setsockopt(
                        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                        socklen_t(MemoryLayout.size(ofValue: enabled))
                    )
                    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                }
                Darwin.close(descriptor)
                usleep(10000)
            }
            throw CodexAdapterError.transportClosed
        #else
            throw CodexAdapterError.transportClosed
        #endif
    }
}
