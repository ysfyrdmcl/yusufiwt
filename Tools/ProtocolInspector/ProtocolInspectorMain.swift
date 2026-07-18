import AgentHookKit
import AgentLocalIPC
import Darwin
import Foundation

@main
enum ProtocolInspectorMain {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { throw InspectorError.usage }
            let configuration = try HookConfiguration.environment()
            let client = AgentControlHookClient(configuration: configuration)
            let response: HelperResponse
            switch command {
            case "health":
                response = await client.send(.health, timeoutMilliseconds: 1000)
            case "pending":
                response = await client.send(.pendingDecisions, timeoutMilliseconds: 1000)
            case "resolve":
                guard arguments.count >= 4,
                      let requestID = UUID(uuidString: arguments[1]),
                      let revision = Int64(arguments[2]),
                      let decision = parseDecision(Array(arguments.dropFirst(3)))
                else { throw InspectorError.invalidResolution }
                response = await client.send(
                    .resolveDecision(HookDecisionResolution(
                        requestID: requestID,
                        revision: revision,
                        decision: decision
                    )),
                    timeoutMilliseconds: 1000
                )
            case "send":
                guard arguments.count == 2 else { throw InspectorError.usage }
                let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
                let request = try BoundedJSON.decode(
                    HelperRequest.self,
                    from: data,
                    maximumBytes: configuration.maximumInputBytes
                )
                response = await client.send(request, timeoutMilliseconds: configuration.decisionTimeoutMilliseconds)
            default:
                throw InspectorError.usage
            }
            try writeJSON(response)
        } catch {
            FileHandle.standardError.write(Data("protocol-inspector: \(error)\n".utf8))
            exit(64)
        }
    }

    private static func parseDecision(_ arguments: [String]) -> HookDecision? {
        guard let first = arguments.first else { return nil }
        switch first {
        case "approve": return HookDecision.approve
        case "deny": return HookDecision.deny
        case "answer":
            return arguments.count >= 2
                ? HookDecision.answer(arguments.dropFirst().joined(separator: " "))
                : nil
        default: return nil
        }
    }

    private static func writeJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

private enum InspectorError: Error, CustomStringConvertible {
    case usage
    case invalidResolution

    var description: String {
        switch self {
        case .usage: "usage: protocol-inspector <health|pending|resolve REQUEST_ID REVISION approve|deny|answer TEXT|send FILE>"
        case .invalidResolution: "invalid decision resolution"
        }
    }
}
