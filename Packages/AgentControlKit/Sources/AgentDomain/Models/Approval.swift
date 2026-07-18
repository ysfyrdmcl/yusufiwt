import Foundation

public struct ApprovalRequest: Codable, Sendable, Identifiable, Equatable {
    public let id: ApprovalRequestID
    public let sessionID: SessionID
    public let providerRequestID: String
    public let action: AgentAction
    public let risk: RiskAssessment
    public let createdAt: Date
    public let expiresAt: Date?
    public let revision: Int64
    public var status: ApprovalStatus

    public init(
        id: ApprovalRequestID,
        sessionID: SessionID,
        providerRequestID: String,
        action: AgentAction,
        risk: RiskAssessment,
        createdAt: Date,
        expiresAt: Date?,
        revision: Int64,
        status: ApprovalStatus
    ) {
        self.id = id
        self.sessionID = sessionID
        self.providerRequestID = providerRequestID
        self.action = action
        self.risk = risk
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.revision = revision
        self.status = status
    }
}
