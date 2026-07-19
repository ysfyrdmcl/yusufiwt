import AgentDomain
import Foundation

// Companion wire/read models are kept together so policy and lifecycle states stay auditable.
// swiftlint:disable file_length

public enum CompanionRequestKind: String, Codable, Sendable, CaseIterable {
    case approval
    case question
}

public struct CompanionQuestionDescriptor: Codable, Equatable, Sendable {
    public let kind: QuestionKind
    public let choices: [QuestionChoice]
    public let maximumAnswerLength: Int?

    public init(kind: QuestionKind, choices: [QuestionChoice] = [], maximumAnswerLength: Int? = nil) {
        self.kind = kind
        self.choices = choices
        self.maximumAnswerLength = maximumAnswerLength
    }

    public var allowsCompanionAnswer: Bool {
        kind != .secret
    }
}

public struct CompanionInboxItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let requestVersion: Int
    public let sessionID: SessionID
    public let agentName: String
    public let projectName: String
    public let title: String
    public let detail: String
    public let risk: RiskLevel
    public let kind: CompanionRequestKind
    public let question: CompanionQuestionDescriptor?
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        id: UUID,
        requestVersion: Int,
        sessionID: SessionID,
        agentName: String,
        projectName: String,
        title: String,
        detail: String,
        risk: RiskLevel,
        kind: CompanionRequestKind,
        question: CompanionQuestionDescriptor? = nil,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.requestVersion = requestVersion
        self.sessionID = sessionID
        self.agentName = agentName
        self.projectName = projectName
        self.title = title
        self.detail = detail
        self.risk = risk
        self.kind = kind
        self.question = question
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public func availability(at now: Date) -> CompanionRequestAvailability {
        if expiresAt <= now {
            return .expired
        }
        if kind == .question, question?.allowsCompanionAnswer == false {
            return .macRequired
        }
        if risk == .critical {
            return .macRequired
        }
        return .available
    }
}

public enum CompanionRequestAvailability: String, Codable, Sendable {
    case available
    case expired
    case superseded
    case macRequired
}

public struct CompanionSessionSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: SessionID
    public let agentName: String
    public let projectName: String
    public let state: SessionState
    public let startedAt: Date
    public let updatedAt: Date
    public let summary: String

    public init(
        id: SessionID,
        agentName: String,
        projectName: String,
        state: SessionState,
        startedAt: Date,
        updatedAt: Date,
        summary: String
    ) {
        self.id = id
        self.agentName = agentName
        self.projectName = projectName
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.summary = summary
    }
}

public enum CompanionDecisionSurface: String, Codable, Sendable {
    case notificationAction
    case applicationDetail
    case watch
}

public struct CompanionDecisionEvidence: Equatable, Sendable {
    public let surface: CompanionDecisionSurface
    public let strongAuthentication: Bool
    public let holdCompleted: Bool

    public init(
        surface: CompanionDecisionSurface,
        strongAuthentication: Bool = false,
        holdCompleted: Bool = false
    ) {
        self.surface = surface
        self.strongAuthentication = strongAuthentication
        self.holdCompleted = holdCompleted
    }
}

public enum CompanionAuthorizationError: Error, Equatable, Sendable {
    case requestExpired
    case approvalRequiresApplication
    case strongAuthenticationRequired
    case holdRequired
    case criticalApprovalForbidden
    case watchApprovalForbidden
    case secretAnswerForbidden
    case answerRequired
}

public extension CompanionDecisionPolicy {
    // All companion risk and authentication branches are kept in one fail-closed policy gate.
    // swiftlint:disable:next cyclomatic_complexity
    func authorize(
        outcome: CompanionRequestedOutcome,
        for item: CompanionInboxItem,
        evidence: CompanionDecisionEvidence,
        answer: String? = nil,
        now: Date
    ) throws {
        guard item.expiresAt > now else { throw CompanionAuthorizationError.requestExpired }
        if outcome == .deny {
            return
        }
        if outcome == .answer {
            guard item.kind == .question, item.question?.allowsCompanionAnswer == true else {
                throw CompanionAuthorizationError.secretAnswerForbidden
            }
            guard let answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CompanionAuthorizationError.answerRequired
            }
            return
        }
        switch item.risk {
        case .low, .medium:
            if evidence.surface == .watch, item.risk != .low {
                throw CompanionAuthorizationError.watchApprovalForbidden
            }
            return
        case .high:
            guard evidence.surface == .applicationDetail else {
                throw CompanionAuthorizationError.approvalRequiresApplication
            }
            guard evidence.strongAuthentication else {
                throw CompanionAuthorizationError.strongAuthenticationRequired
            }
            guard evidence.holdCompleted else { throw CompanionAuthorizationError.holdRequired }
        case .critical:
            throw CompanionAuthorizationError.criticalApprovalForbidden
        }
    }
}

public enum CompanionDecisionState: String, Codable, Sendable, CaseIterable {
    case queued
    case sending
    case serverAccepted
    case awaitingProviderAcknowledgment
    case applied
    case deniedApplied
    case expired
    case superseded
    case policyRejected
    case deliveryFailed

    public var isFinal: Bool {
        switch self {
        case .applied, .deniedApplied, .expired, .superseded, .policyRejected, .deliveryFailed: true
        default: false
        }
    }

    public var isSuccess: Bool {
        self == .applied || self == .deniedApplied
    }
}

public struct CompanionPendingDecision: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let requestID: UUID
    public let requestVersion: Int
    public let payload: CompanionDecisionPayload
    public var state: CompanionDecisionState
    public var envelopeID: UUID?
    public var updatedAt: Date
    public var failureReason: String?

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        requestVersion: Int,
        payload: CompanionDecisionPayload,
        state: CompanionDecisionState = .queued,
        envelopeID: UUID? = nil,
        updatedAt: Date,
        failureReason: String? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.requestVersion = requestVersion
        self.payload = payload
        self.state = state
        self.envelopeID = envelopeID
        self.updatedAt = updatedAt
        self.failureReason = failureReason
    }
}

public actor CompanionDecisionOutbox {
    private var decisions: [UUID: CompanionPendingDecision]

    public init(restored: [CompanionPendingDecision] = []) {
        decisions = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
    }

    @discardableResult
    public func enqueue(_ payload: CompanionDecisionPayload, now: Date) -> CompanionPendingDecision {
        let value = CompanionPendingDecision(
            requestID: payload.requestID,
            requestVersion: payload.requestVersion,
            payload: payload,
            updatedAt: now
        )
        decisions[value.id] = value
        return value
    }

    public func snapshot() -> [CompanionPendingDecision] {
        decisions.values.sorted { $0.updatedAt < $1.updatedAt }
    }

    public func markSending(_ id: UUID, at date: Date) {
        update(id, state: .sending, at: date)
    }

    public func markServerAccepted(_ id: UUID, envelopeID: UUID, at date: Date) {
        guard var value = decisions[id], !value.state.isFinal else { return }
        value.envelopeID = envelopeID
        value.state = .awaitingProviderAcknowledgment
        value.updatedAt = date
        value.failureReason = nil
        decisions[id] = value
    }

    public func markAcknowledged(_ acknowledgment: ProviderAcknowledgmentPayload, at date: Date) {
        guard let entry = decisions.first(where: { $0.value.requestID == acknowledgment.requestID }),
              !entry.value.state.isFinal
        else { return }
        let outcome = entry.value.payload.requestedOutcome
        let state: CompanionDecisionState = if acknowledgment.applied {
            outcome == .deny ? .deniedApplied : .applied
        } else {
            .deliveryFailed
        }
        update(entry.key, state: state, at: date)
    }

    public func markTerminal(_ id: UUID, state: CompanionDecisionState, reason: String? = nil, at date: Date) {
        guard state.isFinal, var value = decisions[id], !value.state.isFinal else { return }
        value.state = state
        value.failureReason = reason
        value.updatedAt = date
        decisions[id] = value
    }

    public func expire(at now: Date, requestExpiries: [UUID: Date]) {
        for (id, value) in decisions where !value.state.isFinal {
            if let expiry = requestExpiries[value.requestID], expiry <= now {
                update(id, state: .expired, at: now)
            }
        }
    }

    private func update(_ id: UUID, state: CompanionDecisionState, at date: Date) {
        guard var value = decisions[id], !value.state.isFinal else { return }
        value.state = state
        value.updatedAt = date
        decisions[id] = value
    }
}

public enum CompanionDeepLink: Equatable, Sendable {
    case inbox(UUID)
    case session(SessionID)
    case pairing

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["agentcontrol", "yusufiwt"].contains(scheme) else { return nil }
        let route = url.host?.lowercased()
        let identifier = url.pathComponents.dropFirst().first
        switch route {
        case "inbox":
            guard let identifier, let id = UUID(uuidString: identifier) else { return nil }
            self = .inbox(id)
        case "session":
            guard let identifier, let id = UUID(uuidString: identifier) else { return nil }
            self = .session(SessionID(id))
        case "pair":
            self = .pairing
        default:
            return nil
        }
    }
}

public enum CompanionNotificationPrivacy: String, Codable, Sendable, CaseIterable {
    case hidden
    case projectOnly
    case full
}

public struct CompanionNotificationPresentation: Equatable, Sendable {
    public let title: String
    public let body: String
    public let categoryIdentifier: String

    public init(title: String, body: String, categoryIdentifier: String) {
        self.title = title
        self.body = body
        self.categoryIdentifier = categoryIdentifier
    }
}

public enum CompanionNotificationCategory {
    public static let lowApproval = "AGENTCONTROL_APPROVAL_LOW"
    public static let mediumApproval = "AGENTCONTROL_APPROVAL_MEDIUM"
    public static let highApproval = "AGENTCONTROL_APPROVAL_HIGH"
    public static let criticalApproval = "AGENTCONTROL_APPROVAL_CRITICAL"
    public static let question = "AGENTCONTROL_QUESTION"
    public static let questionReview = "AGENTCONTROL_QUESTION_REVIEW"
    public static let status = "AGENTCONTROL_STATUS"

    public static func identifier(for item: CompanionInboxItem) -> String {
        if item.kind == .question {
            return item.question?.allowsCompanionAnswer == false ? questionReview : question
        }
        switch item.risk {
        case .low: return lowApproval
        case .medium: return mediumApproval
        case .high: return highApproval
        case .critical: return criticalApproval
        }
    }
}

public enum CompanionNotificationRenderer {
    public static func render(
        _ item: CompanionInboxItem,
        privacy: CompanionNotificationPrivacy
    ) -> CompanionNotificationPresentation {
        let category = CompanionNotificationCategory.identifier(for: item)
        switch privacy {
        case .hidden:
            return .init(title: "yusufiwt", body: "An agent needs your attention.", categoryIdentifier: category)
        case .projectOnly:
            return .init(title: item.projectName, body: "An agent needs your attention.", categoryIdentifier: category)
        case .full:
            return .init(title: item.title, body: item.detail, categoryIdentifier: category)
        }
    }

    public static let genericFallback = CompanionNotificationPresentation(
        title: "yusufiwt",
        body: "Open yusufiwt to review a new agent event.",
        categoryIdentifier: CompanionNotificationCategory.status
    )
}
