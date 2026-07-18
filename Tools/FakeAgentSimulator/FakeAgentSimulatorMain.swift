import AgentHookKit
import AgentLocalIPC
import Darwin
import Foundation

@main
enum FakeAgentSimulatorMain {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let scenarioName = arguments.first,
                  let scenario = FakeAgentScenario(rawValue: scenarioName)
            else { throw SimulatorError.usage }

            let configuration = try HookConfiguration.environment()
            let timeout = integerOption("--timeout-ms", in: arguments) ?? Int(configuration.decisionTimeoutMilliseconds)
            let automaticDecision = stringOption("--auto-decision", in: arguments).flatMap(parseDecision)
            let client = AgentControlHookClient(configuration: configuration)
            let builder = FakeAgentScenarioBuilder()

            for step in builder.steps(for: scenario, decisionTimeoutMilliseconds: timeout) {
                let response: HelperResponse
                switch step {
                case let .emit(submission):
                    response = await client.emit(submission)
                case let .requestDecision(request):
                    if let automaticDecision {
                        async let pendingResponse = client.requestDecision(request)
                        try await Task.sleep(for: .milliseconds(75))
                        _ = await client.send(
                            .resolveDecision(HookDecisionResolution(
                                requestID: request.requestID,
                                revision: request.revision,
                                decision: automaticDecision
                            )),
                            timeoutMilliseconds: 1000
                        )
                        response = await pendingResponse
                    } else {
                        log("Waiting for decision \(request.requestID.uuidString.lowercased()); use protocol-inspector pending/resolve.")
                        response = await client.requestDecision(request)
                    }
                }
                try writeJSON(response)
            }
        } catch {
            log("fake-agent-simulator: \(error)")
            exit(64)
        }
    }

    private static func parseDecision(_ value: String) -> HookDecision? {
        switch value {
        case "approve": HookDecision.approve
        case "deny": HookDecision.deny
        default:
            value.hasPrefix("answer:")
                ? HookDecision.answerText(String(value.dropFirst("answer:".count)))
                : nil
        }
    }

    private static func stringOption(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func integerOption(_ name: String, in arguments: [String]) -> Int? {
        stringOption(name, in: arguments).flatMap(Int.init)
    }

    private static func writeJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func log(_ value: String) {
        FileHandle.standardError.write(Data((value + "\n").utf8))
    }
}

private enum SimulatorError: Error, CustomStringConvertible {
    case usage

    var description: String {
        "usage: fake-agent-simulator <\(FakeAgentScenario.allCases.map(\.rawValue).joined(separator: "|"))> [--timeout-ms N] [--auto-decision approve|deny|answer:TEXT]"
    }
}
