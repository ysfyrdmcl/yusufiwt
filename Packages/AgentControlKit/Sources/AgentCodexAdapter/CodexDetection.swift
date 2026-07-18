import AgentDomain
import AgentProtocol
import Foundation

public struct CodexVersion: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let suffix: String?

    public init(major: Int, minor: Int, patch: Int, suffix: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.suffix = suffix
    }

    public init?(_ output: String) {
        guard let token = output.split(whereSeparator: \.isWhitespace).last else { return nil }
        let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        let numbers = parts[0].split(separator: ".")
        guard numbers.count >= 2,
              let major = Int(numbers[0]), let minor = Int(numbers[1])
        else { return nil }
        self.major = major
        self.minor = minor
        patch = numbers.count > 2 ? Int(numbers[2]) ?? 0 : 0
        suffix = parts.count == 2 ? String(parts[1]) : nil
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        [lhs.major, lhs.minor, lhs.patch].lexicographicallyPrecedes([rhs.major, rhs.minor, rhs.patch])
    }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        return suffix.map { base + "-" + $0 } ?? base
    }
}

public struct CodexBinaryInfo: Codable, Hashable, Sendable {
    public let executableURL: URL
    public let version: CodexVersion

    public init(executableURL: URL, version: CodexVersion) {
        self.executableURL = executableURL
        self.version = version
    }
}

public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CodexCommandRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> CommandResult
}

public struct FoundationCodexCommandRunner: CodexCommandRunning {
    public init() {}

    public func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        try await Task.detached {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            return CommandResult(
                status: process.terminationStatus,
                stdout: output.fileHandleForReading.readDataToEndOfFile(),
                stderr: error.fileHandleForReading.readDataToEndOfFile()
            )
        }.value
    }
}

public struct CodexBinaryDetector: Sendable {
    private let runner: any CodexCommandRunning
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        runner: any CodexCommandRunning = FoundationCodexCommandRunner(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.runner = runner
        self.isExecutable = isExecutable
    }

    public func detect(searchPaths: [URL]? = nil) async throws -> CodexBinaryInfo {
        let candidates = searchPaths ?? Self.defaultCandidates()
        guard let executable = candidates.first(where: { isExecutable($0.path) }) else {
            throw CodexAdapterError.binaryNotFound
        }
        let result = try await runner.run(executable: executable, arguments: ["--version"])
        guard result.status == 0,
              let output = String(data: result.stdout, encoding: .utf8),
              let version = CodexVersion(output)
        else { throw CodexAdapterError.versionDetectionFailed }
        return CodexBinaryInfo(executableURL: executable, version: version)
    }

    public static func defaultCandidates(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var paths: [URL] = []
        if let explicit = environment["AGENTCONTROL_CODEX_PATH"], !explicit.isEmpty {
            paths.append(URL(fileURLWithPath: explicit))
        }
        for directory in environment["PATH", default: ""].split(separator: ":") {
            paths.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("codex"))
        }
        paths.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ])
        var seen = Set<String>()
        return paths.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

public enum CodexCompatibilityMode: Equatable, Sendable {
    case full
    case monitorOnly(reason: String)
}

public struct CodexSchemaCompatibility: Sendable {
    public init() {}

    public func evaluate(schemaData: Data) throws -> CodexCompatibilityMode {
        let root = try JSONDecoder().decode(JSONValue.self, from: schemaData)
        let strings = collectStrings(root)
        let missing = CodexAppServerContract.requiredMethods.subtracting(strings).sorted()
        return missing.isEmpty ? .full : .monitorOnly(reason: "Missing app-server methods: \(missing.joined(separator: ", "))")
    }

    private func collectStrings(_ value: JSONValue) -> Set<String> {
        switch value {
        case let .string(value): [value]
        case let .array(values): values.reduce(into: Set<String>()) { $0.formUnion(collectStrings($1)) }
        case let .object(values): values.reduce(into: Set<String>()) { result, pair in
                result.insert(pair.key)
                result.formUnion(collectStrings(pair.value))
            }
        case .number, .bool, .null: []
        }
    }
}

public struct CodexSchemaGenerator: Sendable {
    private let runner: any CodexCommandRunning
    public init(runner: any CodexCommandRunning = FoundationCodexCommandRunner()) {
        self.runner = runner
    }

    public func generate(using binary: URL, outputDirectory: URL) async throws -> URL {
        let result = try await runner.run(
            executable: binary,
            arguments: ["app-server", "generate-json-schema", "--out", outputDirectory.path]
        )
        guard result.status == 0 else { throw CodexAdapterError.processLaunchFailed }
        return outputDirectory.appendingPathComponent("codex_app_server_protocol.schemas.json")
    }
}
