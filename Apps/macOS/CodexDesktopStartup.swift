import AgentLocalIPC
import AgentMacUI
import AppKit

@MainActor
final class CodexDesktopStartup {
    private var usageTask: Task<Void, Never>?

    func start(store: AgentControlStore) {
        guard let desktop = ["/Applications/Codex.app", "/Applications/ChatGPT.app"]
            .map({ URL(fileURLWithPath: $0) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("Contents/Resources/codex").path) }) else { return }
        let executable = desktop.appendingPathComponent("Contents/Resources/codex")
        usageTask = Task { [weak store] in
            while !Task.isCancelled {
                let metric = await CodexAccountUsageReader.read(executableURL: executable)
                guard !Task.isCancelled else { return }
                // A failed/account-unavailable read must not show a previous account's quota.
                store?.codexAccountUsage = metric
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        Task { await connect(desktop: desktop, executable: executable) }
    }

    func stop() {
        usageTask?.cancel()
    }

    private func connect(desktop: URL, executable: URL) async {
        guard !CodexDesktopControl().isAvailable,
              let relay = Bundle.main.resourceURL?.appendingPathComponent("codex-desktop-relay"),
              FileManager.default.isExecutableFile(atPath: relay.path) else { return }
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL == desktop }
        if !running.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "startup.codex.connect")
            alert.informativeText = String(localized: "startup.codex.restartInfo")
            alert.addButton(withTitle: String(localized: "startup.codex.restart"))
            alert.addButton(withTitle: String(localized: "startup.later"))
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            for application in running {
                application.terminate()
            }
            for _ in 0 ..< 100 {
                if running.allSatisfy(\.isTerminated) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard running.allSatisfy(\.isTerminated) else {
                showFailure(String(localized: "startup.codex.quitFailed"))
                return
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = [
            "CODEX_CLI_PATH": relay.path,
            "CODEX_APP_SERVER_FORCE_CLI": "1",
            "YUSUFIWT_CODEX_EXECUTABLE": executable.path
        ]
        do {
            _ = try await NSWorkspace.shared.openApplication(at: desktop, configuration: configuration)
            for _ in 0 ..< 40 {
                if CodexDesktopControl().isAvailable {
                    return
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            showFailure(String(localized: "startup.codex.connectionFailed"))
        } catch {
            showFailure(String(localized: "startup.codex.openFailed"))
        }
    }

    private func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "startup.codex.title")
        alert.informativeText = message
        alert.runModal()
    }
}
