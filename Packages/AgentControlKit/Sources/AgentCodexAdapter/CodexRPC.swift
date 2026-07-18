import AgentProtocol
import Foundation

public enum CodexRPCID: Codable, Hashable, Sendable, CustomStringConvertible {
    case integer(Int64)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else {
            self = try .string(container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case let .integer(value): String(value)
        case let .string(value): value
        }
    }
}

public struct CodexRPCError: Codable, Equatable, Sendable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public enum CodexRPCMessage: Equatable, Sendable {
    case request(id: CodexRPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: CodexRPCID, result: JSONValue)
    case error(id: CodexRPCID?, error: CodexRPCError)

    public var method: String? {
        switch self {
        case let .request(_, method, _), let .notification(method, _): method
        case .response, .error: nil
        }
    }

    public var id: CodexRPCID? {
        switch self {
        case let .request(id, _, _), let .response(id, _): id
        case let .error(id, _): id
        case .notification: nil
        }
    }
}

extension CodexRPCMessage: Codable {
    private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params, result, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let version = try container.decodeIfPresent(String.self, forKey: .jsonrpc), version != "2.0" {
            throw CodexAdapterError.invalidJSONRPCVersion
        }

        if let method = try container.decodeIfPresent(String.self, forKey: .method) {
            let params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
            if let id = try container.decodeIfPresent(CodexRPCID.self, forKey: .id) {
                self = .request(id: id, method: method, params: params)
            } else {
                self = .notification(method: method, params: params)
            }
        } else if let error = try container.decodeIfPresent(CodexRPCError.self, forKey: .error) {
            self = try .error(id: container.decodeIfPresent(CodexRPCID.self, forKey: .id), error: error)
        } else {
            self = try .response(
                id: container.decode(CodexRPCID.self, forKey: .id),
                result: container.decodeIfPresent(JSONValue.self, forKey: .result) ?? .null
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .request(id, method, params):
            try container.encode(id, forKey: .id)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
        case let .notification(method, params):
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
        case let .response(id, result):
            try container.encode(id, forKey: .id)
            try container.encode(result, forKey: .result)
        case let .error(id, error):
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(error, forKey: .error)
        }
    }
}

public struct CodexJSONLCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    public func encode(_ message: CodexRPCMessage) throws -> Data {
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }

    public func decode(line: Data) throws -> CodexRPCMessage {
        guard !line.isEmpty, !line.contains(0) else { throw CodexAdapterError.malformedJSONL }
        let payload = line.last == 0x0A ? line.dropLast() : line[...]
        guard payload.count <= CodexAppServerContract.maximumLineBytes else {
            throw CodexAdapterError.messageTooLarge
        }
        return try decoder.decode(CodexRPCMessage.self, from: Data(payload))
    }
}

public enum CodexAdapterError: Error, Equatable, Sendable {
    case binaryNotFound
    case versionDetectionFailed
    case invalidJSONRPCVersion
    case malformedJSONL
    case messageTooLarge
    case processAlreadyRunning
    case processNotRunning
    case processLaunchFailed
    case transportClosed
    case invalidPayload(String)
    case unknownRequest(CodexRPCID)
    case requestExpired
    case requestCancelled
    case schemaMismatch([String])
    case monitorOnly(String)
}

public enum CodexAppServerContract {
    public static let maximumLineBytes = 4 * 1024 * 1024
    public static let requiredMethods: Set<String> = [
        "initialize", "thread/start", "turn/start", "turn/interrupt",
        "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
        "item/started", "item/completed", "turn/started", "turn/completed",
        "serverRequest/resolved"
    ]

    public static let adapterID = "openai.codex.app-server.v2"
}
