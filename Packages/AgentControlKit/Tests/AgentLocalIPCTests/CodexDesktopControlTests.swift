import AgentLocalIPC
import Foundation
import Testing

struct CodexDesktopControlTests {
    @Test("Desktop relay preserves desktop messages and interrupts only its verified active turn", arguments: ["inProgress", "completed"])
    func verifiedTurn(status: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("server.py")
        let log = directory.appendingPathComponent("requests")
        let threadID = UUID().uuidString.lowercased()
        try """
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            with open('\(log.path)', 'a') as log: log.write(line)
            if request.get('method') == 'thread/read':
                result = {'thread': {'id': '\(threadID)', 'turns': [{'id': 'active-turn', 'status': '\(status)'}]}}
            else: result = {}
            if 'id' in request:
                print(json.dumps({'id': request['id'], 'result': result}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let input = Pipe()
        let outputURL = directory.appendingPathComponent("desktop-output")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let control = CodexDesktopControl(socketURL: directory.appendingPathComponent("desktop.sock"))
        let run = Task.detached {
            try CodexDesktopRelay().run(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                                        arguments: [script.path], socketURL: control.socketURL,
                                        input: input.fileHandleForReading, output: output)
        }
        defer { try? input.fileHandleForWriting.close() }
        for _ in 0 ..< 100 {
            if control.isAvailable {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(control.isAvailable)
        try input.fileHandleForWriting.write(contentsOf: Data("{\"id\":\"desktop-request\",\"method\":\"initialize\"}\n".utf8))
        #expect(try await control.interrupt(threadID: threadID) == (status == "inProgress"))
        try input.fileHandleForWriting.close()
        _ = try await run.value
        let requests = try String(contentsOf: log, encoding: .utf8)
        #expect(requests.replacingOccurrences(of: "\\/", with: "/").contains("turn/interrupt") == (status == "inProgress"))
        let desktopOutput = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(desktopOutput.contains("desktop-request"))
        #expect(!desktopOutput.contains("yusufiwt-"))
        #expect(!control.isAvailable)
    }
}
