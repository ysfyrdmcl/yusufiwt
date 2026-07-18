import AgentProtocol
import Foundation

public struct CodexDiagnosticRecord: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let category: String
    public let method: String?
    public let identifiers: [String: String]
    public let code: Int?

    public init(timestamp: Date, category: String, method: String?, identifiers: [String: String], code: Int?) {
        self.timestamp = timestamp
        self.category = category
        self.method = method
        self.identifiers = identifiers
        self.code = code
    }
}

public actor CodexDiagnosticCapture {
    private let capacity: Int
    private var records: [CodexDiagnosticRecord] = []

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    public func record(_ message: CodexRPCMessage, at timestamp: Date = Date()) {
        let params: JSONValue?
        let category: String
        let code: Int?
        switch message {
        case let .request(_, _, value), let .notification(_, value):
            params = value; category = "message"; code = nil
        case .response:
            params = nil; category = "response"; code = nil
        case let .error(_, error):
            params = nil; category = "rpcError"; code = error.code
        }
        var identifiers: [String: String] = [:]
        for key in ["threadId", "turnId", "itemId", "requestId", "approvalId"] {
            if let value = params?[key]?.stringValue {
                identifiers[key] = value
            }
        }
        append(CodexDiagnosticRecord(
            timestamp: timestamp, category: category, method: message.method,
            identifiers: identifiers, code: code
        ))
    }

    public func recordTransport(category: String, at timestamp: Date = Date()) {
        append(CodexDiagnosticRecord(timestamp: timestamp, category: category, method: nil, identifiers: [:], code: nil))
    }

    public func snapshot() -> [CodexDiagnosticRecord] {
        records
    }

    private func append(_ record: CodexDiagnosticRecord) {
        records.append(record)
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
    }
}
