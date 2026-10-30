#if os(macOS)
    import AgentDomain
    import AgentPersistence
    import AgentProtocol
    import Foundation

    public struct RegistryNotification: Codable, Sendable, Equatable {
        public let sessionID: SessionID
        public let eventID: EventID
        public let state: SessionState
        public let snapshotRevision: Int64

        public init(sessionID: SessionID, eventID: EventID, state: SessionState, snapshotRevision: Int64) {
            self.sessionID = sessionID
            self.eventID = eventID
            self.state = state
            self.snapshotRevision = snapshotRevision
        }
    }

    public actor SessionRegistryActor {
        private let database: DatabaseActor
        private var aggregates: [SessionID: SessionAggregate] = [:]
        private var authoritativeSessionIDs: Set<SessionID> = []
        private var authorityCheckedSessionIDs: Set<SessionID> = []
        private var continuations: [UUID: AsyncStream<RegistryNotification>.Continuation] = [:]
        private var isIngesting = false
        private var ingestionWaiters: [CheckedContinuation<Void, Never>] = []

        public init(database: DatabaseActor) {
            self.database = database
        }

        @discardableResult
        public func restoreActiveSnapshots() async throws -> Int {
            let active = try await database.sessions(limit: 1000).filter { !$0.state.isTerminal }
            var restored = 0
            for item in active {
                if let snapshot = try await database.session(id: item.id) {
                    let sequences = try await database.latestSequenceBySource(sessionID: item.id)
                    aggregates[item.id] = SessionAggregate(
                        session: snapshot,
                        lastSequenceBySource: sequences
                    )
                    if let adapterVersion = try await database.sessionAdapterVersion(id: item.id),
                       adapterVersion != "transcript-v1", adapterVersion != "liveness-v1" {
                        authoritativeSessionIDs.insert(item.id)
                    }
                    authorityCheckedSessionIDs.insert(item.id)
                    restored += 1
                }
            }
            return restored
        }

        // Ingestion keeps authority, ordering, persistence, and notification decisions atomic.
        // swiftlint:disable:next cyclomatic_complexity function_body_length
        public func ingest(_ submission: HelperEventSubmission) async throws -> EventAppendDisposition {
            if isIngesting {
                await withCheckedContinuation { ingestionWaiters.append($0) }
            }
            isIngesting = true
            defer {
                if ingestionWaiters.isEmpty {
                    isIngesting = false
                } else {
                    ingestionWaiters.removeFirst().resume()
                }
            }
            guard submission.envelope.sessionID == submission.initialSession.id,
                  submission.envelope.source.nodeID == submission.initialSession.nodeID
            else { throw LocalIPCError.malformedPayload }

            var domainEvent = submission.envelope.domainEvent
            var metricsOnly = false
            if Self.isTranscriptFallback(submission.envelope) {
                if !authorityCheckedSessionIDs.contains(submission.envelope.sessionID) {
                    if let adapterVersion = try await database.sessionAdapterVersion(id: submission.envelope.sessionID),
                       adapterVersion != "transcript-v1", adapterVersion != "liveness-v1" {
                        authoritativeSessionIDs.insert(submission.envelope.sessionID)
                    }
                    authorityCheckedSessionIDs.insert(submission.envelope.sessionID)
                }
                if authoritativeSessionIDs.contains(submission.envelope.sessionID) {
                    guard case let .usageUpdated(update) = domainEvent else { return .duplicate }
                    domainEvent = .usageUpdated(SessionUsageUpdate(metrics: update.metrics))
                    metricsOnly = true
                }
            } else if submission.envelope.source.adapterVersion != "liveness-v1" {
                // Once a hook or managed adapter has spoken for a session, its
                // structured events remain authoritative over transcript timing.
                authoritativeSessionIDs.insert(submission.envelope.sessionID)
                authorityCheckedSessionIDs.insert(submission.envelope.sessionID)
            }

            if aggregates[submission.envelope.sessionID] == nil,
               let persisted = try await database.session(id: submission.envelope.sessionID) {
                let sequences = try await database.latestSequenceBySource(sessionID: persisted.id)
                aggregates[persisted.id] = SessionAggregate(session: persisted, lastSequenceBySource: sequences)
            }
            var aggregate = aggregates[submission.envelope.sessionID]
                ?? SessionAggregate(session: submission.initialSession)
            let event = SequencedAgentEvent(
                id: submission.envelope.eventID,
                sourceKey: Self.sourceKey(submission.envelope),
                sequence: submission.envelope.sequence,
                event: domainEvent
            )
            let application = aggregate.apply(event)
            if application == .duplicate || application == .outOfOrder {
                return .duplicate
            }
            aggregate.updateTerminalContext(submission.initialSession.terminalContext)
            let meaningfulAt = metricsOnly || Self.isUnknown(submission.envelope.domainEvent)
                ? aggregate.session.lastMeaningfulEventAt
                : (Self.isTranscriptFallback(submission.envelope) ? submission.envelope.occurredAt : submission.envelope.receivedAt)
            aggregate.updateSnapshotMetadata(
                lastMeaningfulEventAt: meaningfulAt,
                endedAt: aggregate.session.state.isTerminal ? submission.envelope.receivedAt : aggregate.session.endedAt
            )
            aggregate.updateActivitySummary(SessionActivitySummarizer().summary(for: submission.envelope))
            let snapshot = aggregate.session
            let appendResult = try await database.append(EventWrite(envelope: submission.envelope, snapshot: snapshot))
            guard appendResult == .appended else { return .duplicate }

            aggregates[submission.envelope.sessionID] = aggregate
            let notification = RegistryNotification(
                sessionID: snapshot.id,
                eventID: submission.envelope.eventID,
                state: snapshot.state,
                snapshotRevision: snapshot.snapshotRevision
            )
            for continuation in continuations.values {
                continuation.yield(notification)
            }
            switch application {
            case .applied: return .appended
            case .duplicate, .outOfOrder: return .duplicate
            case .recordedWithoutStateChange: return .recordedWithoutStateChange
            case .rejectedTransition: return .rejectedTransition
            }
        }

        /// Expire abandoned working records without deleting history or pending decisions.
        public func expireInactiveSessions(at date: Date, inactivityLimit: TimeInterval = 20 * 60) async throws {
            for item in try await database.sessions(limit: 1000)
                where [.starting, .thinking, .running, .executing].contains(item.state)
                && date.timeIntervalSince(item.lastMeaningfulEventAt) > inactivityLimit {
                guard let session = try await database.session(id: item.id) else { continue }
                let envelope = EventEnvelope(
                    eventID: EventID(UUID()), eventType: "session.stateChanged",
                    source: EventSource(adapterID: session.adapterID, adapterVersion: "liveness-v1", nodeID: session.nodeID, processID: -2),
                    sessionID: session.id, providerSessionID: session.externalSessionID,
                    sequence: Int64(date.timeIntervalSince1970 * 1_000_000), occurredAt: date, receivedAt: date,
                    payload: .object(["state": .string(SessionState.stale.rawValue)]), privacyClass: .privateMetadata,
                    correlationID: EnvelopeID(UUID()), schemaHash: "agentcontrol-liveness-v1"
                )
                _ = try await ingest(HelperEventSubmission(envelope: envelope, initialSession: session))
            }
        }

        public func activeSessionCount() -> Int {
            aggregates.values.count { !$0.session.state.isTerminal && ![.stale, .disconnected, .paused, .discovered].contains($0.session.state) }
        }

        public func session(id: SessionID) -> AgentSession? {
            aggregates[id]?.session
        }

        public func notifications() -> AsyncStream<RegistryNotification> {
            let id = UUID()
            return AsyncStream { continuation in
                continuations[id] = continuation
                continuation.onTermination = { [weak self] _ in
                    Task { await self?.removeContinuation(id) }
                }
            }
        }

        private func removeContinuation(_ id: UUID) {
            continuations.removeValue(forKey: id)
        }

        private static func sourceKey(_ envelope: EventEnvelope) -> String {
            "\(envelope.source.adapterID.rawValue)|\(envelope.source.nodeID.description)|\(envelope.source.processID.map(String.init) ?? "-")"
        }

        private static func isUnknown(_ event: AgentEvent) -> Bool {
            if case .unknown = event {
                return true
            }
            return false
        }

        private static func isTranscriptFallback(_ envelope: EventEnvelope) -> Bool {
            envelope.source.adapterVersion == "transcript-v1"
        }
    }
#endif
