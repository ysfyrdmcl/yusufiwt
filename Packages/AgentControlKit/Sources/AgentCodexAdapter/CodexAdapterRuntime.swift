import AgentDomain
import Foundation

public actor CodexAdapterRuntime {
    private let process: CodexAppServerProcessManager
    private let controller: CodexManagedSessionController
    private let diagnostics: CodexDiagnosticCapture
    private let clientVersion: String
    private var eventTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<CodexAdapterOutput>.Continuation] = [:]

    public init(
        process: CodexAppServerProcessManager,
        controller: CodexManagedSessionController = CodexManagedSessionController(),
        diagnostics: CodexDiagnosticCapture = CodexDiagnosticCapture(),
        clientVersion: String
    ) {
        self.process = process
        self.controller = controller
        self.diagnostics = diagnostics
        self.clientVersion = clientVersion
    }

    public func outputs() -> AsyncStream<CodexAdapterOutput> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func start(compatibility: CodexCompatibilityMode = .full) async throws {
        guard eventTask == nil else { throw CodexAdapterError.processAlreadyRunning }
        await controller.applyCompatibility(compatibility)
        let events = await process.events()
        try await process.start()
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.consume(event)
            }
        }
        let initialize = try await controller.initialize(clientVersion: clientVersion)
        try await process.send(initialize)
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await process.stop()
    }

    public func startManagedSession(workspaceRoot: URL, model: String? = nil) async throws -> SessionID {
        let (sessionID, request) = try await controller.startManagedSession(workspaceRoot: workspaceRoot, model: model)
        try await process.send(request)
        return sessionID
    }

    public func startTurn(threadID: String, prompt: String) async throws {
        try await process.send(controller.startTurn(threadID: threadID, prompt: prompt))
    }

    public func cancel(threadID: String) async throws {
        try await process.send(controller.cancel(threadID: threadID))
    }

    public func decide(
        requestID: ApprovalRequestID,
        revision: Int64,
        decision: CodexApprovalDecision
    ) async throws {
        let update = try await controller.respondToApproval(
            requestID: requestID, revision: revision, decision: decision
        )
        if let response = update.response {
            try await process.send(response)
        }
        emit(CodexAdapterOutput(approvalUpdates: [update]))
    }

    private func consume(_ event: CodexTransportEvent) async {
        switch event {
        case let .message(message):
            await diagnostics.record(message)
            do {
                let output = try await controller.handle(message)
                for outgoing in output.outgoing {
                    try await process.send(outgoing)
                }
                emit(output)
            } catch {
                await diagnostics.recordTransport(category: "mappingError")
            }
        case .malformedLine:
            await diagnostics.recordTransport(category: "malformedLine")
        case .standardError:
            await diagnostics.recordTransport(category: "standardErrorRedacted")
        case .processExited:
            await diagnostics.recordTransport(category: "processExited")
            await emit(controller.processCrashed())
            do {
                if try await process.restartAfterCrash() {
                    let initialize = try await controller.initialize(clientVersion: clientVersion)
                    try await process.send(initialize)
                }
            } catch {
                await diagnostics.recordTransport(category: "reconnectFailed")
            }
        }
    }

    private func emit(_ output: CodexAdapterOutput) {
        for continuation in continuations.values {
            continuation.yield(output)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

private extension CodexAdapterOutput {
    init(approvalUpdates: [CodexApprovalUpdate]) {
        self.init()
        self.approvalUpdates = approvalUpdates
    }
}
