import AgentLocalIPC
import Darwin
import Foundation

do {
    let paths = try AgentControlPaths.userDefault()
    let cipher = try KeychainFieldKeyProvider().loadOrCreateCipher()
    let policy = XPCClientAuthorizationPolicy.forCurrentHelper(allowsAdHocSignatures: allowsAdHocSignatures)
    let host = try await HelperHost.make(paths: paths, cipher: cipher, authorizationPolicy: policy)
    try await host.start()
    await ShutdownSignal.wait()
    await host.stop()
} catch {
    let message = "AgentControlHelper failed: \(String(describing: error))\n"
    FileHandle.standardError.write(Data(message.utf8))
}

private var allowsAdHocSignatures: Bool {
    #if DEBUG || AGENTCONTROL_MAC_LOCAL
        true
    #else
        false
    #endif
}

private enum ShutdownSignal {
    static func wait() async {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        await withCheckedContinuation { continuation in
            let state = SignalContinuation(continuation)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            termination.setEventHandler { state.resume() }
            interruption.setEventHandler { state.resume() }
            termination.resume()
            interruption.resume()
            state.retain(termination, interruption)
        }
    }
}

private final class SignalContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [DispatchSourceSignal] = []

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func retain(_ sources: DispatchSourceSignal...) {
        lock.withLock { self.sources = sources }
    }

    func resume() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let value = self.continuation
            self.continuation = nil
            sources.forEach { $0.cancel() }
            sources.removeAll()
            return value
        }
        continuation?.resume()
    }
}
