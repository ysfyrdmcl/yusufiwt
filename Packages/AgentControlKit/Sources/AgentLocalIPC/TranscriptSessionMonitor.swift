#if os(macOS)
    import AgentDomain
    import AgentProtocol
    import Foundation

    struct TranscriptSessionObservation: Equatable, Sendable {
        enum Provider: String, Sendable {
            case codex
            case claude
        }

        let provider: Provider
        let externalSessionID: String
        let parentExternalSessionID: String?
        let projectURL: URL
        let transcriptURL: URL
        let modifiedAt: Date
        let startedAt: Date

        var sessionID: SessionID {
            SessionID(TranscriptStableIdentifier.uuid("session:\(provider.rawValue):\(externalSessionID)"))
        }

        var parentSessionID: SessionID? {
            parentExternalSessionID.map {
                SessionID(TranscriptStableIdentifier.uuid("session:\(provider.rawValue):\($0)"))
            }
        }
    }

    /// Discovers the structured JSONL transcripts written by Codex and Claude Code.
    /// Only session metadata is retained; prompts and assistant output are never read
    /// into an AgentControl event or persisted by this fallback.
    struct TranscriptSessionScanner: Sendable {
        let codexRoot: URL
        let claudeRoot: URL
        let visibilityInterval: TimeInterval

        init(
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
            visibilityInterval: TimeInterval = 6 * 60 * 60
        ) {
            codexRoot = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
            claudeRoot = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
            self.visibilityInterval = visibilityInterval
        }

        init(codexRoot: URL, claudeRoot: URL, visibilityInterval: TimeInterval = 6 * 60 * 60) {
            self.codexRoot = codexRoot
            self.claudeRoot = claudeRoot
            self.visibilityInterval = visibilityInterval
        }

        func scan(at now: Date = Date()) -> [TranscriptSessionObservation] {
            (scanCodex(at: now) + scanClaude(at: now)).sorted { lhs, rhs in
                lhs.modifiedAt > rhs.modifiedAt
            }
        }

        private func scanCodex(at now: Date) -> [TranscriptSessionObservation] {
            guard let enumerator = FileManager.default.enumerator(
                at: codexRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var observations: [TranscriptSessionObservation] = []
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                guard let dates = dates(for: file), now.timeIntervalSince(dates.modified) <= visibilityInterval else {
                    continue
                }
                let metadata = codexMetadata(from: file)
                let externalID = metadata.id ?? file.deletingPathExtension().lastPathComponent
                let projectURL = metadata.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? file.deletingLastPathComponent()
                observations.append(TranscriptSessionObservation(
                    provider: .codex,
                    externalSessionID: externalID,
                    parentExternalSessionID: metadata.parentID,
                    projectURL: projectURL,
                    transcriptURL: file,
                    modifiedAt: dates.modified,
                    startedAt: dates.created
                ))
            }
            return observations
        }

        private func scanClaude(at now: Date) -> [TranscriptSessionObservation] {
            guard let projects = try? FileManager.default.contentsOfDirectory(
                at: claudeRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var observations: [TranscriptSessionObservation] = []
            for projectDirectory in projects {
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: projectDirectory,
                    includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for file in files where file.pathExtension == "jsonl" {
                    guard let dates = dates(for: file), now.timeIntervalSince(dates.modified) <= visibilityInterval else {
                        continue
                    }
                    let metadata = claudeMetadata(from: file)
                    let externalID = metadata.sessionID ?? file.deletingPathExtension().lastPathComponent
                    let projectURL = metadata.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
                        ?? projectDirectory
                    observations.append(TranscriptSessionObservation(
                        provider: .claude,
                        externalSessionID: externalID,
                        parentExternalSessionID: nil,
                        projectURL: projectURL,
                        transcriptURL: file,
                        modifiedAt: dates.modified,
                        startedAt: dates.created
                    ))
                    observations += scanClaudeSubagents(
                        parentFile: file,
                        parentExternalID: externalID,
                        projectURL: projectURL,
                        now: now
                    )
                }
            }
            return observations
        }

        private func scanClaudeSubagents(
            parentFile: URL,
            parentExternalID: String,
            projectURL: URL,
            now: Date
        ) -> [TranscriptSessionObservation] {
            let directory = parentFile.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return files.compactMap { file in
                guard file.pathExtension == "jsonl", let dates = dates(for: file),
                      now.timeIntervalSince(dates.modified) <= visibilityInterval
                else { return nil }
                let metadata = claudeMetadata(from: file)
                return TranscriptSessionObservation(
                    provider: .claude,
                    externalSessionID: metadata.sessionID ?? file.deletingPathExtension().lastPathComponent,
                    parentExternalSessionID: parentExternalID,
                    projectURL: metadata.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? projectURL,
                    transcriptURL: file,
                    modifiedAt: dates.modified,
                    startedAt: dates.created
                )
            }
        }

        private func dates(for file: URL) -> (modified: Date, created: Date)? {
            guard let values = try? file.resourceValues(forKeys: [
                .contentModificationDateKey, .creationDateKey, .isRegularFileKey
            ]), values.isRegularFile == true, let modified = values.contentModificationDate else { return nil }
            return (modified, values.creationDate ?? modified)
        }

        private func codexMetadata(from file: URL) -> (id: String?, cwd: String?, parentID: String?) {
            for object in metadataObjects(from: file) {
                guard let payload = object["payload"] as? [String: Any] else { continue }
                let id = payload["id"] as? String
                let cwd = payload["cwd"] as? String
                let parentID = payload["parent_thread_id"] as? String
                if id != nil || cwd != nil || parentID != nil {
                    return (id, cwd, parentID)
                }
            }
            return (nil, nil, nil)
        }

        private func claudeMetadata(from file: URL) -> (sessionID: String?, cwd: String?) {
            var sessionID: String?
            var cwd: String?
            for object in metadataObjects(from: file) {
                sessionID = sessionID ?? object["sessionId"] as? String ?? object["session_id"] as? String
                cwd = cwd ?? object["cwd"] as? String
                if sessionID != nil, cwd != nil { break }
            }
            return (sessionID, cwd)
        }

        private func metadataObjects(from file: URL) -> [[String: Any]] {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 262_144)) ?? Data()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").prefix(64).compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
        }
    }

    actor TranscriptSessionMonitor {
        private let runtime: HelperRuntime
        private let scanner: TranscriptSessionScanner
        private let pollingInterval: Duration
        private let runningInterval: TimeInterval
        private var task: Task<Void, Never>?
        private var lastStates: [SessionID: SessionState] = [:]

        init(
            runtime: HelperRuntime,
            scanner: TranscriptSessionScanner = TranscriptSessionScanner(),
            pollingInterval: Duration = .seconds(2),
            runningInterval: TimeInterval = 20
        ) {
            self.runtime = runtime
            self.scanner = scanner
            self.pollingInterval = pollingInterval
            self.runningInterval = runningInterval
        }

        func start() {
            guard task == nil else { return }
            task = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    await poll()
                    do {
                        try await Task.sleep(for: pollingInterval)
                    } catch {
                        return
                    }
                }
            }
        }

        func stop() {
            task?.cancel()
            task = nil
        }

        func poll(at now: Date = Date()) async {
            let observations = scanner.scan(at: now)
            let visibleIDs = Set(observations.map(\.sessionID))
            lastStates = lastStates.filter { visibleIDs.contains($0.key) }
            for observation in observations {
                let state: SessionState = now.timeIntervalSince(observation.modifiedAt) < runningInterval
                    ? .running
                    : .completed
                guard lastStates[observation.sessionID] != state else { continue }
                let wasCompleted = lastStates[observation.sessionID] == .completed
                let submission = Self.submission(
                    for: observation,
                    state: state,
                    resumesTerminalSession: wasCompleted && state == .running,
                    runningInterval: runningInterval,
                    receivedAt: now
                )
                _ = await runtime.handle(.submitEvent(submission))
                if wasCompleted, state == .running {
                    let runningSubmission = Self.submission(
                        for: observation,
                        state: .running,
                        resumesTerminalSession: false,
                        runningInterval: runningInterval,
                        receivedAt: now,
                        sequenceOffset: 1
                    )
                    _ = await runtime.handle(.submitEvent(runningSubmission))
                }
                lastStates[observation.sessionID] = state
            }
        }

        static func submission(
            for observation: TranscriptSessionObservation,
            state: SessionState,
            resumesTerminalSession: Bool,
            runningInterval: TimeInterval,
            receivedAt: Date,
            sequenceOffset: Int64 = 0
        ) -> HelperEventSubmission {
            let provider = observation.provider.rawValue
            let nodeID = NodeID(TranscriptStableIdentifier.uuid("node:\(ProcessInfo.processInfo.hostName)"))
            let projectPath = observation.projectURL.standardizedFileURL.path
            let occurredAt = state == .completed
                ? observation.modifiedAt.addingTimeInterval(runningInterval)
                : observation.modifiedAt
            let sequence = Int64(occurredAt.timeIntervalSince1970 * 1_000_000) + sequenceOffset
            let eventType = resumesTerminalSession ? "provider.resumed" : "session.stateChanged"
            let payload: JSONValue = resumesTerminalSession
                ? .object([:])
                : .object(["state": .string(state.rawValue)])
            let eventToken = "transcript:\(provider):\(observation.externalSessionID):\(eventType):\(sequence)"
            let source = EventSource(
                adapterID: AdapterID(provider),
                adapterVersion: "transcript-v1",
                nodeID: nodeID,
                // Keep transcript ordering independent from hook/app-server ordering.
                processID: -1
            )
            let session = AgentSession(
                id: observation.sessionID,
                nodeID: nodeID,
                adapterID: AdapterID(provider),
                externalSessionID: observation.externalSessionID,
                project: ProjectReference(
                    id: ProjectID(TranscriptStableIdentifier.uuid("project:\(projectPath)")),
                    name: observation.projectURL.lastPathComponent.isEmpty
                        ? "Terminal session"
                        : observation.projectURL.lastPathComponent,
                    rootURL: observation.projectURL
                ),
                terminalContext: nil,
                parentSessionID: observation.parentSessionID,
                state: .starting,
                startedAt: observation.startedAt,
                endedAt: nil,
                lastMeaningfulEventAt: observation.modifiedAt,
                snapshotRevision: 0
            )
            return HelperEventSubmission(
                envelope: EventEnvelope(
                    eventID: EventID(TranscriptStableIdentifier.uuid(eventToken)),
                    eventType: eventType,
                    source: source,
                    sessionID: observation.sessionID,
                    providerSessionID: observation.externalSessionID,
                    sequence: sequence,
                    occurredAt: occurredAt,
                    receivedAt: receivedAt,
                    payload: payload,
                    privacyClass: .privateMetadata,
                    correlationID: EnvelopeID(TranscriptStableIdentifier.uuid(
                        "correlation:\(provider):\(observation.externalSessionID)"
                    )),
                    schemaHash: "agentcontrol-transcript-v1-\(provider)"
                ),
                initialSession: session
            )
        }
    }

    private enum TranscriptStableIdentifier {
        static func uuid(_ value: String) -> UUID {
            var first: UInt64 = 14_695_981_039_346_656_037
            var second: UInt64 = 1_099_511_628_211
            for byte in value.utf8 {
                first = (first ^ UInt64(byte)) &* 1_099_511_628_211
                second = (second &* 1_099_511_628_211) ^ UInt64(byte)
            }
            var bytes = withUnsafeBytes(of: first.bigEndian, Array.init)
                + withUnsafeBytes(of: second.bigEndian, Array.init)
            bytes[6] = (bytes[6] & 0x0F) | 0x50
            bytes[8] = (bytes[8] & 0x3F) | 0x80
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
    }
#endif
