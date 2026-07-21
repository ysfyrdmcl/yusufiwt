#if os(macOS)
    import AgentDomain
    import CryptoKit
    import Foundation

    public enum IntegrationInstallState: String, Codable, Sendable {
        case notInstalled
        case healthy
        case repairNeeded
        case incompatible
    }

    public struct ManagedIntegrationReceipt: Codable, Sendable, Equatable {
        public let provider: HookProvider
        public let configURL: URL
        public let beforeHash: String
        public let afterHash: String
        public let managedBlockIDs: [String]
        public let backupURL: URL?
        public let changedAt: Date
    }

    public struct AgentIntegrationRecord: Sendable, Equatable, Identifiable {
        public var id: String {
            provider.rawValue
        }

        public let provider: HookProvider
        public let state: IntegrationInstallState
        public let detectedVersion: ProviderVersion?
        public let capabilities: CapabilityMatrix
        public let configURL: URL
        public let lastEventAt: Date?
        public let compatibilityWarning: String?
        public let unsupportedCapabilityReasons: [AgentCapability: String]

        public init(
            provider: HookProvider,
            state: IntegrationInstallState,
            detectedVersion: ProviderVersion?,
            capabilities: CapabilityMatrix,
            configURL: URL,
            lastEventAt: Date? = nil,
            compatibilityWarning: String? = nil,
            unsupportedCapabilityReasons: [AgentCapability: String] = [:]
        ) {
            self.provider = provider
            self.state = state
            self.detectedVersion = detectedVersion
            self.capabilities = capabilities
            self.configURL = configURL
            self.lastEventAt = lastEventAt
            self.compatibilityWarning = compatibilityWarning
            self.unsupportedCapabilityReasons = unsupportedCapabilityReasons
        }
    }

    public actor ManagedProviderIntegrationManager {
        private let fileManager: FileManager
        private let homeDirectory: URL
        private let hookExecutableURL: URL
        private let detector: ProviderBinaryDetector
        private let configManager: IntegrationManagerActor
        private let receiptURL: URL
        private var receipts: [HookProvider: ManagedIntegrationReceipt]

        public init(
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
            hookExecutableURL: URL,
            detector: ProviderBinaryDetector = ProviderBinaryDetector(),
            configManager: IntegrationManagerActor = IntegrationManagerActor(),
            receiptURL: URL? = nil
        ) {
            fileManager = .default
            self.homeDirectory = homeDirectory
            self.hookExecutableURL = hookExecutableURL
            self.detector = detector
            self.configManager = configManager
            self.receiptURL = receiptURL
                ?? homeDirectory.appendingPathComponent("Library/Application Support/AgentControl/integration-receipts.json")
            receipts = Self.loadReceipts(from: self.receiptURL)
        }

        public func scan() async -> [AgentIntegrationRecord] {
            var records: [AgentIntegrationRecord] = []
            for provider in [HookProvider.codex, .claude, .gemini, .cursor] {
                await records.append(record(provider))
            }
            return records
        }

        public func preview(provider: HookProvider, uninstall: Bool = false) async throws -> ManagedConfigPreview {
            let installation = try await installation(provider, requiresBinary: false)
            return try await configManager.preview(
                at: installation.configURL,
                format: installation.format,
                hooks: installation.hooks,
                uninstall: uninstall
            )
        }

        public func installAtomically(_ providers: [HookProvider]) async throws {
            var installations: [ProviderHookInstallation] = []
            for provider in providers {
                try await installations.append(installation(provider))
            }
            var previews: [ManagedConfigPreview] = []
            for installation in installations {
                try await previews.append(configManager.preview(
                    at: installation.configURL,
                    format: installation.format,
                    hooks: installation.hooks
                ))
            }
            let operations = installations.map {
                ManagedConfigOperation(url: $0.configURL, format: $0.format, hooks: $0.hooks)
            }
            let backups = try await configManager.installAtomically(operations)
            for (index, installation) in installations.enumerated() {
                let preview = previews[index]
                receipts[installation.provider] = ManagedIntegrationReceipt(
                    provider: installation.provider,
                    configURL: installation.configURL,
                    beforeHash: Self.hash(preview.original),
                    afterHash: Self.hash(preview.updated),
                    managedBlockIDs: installation.hooks.map(\.marker),
                    backupURL: backups[index],
                    changedAt: Date()
                )
            }
            try saveReceipts()
        }

        public func repair(_ provider: HookProvider) async throws {
            try await installAtomically([provider])
        }

        public func uninstall(_ provider: HookProvider) async throws {
            let installation = try await installation(provider, requiresBinary: false)
            _ = try await configManager.uninstall(
                at: installation.configURL,
                format: installation.format,
                hooks: installation.hooks
            )
            receipts.removeValue(forKey: provider)
            try saveReceipts()
        }

        public func restoreBackup(_ provider: HookProvider) async throws {
            guard let receipt = receipts[provider], let backup = receipt.backupURL else {
                throw ManagedConfigError.concurrentModification
            }
            let current = try String(contentsOf: receipt.configURL, encoding: .utf8)
            guard Self.hash(current) == receipt.afterHash else { throw ManagedConfigError.concurrentModification }
            try await configManager.restoreBackup(at: backup, to: receipt.configURL, expectedCurrent: current)
            receipts.removeValue(forKey: provider)
            try saveReceipts()
        }

        private func record(_ provider: HookProvider) async -> AgentIntegrationRecord {
            let detected = try? await detector.detect(provider: provider)
            guard let installation = try? ProviderHookInstallation.userLevel(
                provider: provider,
                hookExecutableURL: hookExecutableURL,
                providerVersion: detected?.version,
                homeDirectory: homeDirectory
            ) else {
                return AgentIntegrationRecord(
                    provider: provider,
                    state: .notInstalled,
                    detectedVersion: nil,
                    capabilities: CapabilityMatrix(supported: []),
                    configURL: homeDirectory
                )
            }
            let health = try? await configManager.health(
                at: installation.configURL,
                format: installation.format,
                hooks: installation.hooks
            )
            let known = detected?.capabilities.supported != [.monitorSessions]
            let state: IntegrationInstallState = switch health {
            case .healthy: known || detected == nil ? .healthy : .incompatible
            case .repairNeeded: .repairNeeded
            case .notInstalled, nil: .notInstalled
            }
            return AgentIntegrationRecord(
                provider: provider,
                state: state,
                detectedVersion: detected?.version,
                capabilities: detected?.capabilities ?? CapabilityMatrix(supported: [.monitorSessions]),
                configURL: installation.configURL,
                compatibilityWarning: known || detected == nil ? nil : "integrations.warning.unknownMajor",
                unsupportedCapabilityReasons: provider == .cursor ? [
                    .answerQuestions: "integrations.cursor.questionsUnavailable",
                    .reviewPlans: "integrations.cursor.plansUnavailable"
                ] : [:]
            )
        }

        private func installation(_ provider: HookProvider, requiresBinary: Bool = true) async throws -> ProviderHookInstallation {
            let binary = try? await detector.detect(provider: provider)
            if requiresBinary, binary == nil {
                throw ProviderIntegrationError.binaryNotFound(provider)
            }
            return try ProviderHookInstallation.userLevel(
                provider: provider,
                hookExecutableURL: hookExecutableURL,
                providerVersion: binary?.version,
                homeDirectory: homeDirectory
            )
        }

        private func saveReceipts() throws {
            try fileManager.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(receipts.values))
            try data.write(to: receiptURL, options: .atomic)
        }

        private static func loadReceipts(from url: URL) -> [HookProvider: ManagedIntegrationReceipt] {
            guard let data = try? Data(contentsOf: url),
                  let values = try? JSONDecoder().decode([ManagedIntegrationReceipt].self, from: data)
            else { return [:] }
            return Dictionary(uniqueKeysWithValues: values.map { ($0.provider, $0) })
        }

        private static func hash(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

#endif
