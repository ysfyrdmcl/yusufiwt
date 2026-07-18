import AgentDomain
import AgentProtocol
import Foundation

public enum PersistenceError: Error, Sendable, Equatable, CustomStringConvertible {
    case migrationChecksumMismatch(version: Int)
    case migrationGap(expected: Int, found: Int)
    case secretPersistenceForbidden
    case encryptionUnavailable
    case invalidStoredValue(String)
    case databaseClosed

    public var description: String {
        switch self {
        case let .migrationChecksumMismatch(version): "Migration \(version) checksum does not match the applied schema"
        case let .migrationGap(expected, found): "Migration sequence is not contiguous; expected \(expected), found \(found)"
        case .secretPersistenceForbidden: "Secret-class event payloads must not be persisted"
        case .encryptionUnavailable: "Sensitive field encryption is not configured"
        case let .invalidStoredValue(name): "Stored database value is invalid: \(name)"
        case .databaseClosed: "Database is closed"
        }
    }
}

public struct DatabaseConfiguration: Sendable {
    public let url: URL?
    public let busyTimeoutMilliseconds: Int
    public let automaticBackupBeforeMigration: Bool

    public init(
        url: URL?,
        busyTimeoutMilliseconds: Int = 5000,
        automaticBackupBeforeMigration: Bool = true
    ) {
        self.url = url
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.automaticBackupBeforeMigration = automaticBackupBeforeMigration
    }

    public static var inMemory: DatabaseConfiguration {
        DatabaseConfiguration(url: nil, automaticBackupBeforeMigration: false)
    }
}

public struct EventWrite: Sendable {
    public let envelope: EventEnvelope
    public let snapshot: AgentSession

    public init(envelope: EventEnvelope, snapshot: AgentSession) {
        self.envelope = envelope
        self.snapshot = snapshot
    }
}

public enum EventAppendResult: Sendable, Equatable {
    case appended
    case duplicate
}

public struct PersistedSessionEvent: Codable, Sendable, Equatable {
    public let envelope: EventEnvelope
    public let wasEncrypted: Bool

    public init(envelope: EventEnvelope, wasEncrypted: Bool) {
        self.envelope = envelope
        self.wasEncrypted = wasEncrypted
    }
}

public struct SessionListItem: Codable, Sendable, Equatable, Identifiable {
    public let id: SessionID
    public let projectName: String
    public let adapterID: AdapterID
    public let state: SessionState
    public let lastMeaningfulEventAt: Date
    public let snapshotRevision: Int64

    public init(
        id: SessionID,
        projectName: String,
        adapterID: AdapterID,
        state: SessionState,
        lastMeaningfulEventAt: Date,
        snapshotRevision: Int64
    ) {
        self.id = id
        self.projectName = projectName
        self.adapterID = adapterID
        self.state = state
        self.lastMeaningfulEventAt = lastMeaningfulEventAt
        self.snapshotRevision = snapshotRevision
    }
}

public struct AuditEntry: Sendable, Equatable {
    public let id: UUID
    public let category: String
    public let action: String
    public let targetID: String?
    public let metadata: Data?
    public let createdAt: Date

    public init(
        id: UUID,
        category: String,
        action: String,
        targetID: String? = nil,
        metadata: Data? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.category = category
        self.action = action
        self.targetID = targetID
        self.metadata = metadata
        self.createdAt = createdAt
    }
}

public enum DatabaseHealth: Sendable, Equatable {
    case healthy
    case corrupt(details: String)
    case unreadable(details: String)
}

public struct RecoveryReport: Sendable, Equatable {
    public let health: DatabaseHealth
    public let canOpenReadOnly: Bool
    public let userFacingRecoveryRequired: Bool

    public init(health: DatabaseHealth, canOpenReadOnly: Bool, userFacingRecoveryRequired: Bool) {
        self.health = health
        self.canOpenReadOnly = canOpenReadOnly
        self.userFacingRecoveryRequired = userFacingRecoveryRequired
    }
}

public struct DatabaseRuntimeSettings: Sendable, Equatable {
    public let journalMode: String
    public let foreignKeysEnabled: Bool
    public let busyTimeoutMilliseconds: Int

    public init(journalMode: String, foreignKeysEnabled: Bool, busyTimeoutMilliseconds: Int) {
        self.journalMode = journalMode
        self.foreignKeysEnabled = foreignKeysEnabled
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
    }
}
