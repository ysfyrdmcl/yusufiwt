#if os(macOS)
    import AgentDomain
    import Foundation

    /// Read-only app-server requests. Never starts a turn or stores credentials.
    public enum CodexAccountUsageReader {
        public static func read(executableURL: URL) async -> SessionUsageMetric? {
            await Task.detached(priority: .utility) { readSynchronously(executableURL: executableURL) }.value
        }

        // Keep the bounded read-only handshake and its process cleanup together.
        // swiftlint:disable:next cyclomatic_complexity function_body_length
        private static func readSynchronously(executableURL: URL) -> SessionUsageMetric? {
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = executableURL
            process.arguments = ["app-server"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let timeout = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            defer {
                timeout.cancel()
                try? input.fileHandleForWriting.close()
                if process.isRunning {
                    process.terminate()
                }
                try? output.fileHandleForReading.close()
            }
            func send(_ object: [String: Any]) throws {
                var data = try JSONSerialization.data(withJSONObject: object)
                data.append(10)
                try input.fileHandleForWriting.write(contentsOf: data)
            }
            do {
                try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "yusufiwt", "version": "1.0"]]])
                var buffer = Data()
                while true {
                    let data = output.fileHandleForReading.availableData
                    guard !data.isEmpty else { return nil }
                    buffer.append(data)
                    guard buffer.count < 1_048_576 else { return nil }
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end])
                        buffer.removeSubrange(...end)
                        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                        switch object["id"] as? Int {
                        case 1:
                            guard object["error"] == nil else { return nil }
                            try send(["method": "initialized", "params": [:]])
                            try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
                        case 2:
                            guard let result = object["result"] as? [String: Any] else { return nil }
                            return weeklyMetric(from: result, at: Date())
                        default: continue
                        }
                    }
                }
            } catch { return nil }
        }

        static func weeklyMetric(from result: [String: Any], at date: Date) -> SessionUsageMetric? {
            let byID = result["rateLimitsByLimitId"] as? [String: Any]
            guard let limits = (byID?["codex"] ?? result["rateLimits"]) as? [String: Any] else { return nil }
            for name in ["primary", "secondary"] {
                guard let window = limits[name] as? [String: Any],
                      window["windowDurationMins"] as? Int == 10080,
                      let used = window["usedPercent"] as? Double, used.isFinite,
                      (0 ... 100).contains(used) else { continue }
                return SessionUsageMetric(
                    provider: AdapterID("codex"), kind: .quotaRemaining, remainingPercent: 100 - used,
                    source: "account/rateLimits/read", updatedAt: date, quotaWindow: .weekly,
                    resetsAt: (window["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
                )
            }
            return nil
        }
    }
#endif
