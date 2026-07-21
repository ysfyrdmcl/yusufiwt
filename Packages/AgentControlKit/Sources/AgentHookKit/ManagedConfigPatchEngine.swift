// swiftlint:disable file_length
#if os(macOS)
    import Darwin
    import Foundation

    public enum ManagedConfigFormat: String, Codable, Sendable, CaseIterable {
        case json
        case jsonc
        case toml
    }

    public enum HookCommandLayout: String, Codable, Hashable, Sendable {
        case nested
        case direct
    }

    public enum ManagedConfigError: Error, Sendable, Equatable, CustomStringConvertible {
        case malformedConfiguration
        case unsupportedRoot
        case concurrentModification
        case unsafeSymbolicLink
        case ownerMismatch
        case readOnly
        case unsafeFileType
        case invalidManagedEntry
        case managedEntryConflict(String)

        public var description: String {
            switch self {
            case .malformedConfiguration: "The integration configuration is malformed."
            case .unsupportedRoot: "The integration configuration must have an object root."
            case .concurrentModification: "The configuration changed after the preview was created."
            case .unsafeSymbolicLink: "Refusing to modify a symbolic-link configuration path."
            case .ownerMismatch: "Refusing to modify a configuration owned by another user."
            case .readOnly: "The configuration is not writable."
            case .unsafeFileType: "The integration configuration must be a regular file."
            case .invalidManagedEntry: "The managed hook contains an unsafe or invalid value."
            case let .managedEntryConflict(marker): "The managed entry \(marker) conflicts with user changes."
            }
        }
    }

    public struct HookCommandDefinition: Codable, Hashable, Sendable {
        public let event: String
        public let matcher: String?
        public let command: String
        public let timeoutSeconds: Int
        public let marker: String
        public let usesNameField: Bool
        public let layout: HookCommandLayout
        public let failClosed: Bool

        public init(
            event: String,
            matcher: String? = nil,
            command: String,
            timeoutSeconds: Int,
            marker: String,
            usesNameField: Bool = false,
            layout: HookCommandLayout = .nested,
            failClosed: Bool = false
        ) {
            self.event = event
            self.matcher = matcher
            self.command = command
            self.timeoutSeconds = timeoutSeconds
            self.marker = marker
            self.usesNameField = usesNameField
            self.layout = layout
            self.failClosed = failClosed
        }
    }

    public struct ManagedConfigPreview: Sendable, Equatable {
        public let original: String
        public let updated: String
        public let diff: String

        public init(original: String, updated: String) {
            self.original = original
            self.updated = updated
            diff = Self.makeDiff(original: original, updated: updated)
        }

        public var hasChanges: Bool {
            original != updated
        }

        private static func makeDiff(original: String, updated: String) -> String {
            guard original != updated else { return "" }
            return "--- current\n+++ proposed\n-\(original)\n+\(updated)"
        }
    }

    public struct ManagedConfigOperation: Sendable {
        public let url: URL
        public let format: ManagedConfigFormat
        public let hooks: [HookCommandDefinition]

        public init(url: URL, format: ManagedConfigFormat, hooks: [HookCommandDefinition]) {
            self.url = url
            self.format = format
            self.hooks = hooks
        }
    }

    /// A lossless patcher for provider hook files. JSON/JSONC edits are inserted into
    /// the existing syntax tree as text, so comments, ordering, and unrelated fields stay byte-for-byte intact.
    public struct ManagedConfigPatchEngine: Sendable {
        public init() {}

        public func previewInstall(
            content: String,
            format: ManagedConfigFormat,
            hooks: [HookCommandDefinition]
        ) throws -> ManagedConfigPreview {
            try hooks.forEach(validateHook)
            let original = content.isEmpty ? emptyDocument(for: format) : content
            var updated = original
            switch format {
            case .json, .jsonc:
                try validateJSONLike(original, allowsComments: format == .jsonc)
                for hook in hooks {
                    updated = try JSONTextPatcher.upsert(hook, in: updated)
                }
                try validateJSONLike(updated, allowsComments: format == .jsonc)
            case .toml:
                for hook in hooks where !updated.contains(hook.marker) {
                    updated = appendTOML(hook, to: updated)
                }
            }
            return ManagedConfigPreview(original: original, updated: updated)
        }

        public func previewUninstall(
            content: String,
            format: ManagedConfigFormat,
            hooks: [HookCommandDefinition]
        ) throws -> ManagedConfigPreview {
            try hooks.forEach(validateHook)
            guard !content.isEmpty else { return ManagedConfigPreview(original: "", updated: "") }
            var updated = content
            switch format {
            case .json, .jsonc:
                for hook in hooks {
                    updated = try JSONTextPatcher.remove(marker: hook.marker, event: hook.event, from: updated)
                }
                try validateJSONLike(updated, allowsComments: format == .jsonc)
            case .toml:
                for hook in hooks {
                    updated = removeTOML(marker: hook.marker, from: updated)
                }
            }
            return ManagedConfigPreview(original: content, updated: updated)
        }

        private func emptyDocument(for format: ManagedConfigFormat) -> String {
            switch format {
            case .json, .jsonc: "{}\n"
            case .toml: ""
            }
        }

        private func validateJSONLike(_ content: String, allowsComments: Bool) throws {
            let normalized = allowsComments ? JSONCommentStripper.strip(content) : content
            let data = Data((allowsComments ? JSONCommentStripper.removeTrailingCommas(normalized) : normalized).utf8)
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                guard object is [String: Any] else { throw ManagedConfigError.unsupportedRoot }
            } catch let error as ManagedConfigError {
                throw error
            } catch {
                throw ManagedConfigError.malformedConfiguration
            }
        }

        private func appendTOML(_ hook: HookCommandDefinition, to content: String) -> String {
            var block = "# agentcontrol:begin \(hook.marker)\n[[hooks.\(hook.event)]]\n"
            if let matcher = hook.matcher {
                block += "matcher = \(tomlString(matcher))\n"
            }
            block += "[[hooks.\(hook.event).hooks]]\n"
            block += "type = \"command\"\ncommand = \(tomlString(hook.command))\n"
            block += "timeout = \(hook.timeoutSeconds)\nstatusMessage = \"yusufiwt [\(hook.marker)]\"\n"
            block += "# agentcontrol:end \(hook.marker)\n"
            let separator = content.isEmpty || content.hasSuffix("\n") ? "" : "\n"
            return content + separator + block
        }

        private func tomlString(_ value: String) -> String {
            let data = try? JSONEncoder().encode(value)
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }

        private func validateHook(_ hook: HookCommandDefinition) throws {
            let safeIdentifier = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            guard !hook.event.isEmpty,
                  hook.event.unicodeScalars.allSatisfy(safeIdentifier.contains),
                  !hook.marker.isEmpty,
                  hook.marker.unicodeScalars.allSatisfy(safeIdentifier.contains),
                  (1 ... 120_000).contains(hook.timeoutSeconds),
                  !hook.command.isEmpty,
                  hook.command.utf8.count <= 4096,
                  !hook.command.contains("\0"),
                  (hook.matcher?.utf8.count ?? 0) <= 512,
                  hook.matcher?.contains("\0") != true
            else { throw ManagedConfigError.invalidManagedEntry }
        }

        private func removeTOML(marker: String, from content: String) -> String {
            let begin = "# agentcontrol:begin \(marker)"
            let end = "# agentcontrol:end \(marker)"
            guard let start = content.range(of: begin),
                  let endStart = content.range(of: end, range: start.upperBound ..< content.endIndex)
            else { return content }
            var upper = endStart.upperBound
            if upper < content.endIndex, content[upper] == "\n" {
                upper = content.index(after: upper)
            }
            var result = content
            result.removeSubrange(start.lowerBound ..< upper)
            return result
        }
    }

    public actor IntegrationManagerActor {
        private let patcher: ManagedConfigPatchEngine
        private let fileManager: FileManager

        public init(patcher: ManagedConfigPatchEngine = ManagedConfigPatchEngine()) {
            self.patcher = patcher
            fileManager = .default
        }

        public func preview(
            at url: URL,
            format: ManagedConfigFormat,
            hooks: [HookCommandDefinition],
            uninstall: Bool = false
        ) throws -> ManagedConfigPreview {
            try validatePath(url, requireWritable: false)
            let content = try read(url)
            return try uninstall
                ? patcher.previewUninstall(content: content, format: format, hooks: hooks)
                : patcher.previewInstall(content: content, format: format, hooks: hooks)
        }

        public enum Health: String, Codable, Sendable {
            case notInstalled
            case healthy
            case repairNeeded
        }

        public func health(
            at url: URL,
            format: ManagedConfigFormat,
            hooks: [HookCommandDefinition]
        ) throws -> Health {
            guard fileManager.fileExists(atPath: url.path) else { return .notInstalled }
            let result = try preview(at: url, format: format, hooks: hooks)
            return result.hasChanges ? .repairNeeded : .healthy
        }

        @discardableResult
        public func install(
            at url: URL,
            format: ManagedConfigFormat,
            hooks: [HookCommandDefinition]
        ) throws -> URL? {
            try apply(preview(at: url, format: format, hooks: hooks), at: url)
        }

        @discardableResult
        public func repair(
            at url: URL,
            format: ManagedConfigFormat,
            hooks: [HookCommandDefinition]
        ) throws -> URL? {
            try install(at: url, format: format, hooks: hooks)
        }

        @discardableResult
        public func uninstall(
            at url: URL,
            format: ManagedConfigFormat,
            hooks: [HookCommandDefinition]
        ) throws -> URL? {
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try apply(preview(at: url, format: format, hooks: hooks, uninstall: true), at: url)
        }

        /// Validates every preview before writing and rolls back earlier writes if a
        /// later operation fails or the onboarding task is cancelled.
        public func installAtomically(_ operations: [ManagedConfigOperation]) throws -> [URL?] {
            struct Prepared {
                let operation: ManagedConfigOperation
                let preview: ManagedConfigPreview
                let existed: Bool
            }
            let prepared = try operations.map { operation in
                try Prepared(
                    operation: operation,
                    preview: preview(
                        at: operation.url,
                        format: operation.format,
                        hooks: operation.hooks
                    ),
                    existed: fileManager.fileExists(atPath: operation.url.path)
                )
            }
            var applied: [Prepared] = []
            var backups: [URL?] = []
            do {
                for item in prepared {
                    try Task.checkCancellation()
                    try backups.append(apply(item.preview, at: item.operation.url))
                    if item.preview.hasChanges {
                        applied.append(item)
                    }
                }
                return backups
            } catch {
                for item in applied.reversed() {
                    try? rollback(item.preview, at: item.operation.url, existed: item.existed)
                }
                throw error
            }
        }

        public func latestBackup(for url: URL) throws -> URL? {
            let directory = url.deletingLastPathComponent()
            guard fileManager.fileExists(atPath: directory.path) else { return nil }
            let prefix = url.lastPathComponent + ".agentcontrol-backup-"
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ).filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted {
                let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }.first
        }

        public func restoreBackup(at backupURL: URL, to url: URL, expectedCurrent: String) throws {
            try validatePath(url, requireWritable: true)
            let current = try read(url)
            guard current == expectedCurrent else { throw ManagedConfigError.concurrentModification }
            let backup = try String(contentsOf: backupURL, encoding: .utf8)
            _ = try apply(ManagedConfigPreview(original: current, updated: backup), at: url)
        }

        @discardableResult
        public func apply(
            _ preview: ManagedConfigPreview,
            at url: URL,
            backupLimit: Int = 3
        ) throws -> URL? {
            try validatePath(url, requireWritable: true)
            let current = try read(url)
            guard current == preview.original || (!fileManager.fileExists(atPath: url.path) && preview.original == "{}\n") else {
                throw ManagedConfigError.concurrentModification
            }
            guard preview.hasChanges else { return nil }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let backup = try createBackupIfNeeded(url, limit: max(1, backupLimit))
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).agentcontrol-\(UUID().uuidString).tmp")
            guard fileManager.createFile(atPath: temporary.path, contents: Data(preview.updated.utf8)) else {
                throw ManagedConfigError.readOnly
            }
            defer { try? fileManager.removeItem(at: temporary) }
            if let permissions = attributes?[.posixPermissions] {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            // Close the preview/write race before the atomic replacement. A path
            // swapped to a symlink after preview must still fail closed.
            try validatePath(url, requireWritable: true)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
            let directoryDescriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
            if directoryDescriptor >= 0 {
                _ = fsync(directoryDescriptor)
                _ = close(directoryDescriptor)
            }
            return backup
        }

        private func read(_ url: URL) throws -> String {
            guard fileManager.fileExists(atPath: url.path) else { return "" }
            return try String(contentsOf: url, encoding: .utf8)
        }

        private func rollback(_ preview: ManagedConfigPreview, at url: URL, existed: Bool) throws {
            let current = try read(url)
            guard current == preview.updated else { throw ManagedConfigError.concurrentModification }
            if existed {
                _ = try apply(ManagedConfigPreview(original: current, updated: preview.original), at: url)
            } else if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }

        private func validatePath(_ url: URL, requireWritable: Bool) throws {
            let standardized = url.standardizedFileURL
            try validateExistingComponents(of: standardized)
            guard fileManager.fileExists(atPath: standardized.path) else { return }
            var info = stat()
            guard lstat(standardized.path, &info) == 0 else { throw ManagedConfigError.readOnly }
            guard (info.st_mode & S_IFMT) != S_IFLNK else { throw ManagedConfigError.unsafeSymbolicLink }
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw ManagedConfigError.unsafeFileType }
            guard info.st_uid == getuid() else { throw ManagedConfigError.ownerMismatch }
            if requireWritable, !fileManager.isWritableFile(atPath: standardized.path) {
                throw ManagedConfigError.readOnly
            }
        }

        private func validateExistingComponents(of url: URL) throws {
            var component = URL(fileURLWithPath: "/", isDirectory: true)
            for name in url.pathComponents.dropFirst() {
                component.appendPathComponent(name)
                var componentInfo = stat()
                if lstat(component.path, &componentInfo) != 0 {
                    guard errno == ENOENT else { throw ManagedConfigError.readOnly }
                    break
                }
                if (componentInfo.st_mode & S_IFMT) == S_IFLNK {
                    // macOS exposes trusted temporary paths through root-owned
                    // compatibility links such as /var. Reject every
                    // user-controlled link in the configuration path.
                    guard componentInfo.st_uid == 0 else {
                        throw ManagedConfigError.unsafeSymbolicLink
                    }
                }
            }
        }

        private func createBackupIfNeeded(_ url: URL, limit: Int) throws -> URL? {
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).agentcontrol-backup-\(UUID().uuidString)")
            try fileManager.copyItem(at: url, to: backup)
            let prefix = url.lastPathComponent + ".agentcontrol-backup-"
            let backups = try fileManager.contentsOfDirectory(
                at: url.deletingLastPathComponent(),
                includingPropertiesForKeys: [.contentModificationDateKey]
            ).filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted {
                let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
            for stale in backups.dropFirst(limit) {
                try fileManager.removeItem(at: stale)
            }
            return backup
        }
    }

    private enum JSONTextPatcher {
        static func upsert(_ hook: HookCommandDefinition, in content: String) throws -> String {
            var bytes = Array(content.utf8)
            guard let root = JSONScanner.rootObject(in: bytes) else { throw ManagedConfigError.unsupportedRoot }
            let group = makeGroup(hook)
            if containsExactMarker(hook.marker, in: content) {
                guard let hooks = JSONScanner.property("hooks", inObject: root, bytes: bytes),
                      bytes[hooks.lowerBound] == ascii("{"),
                      let eventArray = JSONScanner.property(
                          hook.event,
                          inObject: hooks.lowerBound ..< hooks.upperBound,
                          bytes: bytes
                      ),
                      bytes[eventArray.lowerBound] == ascii("["),
                      let ownedEntry = JSONScanner.arrayElements(in: eventArray, bytes: bytes).first(where: {
                          containsExactMarker(
                              hook.marker,
                              in: String(bytes: bytes[$0], encoding: .utf8) ?? ""
                          )
                      })
                else { throw ManagedConfigError.managedEntryConflict(hook.marker) }
                guard String(bytes: bytes[ownedEntry], encoding: .utf8) != group else { return content }
                bytes.replaceSubrange(ownedEntry, with: group.utf8)
                return String(bytes: bytes, encoding: .utf8) ?? ""
            }
            if let hooksValue = JSONScanner.property("hooks", inObject: root, bytes: bytes) {
                guard bytes[hooksValue.lowerBound] == ascii("{") else { throw ManagedConfigError.managedEntryConflict("hooks") }
                let hooksObject = hooksValue.lowerBound ..< hooksValue.upperBound
                if let eventValue = JSONScanner.property(hook.event, inObject: hooksObject, bytes: bytes) {
                    guard bytes[eventValue.lowerBound] == ascii("[") else { throw ManagedConfigError.managedEntryConflict(hook.event) }
                    bytes = insertArrayValue(group, into: eventValue, bytes: bytes)
                } else {
                    bytes = insertObjectProperty(key: hook.event, value: "[\n      \(group)\n    ]", into: hooksObject, bytes: bytes, indent: 4)
                }
            } else {
                let value = "{\n    \"\(escape(hook.event))\": [\n      \(group)\n    ]\n  }"
                bytes = insertObjectProperty(key: "hooks", value: value, into: root, bytes: bytes, indent: 2)
            }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }

        static func remove(marker: String, event: String, from content: String) throws -> String {
            var bytes = Array(content.utf8)
            guard let root = JSONScanner.rootObject(in: bytes),
                  let hooks = JSONScanner.property("hooks", inObject: root, bytes: bytes),
                  bytes[hooks.lowerBound] == ascii("{"),
                  let eventArray = JSONScanner.property(event, inObject: hooks.lowerBound ..< hooks.upperBound, bytes: bytes),
                  bytes[eventArray.lowerBound] == ascii("[")
            else { return content }
            guard let element = JSONScanner.arrayElements(in: eventArray, bytes: bytes).first(where: {
                containsExactMarker(marker, in: String(bytes: bytes[$0], encoding: .utf8) ?? "")
            }) else { return content }

            let elements = JSONScanner.arrayElements(in: eventArray, bytes: bytes)
            guard let index = elements.firstIndex(of: element) else { return content }
            var removal = element
            if index > 0 {
                var cursor = element.lowerBound - 1
                while cursor > elements[index - 1].upperBound, JSONScanner.isTrivia(bytes[cursor]) {
                    cursor -= 1
                }
                if bytes[cursor] == ascii(",") {
                    removal = cursor ..< element.upperBound
                }
            } else if elements.count > 1 {
                var cursor = element.upperBound
                while cursor < elements[1].lowerBound, JSONScanner.isTrivia(bytes[cursor]) {
                    cursor += 1
                }
                if cursor < bytes.count, bytes[cursor] == ascii(",") {
                    removal = element.lowerBound ..< (cursor + 1)
                }
            }
            bytes.removeSubrange(removal)
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }

        private static func makeGroup(_ hook: HookCommandDefinition) -> String {
            if hook.layout == .direct {
                let markedCommand = "AGENTCONTROL_MANAGED_MARKER="
                    + shellQuoted(hook.marker) + " " + hook.command
                var group = "{"
                if let matcher = hook.matcher {
                    group += "\"matcher\":\"\(escape(matcher))\","
                }
                group += "\"command\":\"\(escape(markedCommand))\",\"timeout\":\(hook.timeoutSeconds)"
                if hook.failClosed {
                    group += ",\"failClosed\":true"
                }
                return group + "}"
            }
            var group = "{"
            if let matcher = hook.matcher {
                group += "\"matcher\":\"\(escape(matcher))\","
            }
            group += "\"hooks\":[{\"type\":\"command\",\"command\":\"\(escape(hook.command))\",\"timeout\":\(hook.timeoutSeconds),"
            if hook.usesNameField {
                group += "\"name\":\"\(escape(hook.marker))\""
            } else {
                group += "\"statusMessage\":\"yusufiwt [\(escape(hook.marker))]\""
            }
            return group + "}]}"
        }

        private static func shellQuoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        private static func insertArrayValue(_ value: String, into array: Range<Int>, bytes: [UInt8]) -> [UInt8] {
            let close = array.upperBound - 1
            let hasValues = !JSONScanner.onlyTrivia(bytes[(array.lowerBound + 1) ..< close])
            let insertion = (hasValues ? "," : "") + "\n      " + value + "\n    "
            var result = bytes
            result.insert(contentsOf: insertion.utf8, at: close)
            return result
        }

        private static func insertObjectProperty(key: String, value: String, into object: Range<Int>, bytes: [UInt8], indent: Int) -> [UInt8] {
            let close = object.upperBound - 1
            let hasValues = !JSONScanner.onlyTrivia(bytes[(object.lowerBound + 1) ..< close])
            let padding = String(repeating: " ", count: indent)
            let insertion = (hasValues ? "," : "") + "\n\(padding)\"\(escape(key))\": \(value)\n" + String(repeating: " ", count: max(0, indent - 2))
            var result = bytes
            result.insert(contentsOf: insertion.utf8, at: close)
            return result
        }

        private static func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }

        /// Marker names share prefixes (for example `beforetool` and
        /// `beforetoolselection`). Only a complete marker token identifies an
        /// AgentControl-owned entry.
        private static func containsExactMarker(_ marker: String, in content: String) -> Bool {
            var searchRange = content.startIndex ..< content.endIndex
            while let range = content.range(of: marker, range: searchRange) {
                let hasIdentifierBefore = range.lowerBound > content.startIndex
                    && isMarkerCharacter(content[content.index(before: range.lowerBound)])
                let hasIdentifierAfter = range.upperBound < content.endIndex
                    && isMarkerCharacter(content[range.upperBound])
                if !hasIdentifierBefore, !hasIdentifierAfter {
                    return true
                }
                searchRange = range.upperBound ..< content.endIndex
            }
            return false
        }

        private static func isMarkerCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
        }
    }

    private enum JSONScanner {
        static func rootObject(in bytes: [UInt8]) -> Range<Int>? {
            let start = skipTrivia(from: 0, limit: bytes.count, bytes: bytes)
            guard start < bytes.count, bytes[start] == ascii("{") else { return nil }
            return valueRange(at: start, bytes: bytes)
        }

        static func property(_ name: String, inObject object: Range<Int>, bytes: [UInt8]) -> Range<Int>? {
            var cursor = object.lowerBound + 1
            let limit = object.upperBound - 1
            while cursor < limit {
                cursor = skipTrivia(from: cursor, limit: limit, bytes: bytes)
                if cursor < limit, bytes[cursor] == ascii(",") {
                    cursor += 1; continue
                }
                guard cursor < limit, bytes[cursor] == ascii("\"") else { return nil }
                guard let keyRange = stringRange(at: cursor, bytes: bytes) else { return nil }
                let keyBytes = bytes[(keyRange.lowerBound + 1) ..< (keyRange.upperBound - 1)]
                let key = String(bytes: keyBytes, encoding: .utf8) ?? ""
                cursor = skipTrivia(from: keyRange.upperBound, limit: limit, bytes: bytes)
                guard cursor < limit, bytes[cursor] == ascii(":") else { return nil }
                cursor = skipTrivia(from: cursor + 1, limit: limit, bytes: bytes)
                guard let value = valueRange(at: cursor, bytes: bytes) else { return nil }
                if key == name {
                    return value
                }
                cursor = value.upperBound
            }
            return nil
        }

        static func arrayElements(in array: Range<Int>, bytes: [UInt8]) -> [Range<Int>] {
            var result: [Range<Int>] = []
            var cursor = array.lowerBound + 1
            let limit = array.upperBound - 1
            while cursor < limit {
                cursor = skipTrivia(from: cursor, limit: limit, bytes: bytes)
                if cursor < limit, bytes[cursor] == ascii(",") {
                    cursor += 1; continue
                }
                guard cursor < limit, let value = valueRange(at: cursor, bytes: bytes) else { break }
                result.append(value)
                cursor = value.upperBound
            }
            return result
        }

        // swiftlint:disable:next cyclomatic_complexity
        static func valueRange(at start: Int, bytes: [UInt8]) -> Range<Int>? {
            guard start < bytes.count else { return nil }
            if bytes[start] == ascii("\"") {
                return stringRange(at: start, bytes: bytes)
            }
            if bytes[start] == ascii("{") || bytes[start] == ascii("[") {
                let open = bytes[start]
                let close = open == ascii("{") ? ascii("}") : ascii("]")
                var depth = 0
                var cursor = start
                while cursor < bytes.count {
                    if bytes[cursor] == ascii("\"") {
                        guard let string = stringRange(at: cursor, bytes: bytes) else { return nil }
                        cursor = string.upperBound
                        continue
                    }
                    if isCommentStart(cursor, bytes: bytes) {
                        cursor = skipComment(from: cursor, limit: bytes.count, bytes: bytes)
                        continue
                    }
                    if bytes[cursor] == open {
                        depth += 1
                    }
                    if bytes[cursor] == close {
                        depth -= 1
                        if depth == 0 {
                            return start ..< (cursor + 1)
                        }
                    }
                    cursor += 1
                }
                return nil
            }
            var cursor = start
            while cursor < bytes.count, ![ascii(","), ascii("}"), ascii("]")].contains(bytes[cursor]) {
                cursor += 1
            }
            var end = cursor
            while end > start, isTrivia(bytes[end - 1]) {
                end -= 1
            }
            return start ..< end
        }

        static func onlyTrivia(_ bytes: ArraySlice<UInt8>) -> Bool {
            var cursor = bytes.startIndex
            while cursor < bytes.endIndex {
                if isTrivia(bytes[cursor]) {
                    cursor += 1; continue
                }
                if cursor + 1 < bytes.endIndex, bytes[cursor] == ascii("/"), [ascii("/"), ascii("*")].contains(bytes[cursor + 1]) {
                    // A comment without a value still counts as trivia.
                    if bytes[cursor + 1] == ascii("/") {
                        cursor += 2
                        while cursor < bytes.endIndex, bytes[cursor] != 10 {
                            cursor += 1
                        }
                    } else {
                        cursor += 2
                        while cursor + 1 < bytes.endIndex, !(bytes[cursor] == ascii("*") && bytes[cursor + 1] == ascii("/")) {
                            cursor += 1
                        }
                        cursor = min(bytes.endIndex, cursor + 2)
                    }
                    continue
                }
                return false
            }
            return true
        }

        static func isTrivia(_ byte: UInt8) -> Bool {
            byte == 9 || byte == 10 || byte == 13 || byte == 32
        }

        private static func stringRange(at start: Int, bytes: [UInt8]) -> Range<Int>? {
            var cursor = start + 1
            while cursor < bytes.count {
                if bytes[cursor] == ascii("\\") {
                    cursor += 2; continue
                }
                if bytes[cursor] == ascii("\"") {
                    return start ..< (cursor + 1)
                }
                cursor += 1
            }
            return nil
        }

        private static func skipTrivia(from start: Int, limit: Int, bytes: [UInt8]) -> Int {
            var cursor = start
            while cursor < limit {
                if isTrivia(bytes[cursor]) {
                    cursor += 1; continue
                }
                if isCommentStart(cursor, bytes: bytes) {
                    cursor = skipComment(from: cursor, limit: limit, bytes: bytes)
                    continue
                }
                break
            }
            return cursor
        }

        private static func isCommentStart(_ index: Int, bytes: [UInt8]) -> Bool {
            index + 1 < bytes.count && bytes[index] == ascii("/") && [ascii("/"), ascii("*")].contains(bytes[index + 1])
        }

        private static func skipComment(from start: Int, limit: Int, bytes: [UInt8]) -> Int {
            if bytes[start + 1] == ascii("/") {
                var cursor = start + 2
                while cursor < limit, bytes[cursor] != 10 {
                    cursor += 1
                }
                return cursor
            }
            var cursor = start + 2
            while cursor + 1 < limit {
                if bytes[cursor] == ascii("*"), bytes[cursor + 1] == ascii("/") {
                    return cursor + 2
                }
                cursor += 1
            }
            return limit
        }
    }

    private enum JSONCommentStripper {
        static func strip(_ content: String) -> String {
            let bytes = Array(content.utf8)
            var output: [UInt8] = []
            var cursor = 0
            var inString = false
            while cursor < bytes.count {
                if inString {
                    output.append(bytes[cursor])
                    if bytes[cursor] == ascii("\\"), cursor + 1 < bytes.count {
                        cursor += 1; output.append(bytes[cursor])
                    } else if bytes[cursor] == ascii("\"") {
                        inString = false
                    }
                    cursor += 1
                    continue
                }
                if bytes[cursor] == ascii("\"") {
                    inString = true; output.append(bytes[cursor]); cursor += 1; continue
                }
                if cursor + 1 < bytes.count, bytes[cursor] == ascii("/"), bytes[cursor + 1] == ascii("/") {
                    while cursor < bytes.count, bytes[cursor] != 10 {
                        cursor += 1
                    }
                    continue
                }
                if cursor + 1 < bytes.count, bytes[cursor] == ascii("/"), bytes[cursor + 1] == ascii("*") {
                    cursor += 2
                    while cursor + 1 < bytes.count, !(bytes[cursor] == ascii("*") && bytes[cursor + 1] == ascii("/")) {
                        cursor += 1
                    }
                    cursor = min(bytes.count, cursor + 2)
                    continue
                }
                output.append(bytes[cursor]); cursor += 1
            }
            return String(bytes: output, encoding: .utf8) ?? ""
        }

        static func removeTrailingCommas(_ content: String) -> String {
            var bytes = Array(content.utf8)
            var cursor = 0
            var inString = false
            while cursor < bytes.count {
                if bytes[cursor] == ascii("\\"), inString {
                    cursor += 2; continue
                }
                if bytes[cursor] == ascii("\"") {
                    inString.toggle(); cursor += 1; continue
                }
                if !inString, bytes[cursor] == ascii(",") {
                    var lookahead = cursor + 1
                    while lookahead < bytes.count, JSONScanner.isTrivia(bytes[lookahead]) {
                        lookahead += 1
                    }
                    if lookahead < bytes.count, [ascii("}"), ascii("]")].contains(bytes[lookahead]) {
                        bytes[cursor] = ascii(" ")
                    }
                }
                cursor += 1
            }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
    }

    private func ascii(_ character: Character) -> UInt8 {
        character.asciiValue ?? 0
    }
#endif
