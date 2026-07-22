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
                       adapterVersion != "transcript-v1" {
                        authoritativeSessionIDs.insert(item.id)
                    }
                    authorityCheckedSessionIDs.insert(item.id)
                    restored += 1
                }
            }
            return restored
        }

        public func ingest(_ submission: HelperEventSubmission) async throws -> EventAppendDisposition {
            guard submission.envelope.sessionID == submission.initialSession.id,
                  submission.envelope.source.nodeID == submission.initialSession.nodeID
            else { throw LocalIPCError.malformedPayload }

            if Self.isTranscriptFallback(submission.envelope) {
                if !authorityCheckedSessionIDs.contains(submission.envelope.sessionID) {
                    if let adapterVersion = try await database.sessionAdapterVersion(id: submission.envelope.sessionID),
                       adapterVersion != "transcript-v1" {
                        authoritativeSessionIDs.insert(submission.envelope.sessionID)
                    }
                    authorityCheckedSessionIDs.insert(submission.envelope.sessionID)
                }
                guard !authoritativeSessionIDs.contains(submission.envelope.sessionID) else { return .duplicate }
            } else {
                // Once a hook or managed adapter has spoken for a session, its
                // structured events remain authoritative over transcript timing.
                authoritativeSessionIDs.insert(submission.envelope.sessionID)
                authorityCheckedSessionIDs.insert(submission.envelope.sessionID)
            }

            var aggregate = aggregates[submission.envelope.sessionID]
                ?? SessionAggregate(session: submission.initialSession)
            let event = SequencedAgentEvent(
                id: submission.envelope.eventID,
                sourceKey: Self.sourceKey(submission.envelope),
                sequence: submission.envelope.sequence,
                event: submission.envelope.domainEvent
            )
            let application = aggregate.apply(event)
            if application == .duplicate || application == .outOfOrder {
                return .duplicate
            }
            let meaningfulAt = Self.isUnknown(submission.envelope.domainEvent)
                ? aggregate.session.lastMeaningfulEventAt
                : submission.envelope.receivedAt
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

        public func activeSessionCount() -> Int {
            aggregates.values.count { !$0.session.state.isTerminal }
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
