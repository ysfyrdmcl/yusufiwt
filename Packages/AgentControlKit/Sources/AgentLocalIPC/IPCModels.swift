#if os(macOS)
    import AgentDomain
    import AgentPersistence
    import AgentProtocol
    import Foundation

    // IPC DTOs stay together so wire compatibility is auditable in one place.
    // swiftlint:disable file_length
    public struct LocalIPCVersion: Codable, Comparable, Hashable, Sendable {
        public let major: UInt16
        public let minor: UInt16

        public init(major: UInt16, minor: UInt16 = 0) {
            self.major = major
            self.minor = minor
        }

        private enum CodingKeys: String, CodingKey {
            case major, minor
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            major = try values.decode(UInt16.self, forKey: .major)
            // A version emitted before minor negotiation existed means major.0.
            minor = try values.decodeIfPresent(UInt16.self, forKey: .minor) ?? 0
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.major == rhs.major ? lhs.minor < rhs.minor : lhs.major < rhs.major
        }
    }

    public enum LocalIPCContract {
        // Additive DTO fields advance the minor while the ACIP frame and legacy
        // negotiation continue to use the byte-compatible major version.
        public static let current = LocalIPCVersion(major: 1, minor: 2)
        public static let currentMajorVersion = current.major
        public static let currentMinorVersion = current.minor
        public static let supportedVersions = [current]
        public static let currentVersion = currentMajorVersion
        public static let maximumFrameSize = 1_048_576
        public static let magic = Data([0x41, 0x43, 0x49, 0x50]) // ACIP
        public static let machServiceName = "com.yusuf.agentcontrol.helper.xpc"

        public static func negotiate(supportedVersions offered: [LocalIPCVersion]) -> LocalIPCVersion? {
            offered
                .filter { $0.major == currentMajorVersion }
                .map { LocalIPCVersion(major: currentMajorVersion, minor: min($0.minor, currentMinorVersion)) }
                .max()
        }

        public static func supports(_ version: LocalIPCVersion) -> Bool {
            version.major == currentMajorVersion && version.minor <= currentMinorVersion
        }
    }

    public enum LocalIPCError: Error, Sendable, Equatable, CustomStringConvertible {
        case invalidMagic
        case unsupportedVersion(UInt16)
        case oversizedFrame(Int)
        case truncatedFrame
        case trailingBytes
        case checksumMismatch
        case malformedPayload
        case unauthorizedClient
        case socketFailure(code: Int32)
        case unsafeSocketPath
        case timeout
        case unavailable
        case shuttingDown

        public var description: String {
            switch self {
            case .invalidMagic: "IPC frame magic is invalid"
            case let .unsupportedVersion(version): "IPC protocol version \(version) is unsupported"
            case let .oversizedFrame(size): "IPC frame size \(size) exceeds the limit"
            case .truncatedFrame: "IPC frame is truncated"
            case .trailingBytes: "IPC frame contains trailing bytes"
            case .checksumMismatch: "IPC payload checksum is invalid"
            case .malformedPayload: "IPC payload is malformed"
            case .unauthorizedClient: "IPC client is not authorized"
            case let .socketFailure(code): "Unix socket operation failed with code \(code)"
            case .unsafeSocketPath: "Unix socket path or ownership is unsafe"
            case .timeout: "IPC operation timed out"
            case .unavailable: "Helper is unavailable"
            case .shuttingDown: "Helper is shutting down"
            }
        }
    }

    public enum SocketMessageType: UInt16, Codable, Sendable {
        case request = 1
        case response = 2
    }

    public struct SocketFrame: Sendable, Equatable {
        public let protocolVersion: UInt16
        public let messageType: SocketMessageType
        public let payload: Data

        public init(
            protocolVersion: UInt16 = LocalIPCContract.currentVersion,
            messageType: SocketMessageType,
            payload: Data
        ) {
            self.protocolVersion = protocolVersion
            self.messageType = messageType
            self.payload = payload
        }
    }

    public enum HelperRequest: Codable, Sendable {
        case negotiateProtocol(supportedVersions: [LocalIPCVersion])
        case negotiate(supportedVersions: [UInt16])
        case health
        case heartbeat
        case submitEvent(HelperEventSubmission)
        case requestDecision(HookDecisionRequest)
        case pendingDecisions
        case decisionLifecycles
        case resolveDecision(HookDecisionResolution)
        case listSessions(limit: Int)
        case sessionSnapshot(SessionID)
        case interruptCodexSession(SessionID)
        case sessionEvents(sessionID: SessionID, limit: Int)
        case history(HistoryQuery)
        case analytics(AnalyticsQuery)
        case listRules
        case upsertRule(OperationsRule)
        case deleteRule(UUID)
        case activeAlerts
        case privacySettings
        case savePrivacySettings(PrivacySettings)
        case diagnostics
        case repair(RepairAction)
        case deleteCompletedHistory(endedBefore: Date)
        case prepareForUpdate
    }

    public enum HelperResponse: Codable, Sendable, Equatable {
        case protocolNegotiated(version: LocalIPCVersion)
        case negotiated(version: UInt16)
        case health(HelperHealth)
        case heartbeat(HelperHeartbeat)
        case eventAccepted(EventAppendDisposition)
        case decision(HookDecisionResult)
        case pendingDecisions([PendingHookDecision])
        case decisionLifecycles([DecisionLifecycleSnapshot])
        case decisionResolution(DecisionResolutionDisposition)
        case sessionList([SessionListItem])
        case sessionSnapshot(AgentSession?)
        case codexInterruptRequested(Bool)
        case sessionEvents([PersistedSessionEvent])
        case history(HistoryPage)
        case analytics(AnalyticsSummary)
        case rules([OperationsRule])
        case ruleSaved(OperationsRule)
        case ruleDeleted(Bool)
        case activeAlerts([SessionAlert])
        case privacySettings(PrivacySettings)
        case diagnostics(DiagnosticsReport)
        case repair(RepairResult)
        case dataDeletion(DataDeletionResult)
        case updateHandoff(UpdateHandoff)
        case registryEvent(RegistryNotification)
        case neutral(reason: NeutralFallbackReason)
        case failure(code: String, safeMessage: String)
    }

    public struct HelperEventSubmission: Codable, Sendable {
        public let envelope: EventEnvelope
        public let initialSession: AgentSession

        public init(envelope: EventEnvelope, initialSession: AgentSession) {
            self.envelope = envelope
            self.initialSession = initialSession
        }
    }

    public enum HookDecisionKind: String, Codable, Sendable, Equatable {
        case approval
        case question
        case plan
    }

    public struct HookDecisionRequest: Codable, Sendable {
        public let requestID: UUID
        public let revision: Int64
        public let kind: HookDecisionKind
        public let prompt: String
        public let choices: [QuestionChoice]
        public let maximumAnswerLength: Int?
        public let expiresAt: Date?
        public let waitTimeoutMilliseconds: Int
        public let submission: HelperEventSubmission

        public init(
            requestID: UUID,
            revision: Int64,
            kind: HookDecisionKind,
            prompt: String,
            choices: [QuestionChoice] = [],
            maximumAnswerLength: Int? = nil,
            expiresAt: Date? = nil,
            waitTimeoutMilliseconds: Int = 25000,
            submission: HelperEventSubmission
        ) {
            self.requestID = requestID
            self.revision = revision
            self.kind = kind
            self.prompt = prompt
            self.choices = choices
            self.maximumAnswerLength = maximumAnswerLength
            self.expiresAt = expiresAt
            self.waitTimeoutMilliseconds = waitTimeoutMilliseconds
            self.submission = submission
        }

        public init(
            requestID: UUID,
            revision: Int64,
            kind: HookDecisionKind,
            prompt: String,
            legacyChoiceLabels: [String],
            maximumAnswerLength: Int? = nil,
            expiresAt: Date? = nil,
            waitTimeoutMilliseconds: Int = 25000,
            submission: HelperEventSubmission
        ) {
            self.init(
                requestID: requestID,
                revision: revision,
                kind: kind,
                prompt: prompt,
                choices: legacyChoiceLabels.map(QuestionChoice.legacy(label:)),
                maximumAnswerLength: maximumAnswerLength,
                expiresAt: expiresAt,
                waitTimeoutMilliseconds: waitTimeoutMilliseconds,
                submission: submission
            )
        }

        public init(
            requestID: UUID,
            revision: Int64,
            kind: HookDecisionKind,
            prompt: String,
            choices: [String],
            maximumAnswerLength: Int? = nil,
            expiresAt: Date? = nil,
            waitTimeoutMilliseconds: Int = 25000,
            submission: HelperEventSubmission
        ) {
            self.init(
                requestID: requestID,
                revision: revision,
                kind: kind,
                prompt: prompt,
                legacyChoiceLabels: choices,
                maximumAnswerLength: maximumAnswerLength,
                expiresAt: expiresAt,
                waitTimeoutMilliseconds: waitTimeoutMilliseconds,
                submission: submission
            )
        }
    }

    public enum HookDecision: Codable, Sendable, Equatable {
        case approve
        case deny
        case answerChoice(id: String)
        case answerChoices(ids: [String])
        case answerText(String)
        case confirm(Bool)
        case requestPlanChanges(String)
    }

    public struct HookDecisionResult: Codable, Sendable, Equatable {
        public let requestID: UUID
        public let revision: Int64
        public let decision: HookDecision

        public init(requestID: UUID, revision: Int64, decision: HookDecision) {
            self.requestID = requestID
            self.revision = revision
            self.decision = decision
        }
    }

    public struct HookDecisionResolution: Codable, Sendable {
        public let requestID: UUID
        public let revision: Int64
        public let decision: HookDecision

        public init(requestID: UUID, revision: Int64, decision: HookDecision) {
            self.requestID = requestID
            self.revision = revision
            self.decision = decision
        }
    }

    public struct PendingHookDecision: Codable, Sendable, Equatable {
        public let requestID: UUID
        public let sessionID: SessionID
        public let revision: Int64
        public let kind: HookDecisionKind
        public let prompt: String
        public let choices: [QuestionChoice]
        public let maximumAnswerLength: Int?
        public let expiresAt: Date?
        public let projectName: String?
        public let projectRootURL: URL?
        public let terminalContext: TerminalContext?
        public let privacyClass: PrivacyClass?
        public let approval: ApprovalRequest?
        public let question: AgentQuestion?
        public let planTitle: String?
        public let planChangesSupported: Bool?
        public let provider: String?

        public init(request: HookDecisionRequest) {
            requestID = request.requestID
            sessionID = request.submission.envelope.sessionID
            revision = request.revision
            kind = request.kind
            prompt = request.prompt
            choices = request.choices
            maximumAnswerLength = request.maximumAnswerLength
            expiresAt = request.expiresAt
            let submission = request.submission
            projectName = submission.initialSession.project.name
            projectRootURL = submission.initialSession.project.rootURL
            terminalContext = submission.initialSession.terminalContext
            privacyClass = submission.envelope.privacyClass
            approval = request.kind == .approval
                ? Self.decode(ApprovalRequest.self, from: submission.envelope.payload)
                : nil
            question = request.kind == .question
                ? Self.decode(AgentQuestion.self, from: submission.envelope.payload)
                : nil
            if request.kind == .plan {
                planTitle = submission.envelope.payload["title"]?.stringValue ?? request.prompt
                if case let .bool(value)? = submission.envelope.payload["allowsPlanChanges"] {
                    planChangesSupported = value
                } else {
                    planChangesSupported = nil
                }
            } else {
                planTitle = nil
                planChangesSupported = nil
            }
            provider = submission.initialSession.adapterID.rawValue
        }

        private static func decode<T: Decodable>(_ type: T.Type, from payload: JSONValue) -> T? {
            guard let data = try? JSONEncoder().encode(payload) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
    }

    public enum DecisionResolutionDisposition: String, Codable, Sendable, Equatable {
        case accepted
        case notFound
        case revisionMismatch
        case expired
        case invalidDecision
    }

    public enum DecisionResolutionSource: String, Codable, Sendable, Equatable {
        case user
        case automation
    }

    /// Helper-owned lifecycle state. A local decision is deliberately distinct from
    /// provider application so UI surfaces cannot report success before an ack event.
    public enum DecisionLifecycleState: String, Codable, Sendable, Equatable {
        case awaitingUser
        case userResolvedAwaitingProviderAck
        case automaticallyResolvedAwaitingProviderAck
        case providerAcknowledged
        case applied
        case deniedApplied
        case expired
        case cancelled
        case superseded
        case providerRejected

        public var isActionable: Bool {
            self == .awaitingUser
        }

        public var isFinal: Bool {
            switch self {
            case .applied, .deniedApplied, .expired, .cancelled, .superseded, .providerRejected:
                true
            case .awaitingUser, .userResolvedAwaitingProviderAck,
                 .automaticallyResolvedAwaitingProviderAck, .providerAcknowledged:
                false
            }
        }
    }

    public struct DecisionLifecycleSnapshot: Codable, Sendable, Equatable {
        public let requestID: UUID
        public let sessionID: SessionID
        public let revision: Int64
        public let kind: HookDecisionKind
        public let provider: String?
        public let projectName: String?
        public let state: DecisionLifecycleState
        public let resolutionSource: DecisionResolutionSource?
        public let decision: HookDecision?
        public let expiresAt: Date?
        public let updatedAt: Date

        public init(
            requestID: UUID,
            sessionID: SessionID,
            revision: Int64,
            kind: HookDecisionKind,
            provider: String? = nil,
            projectName: String? = nil,
            state: DecisionLifecycleState,
            resolutionSource: DecisionResolutionSource? = nil,
            decision: HookDecision? = nil,
            expiresAt: Date? = nil,
            updatedAt: Date
        ) {
            self.requestID = requestID
            self.sessionID = sessionID
            self.revision = revision
            self.kind = kind
            self.provider = provider
            self.projectName = projectName
            self.state = state
            self.resolutionSource = resolutionSource
            self.decision = decision
            self.expiresAt = expiresAt
            self.updatedAt = updatedAt
        }
    }

    public enum EventAppendDisposition: String, Codable, Sendable, Equatable {
        case appended
        case duplicate
        case recordedWithoutStateChange
        case rejectedTransition
        case spooled
    }

    public enum NeutralFallbackReason: String, Codable, Sendable, Equatable {
        case helperUnavailable
        case timeout
        case unsupportedProtocol
        case shuttingDown
    }

    public struct HelperHealth: Codable, Sendable, Equatable {
        public let protocolVersion: UInt16
        public let processID: Int32
        public let uptimeSeconds: TimeInterval
        public let activeSessionCount: Int
        public let persistedEventCount: Int
        public let spoolPendingCount: Int
        public let pendingDecisionCount: Int?
        public let socketAcceptingConnections: Bool
        public let databaseHealthy: Bool

        public init(
            protocolVersion: UInt16,
            processID: Int32,
            uptimeSeconds: TimeInterval,
            activeSessionCount: Int,
            persistedEventCount: Int,
            spoolPendingCount: Int,
            pendingDecisionCount: Int? = nil,
            socketAcceptingConnections: Bool,
            databaseHealthy: Bool
        ) {
            self.protocolVersion = protocolVersion
            self.processID = processID
            self.uptimeSeconds = uptimeSeconds
            self.activeSessionCount = activeSessionCount
            self.persistedEventCount = persistedEventCount
            self.spoolPendingCount = spoolPendingCount
            self.pendingDecisionCount = pendingDecisionCount
            self.socketAcceptingConnections = socketAcceptingConnections
            self.databaseHealthy = databaseHealthy
        }
    }

    public struct HelperHeartbeat: Codable, Sendable, Equatable {
        public let sequence: UInt64
        public let emittedAt: Date

        public init(sequence: UInt64, emittedAt: Date) {
            self.sequence = sequence
            self.emittedAt = emittedAt
        }
    }

    public struct UpdateHandoff: Codable, Sendable, Equatable {
        public let token: UUID
        public let preparedAt: Date
        public let persistedEventCount: Int

        public init(token: UUID, preparedAt: Date, persistedEventCount: Int) {
            self.token = token
            self.preparedAt = preparedAt
            self.persistedEventCount = persistedEventCount
        }
    }
#endif
