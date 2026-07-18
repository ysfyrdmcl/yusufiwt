import AgentHookKit
import AgentLocalIPC
import AgentProtocol
import Darwin
import Foundation

@main
enum AgentControlHookMain {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { throw CLIError.usage }
            if command == "version" {
                writeStandardOutput(Data("agentcontrol-hook 0.4.0\n".utf8))
                return
            }

            let configuration = try HookConfiguration.environment()
            let client = AgentControlHookClient(configuration: configuration)
            let response: HelperResponse
            switch command {
            case "emit", "notify":
                let data = try readInput(arguments: Array(arguments.dropFirst()), maximumBytes: configuration.maximumInputBytes)
                let submission = try BoundedJSON.decode(
                    HelperEventSubmission.self,
                    from: data,
                    maximumBytes: configuration.maximumInputBytes
                )
                response = await client.emit(submission, notification: command == "notify")
            case "request-decision":
                let data = try readInput(arguments: Array(arguments.dropFirst()), maximumBytes: configuration.maximumInputBytes)
                let request = try BoundedJSON.decode(
                    HookDecisionRequest.self,
                    from: data,
                    maximumBytes: configuration.maximumInputBytes
                )
                response = await client.requestDecision(request)
            case "doctor":
                response = await client.doctor()
            case "provider-hook":
                guard arguments.count == 2,
                      let provider = HookProvider(rawValue: arguments[1])
                else { throw CLIError.usage }
                let data = try readInput(arguments: [], maximumBytes: configuration.maximumInputBytes)
                let input = try BoundedJSON.decode(
                    JSONValue.self,
                    from: data,
                    maximumBytes: configuration.maximumInputBytes
                )
                let mapper = ProviderHookMapper()
                let mapping = try mapper.map(provider: provider, input: input)
                if let request = mapping.decisionRequest {
                    response = await client.requestDecision(request)
                } else {
                    response = await client.emit(mapping.submission, notification: true)
                }
                try writeJSON(mapper.providerOutput(for: response, mapping: mapping))
                return
            default:
                throw CLIError.unknownCommand(command)
            }
            try writeJSON(response)
        } catch {
            log("agentcontrol-hook: \(error)")
            let failure = HelperResponse.failure(code: "hook.invalid_invocation", safeMessage: "The hook request was invalid.")
            try? writeJSON(failure)
            exit(64)
        }
    }

    private static func readInput(arguments: [String], maximumBytes: Int) throws -> Data {
        if let index = arguments.firstIndex(of: "--json") {
            guard arguments.indices.contains(index + 1) else { throw CLIError.missingJSONValue }
            let value = arguments[index + 1]
            if value != "-" {
                let data = try Data(contentsOf: URL(fileURLWithPath: value), options: .mappedIfSafe)
                guard data.count <= maximumBytes else { throw HookInputError.tooLarge(data.count) }
                return data
            }
        }
        let data = try FileHandle.standardInput.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw HookInputError.tooLarge(data.count) }
        return data
    }

    private static func writeJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        writeStandardOutput(data)
    }

    private static func writeStandardOutput(_ data: Data) {
        FileHandle.standardOutput.write(data)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private enum CLIError: Error, CustomStringConvertible {
    case usage
    case missingJSONValue
    case unknownCommand(String)

    var description: String {
        switch self {
        case .usage: "usage: agentcontrol-hook <emit|request-decision|notify|doctor|provider-hook PROVIDER|version> [--json FILE|-]"
        case .missingJSONValue: "--json requires a file path or -"
        case let .unknownCommand(command): "unknown command: \(command)"
        }
    }
}
