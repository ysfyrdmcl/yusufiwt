#if os(macOS)
    import Darwin
    import Foundation

    public struct SpoolImportReport: Sendable, Equatable {
        public let imported: Int
        public let failed: Int
        public let remaining: Int

        public init(imported: Int, failed: Int, remaining: Int) {
            self.imported = imported
            self.failed = failed
            self.remaining = remaining
        }
    }

    public actor HookSpool {
        private let directory: URL
        private let fileManager: FileManager
        private let maximumItemSize: Int

        public init(directory: URL, fileManager: FileManager = .default, maximumItemSize: Int = LocalIPCContract.maximumFrameSize) {
            self.directory = directory
            self.fileManager = fileManager
            self.maximumItemSize = maximumItemSize
        }

        public func prepare() throws {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard chmod(directory.path, S_IRWXU) == 0 else { throw LocalIPCError.socketFailure(code: errno) }
        }

        @discardableResult
        public func enqueue(_ data: Data, id: UUID = UUID()) throws -> URL {
            guard data.count <= maximumItemSize else { throw LocalIPCError.oversizedFrame(data.count) }
            try prepare()
            let finalURL = directory.appendingPathComponent("\(id.uuidString.lowercased()).event")
            let temporaryURL = directory.appendingPathComponent(".\(id.uuidString.lowercased()).tmp")
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            guard chmod(temporaryURL.path, S_IRUSR | S_IWUSR) == 0 else {
                try? fileManager.removeItem(at: temporaryURL)
                throw LocalIPCError.socketFailure(code: errno)
            }
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
            return finalURL
        }

        public func pendingCount() throws -> Int {
            try pendingURLs().count
        }

        public func importPending(
            limit: Int = 1000,
            handler: @Sendable (Data) async throws -> Void
        ) async throws -> SpoolImportReport {
            let candidates = try Array(pendingURLs().prefix(max(1, min(limit, 10000))))
            var imported = 0
            var failed = 0
            for sourceURL in candidates {
                let claimedURL = sourceURL.appendingPathExtension("processing")
                do {
                    try fileManager.moveItem(at: sourceURL, to: claimedURL)
                    let data = try Data(contentsOf: claimedURL, options: .mappedIfSafe)
                    guard data.count <= maximumItemSize else { throw LocalIPCError.oversizedFrame(data.count) }
                    try await handler(data)
                    try fileManager.removeItem(at: claimedURL)
                    imported += 1
                } catch {
                    failed += 1
                    if fileManager.fileExists(atPath: claimedURL.path), !fileManager.fileExists(atPath: sourceURL.path) {
                        try? fileManager.moveItem(at: claimedURL, to: sourceURL)
                    }
                }
            }
            return try SpoolImportReport(imported: imported, failed: failed, remaining: pendingCount())
        }

        private func pendingURLs() throws -> [URL] {
            guard fileManager.fileExists(atPath: directory.path) else { return [] }
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                guard url.pathExtension == "event",
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }
#endif
