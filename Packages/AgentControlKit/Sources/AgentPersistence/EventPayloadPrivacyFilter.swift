import AgentProtocol

enum EventPayloadPrivacyFilter {
    private static let promptKeys: Set<String> = ["prompt", "prompttext", "userprompt", "originalprompt"]
    private static let terminalOutputKeys: Set<String> = ["stdout", "stderr", "terminaloutput", "rawoutput", "commandoutput"]

    static func filter(_ value: JSONValue, settings: PrivacySettings) -> JSONValue {
        switch value {
        case let .object(object):
            .object(object.mapValuesWithKeys { key, child in
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                if !settings.storePromptContent, promptKeys.contains(normalized) {
                    return .string("[redacted by privacy setting]")
                }
                if !settings.storeTerminalOutput, terminalOutputKeys.contains(normalized) {
                    return .string("[redacted by privacy setting]")
                }
                return filter(child, settings: settings)
            })
        case let .array(values):
            .array(values.map { filter($0, settings: settings) })
        case .string, .number, .bool, .null:
            value
        }
    }
}

private extension [String: JSONValue] {
    func mapValuesWithKeys(_ transform: (String, JSONValue) -> JSONValue) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: map { element in
            (element.key, transform(element.key, element.value))
        })
    }
}
