public enum Retryability: String, Codable, Sendable { case never, retryable, retryAfterUserAction }

public struct ErrorDescriptor: Codable, Sendable, Equatable {
    public let code: String
    public let userMessage: String
    public let redactedContext: String?
    public let retryability: Retryability
    public let recoverySuggestion: String

    public init(
        code: String,
        userMessage: String,
        redactedContext: String? = nil,
        retryability: Retryability,
        recoverySuggestion: String
    ) {
        self.code = code
        self.userMessage = userMessage
        self.redactedContext = redactedContext
        self.retryability = retryability
        self.recoverySuggestion = recoverySuggestion
    }
}

public protocol TypedAgentError: Error, Sendable {
    var descriptor: ErrorDescriptor { get }
}

public struct ConfigurationError: TypedAgentError { public let descriptor: ErrorDescriptor; public init(_ descriptor: ErrorDescriptor) {
    self.descriptor = descriptor
} }
public struct IntegrationError: TypedAgentError { public let descriptor: ErrorDescriptor; public init(_ descriptor: ErrorDescriptor) {
    self.descriptor = descriptor
} }
public struct ProtocolError: TypedAgentError { public let descriptor: ErrorDescriptor; public init(_ descriptor: ErrorDescriptor) {
    self.descriptor = descriptor
} }
public struct PersistenceError: TypedAgentError { public let descriptor: ErrorDescriptor; public init(_ descriptor: ErrorDescriptor) {
    self.descriptor = descriptor
} }
public struct SecurityError: TypedAgentError { public let descriptor: ErrorDescriptor; public init(_ descriptor: ErrorDescriptor) {
    self.descriptor = descriptor
} }
public struct RelayError: TypedAgentError { public let descriptor: ErrorDescriptor; public init(_ descriptor: ErrorDescriptor) {
    self.descriptor = descriptor
} }
public struct NotificationError: TypedAgentError { public let descriptor: ErrorDescriptor; public init(_ descriptor: ErrorDescriptor) {
    self.descriptor = descriptor
} }
public struct NavigationError: TypedAgentError { public let descriptor: ErrorDescriptor; public init(_ descriptor: ErrorDescriptor) {
    self.descriptor = descriptor
} }
public struct PolicyError: TypedAgentError { public let descriptor: ErrorDescriptor; public init(_ descriptor: ErrorDescriptor) {
    self.descriptor = descriptor
} }
