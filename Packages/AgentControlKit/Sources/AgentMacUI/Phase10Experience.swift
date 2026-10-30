#if os(macOS)
    import AgentDomain
    import AgentHookKit
    import AgentLocalIPC
    import AgentPersistence
    import AgentProtocol
    import AppKit
    import Foundation
    import Observation

    public enum AgentControlWorkingMode: String, CaseIterable, Sendable {
        case localOnly
        case personalRemote
        case selfHostedRemote
    }

    public enum OnboardingStep: String, CaseIterable, Sendable {
        case welcome
        case mode
        case coreServices
        case discovery
        case review
        case navigation
        case verification
    }

    public enum Phase10Message: Sendable, Equatable {
        case localized(String)
        case verbatim(String)
    }

    @MainActor
    @Observable
    // The coordinator intentionally owns the full ordered onboarding transaction.
    // swiftlint:disable:next type_body_length
    public final class Phase10Coordinator {
        public var isOnboardingPresented: Bool
        public var onboardingStep: OnboardingStep
        public var workingMode: AgentControlWorkingMode
        public var selectedProviders: Set<HookProvider> = []
        public private(set) var integrations: [AgentIntegrationRecord] = []
        public private(set) var detectedTerminals: [TerminalApplication] = []
        public private(set) var previews: [HookProvider: ManagedConfigPreview] = [:]
        public private(set) var busy = false
        public private(set) var message: Phase10Message?
        public private(set) var helperState: LaunchAgentState = .notRegistered
        public private(set) var notificationState: NotificationAuthorizationState = .unknown
        public private(set) var accessibilityEnabled = false
        public private(set) var testEventSucceeded = false

        public var isCompleted: Bool {
            defaults.bool(forKey: Keys.completed)
        }

        private let defaults: UserDefaults
        private let integrationManager: ManagedProviderIntegrationManager
        private let notificationCoordinator: MacNotificationCoordinator?
        private let navigationPreferences: NavigationPreferences

        public init(
            defaults: UserDefaults = .standard,
            integrationManager: ManagedProviderIntegrationManager? = nil,
            notificationCoordinator: MacNotificationCoordinator? = nil,
            navigationPreferences: NavigationPreferences? = nil
        ) {
            self.defaults = defaults
            self.notificationCoordinator = notificationCoordinator
            let preferences = navigationPreferences ?? NavigationPreferences(defaults: defaults)
            self.navigationPreferences = preferences
            accessibilityEnabled = preferences.accessibilityNavigationEnabled
            workingMode = AgentControlWorkingMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .localOnly
            onboardingStep = OnboardingStep(rawValue: defaults.string(forKey: Keys.step) ?? "") ?? .welcome
            isOnboardingPresented = !defaults.bool(forKey: Keys.completed)
            let hookURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agentcontrol-hook")
            self.integrationManager = integrationManager ?? ManagedProviderIntegrationManager(hookExecutableURL: hookURL)
        }

        public func setStep(_ step: OnboardingStep) {
            onboardingStep = step
            defaults.set(step.rawValue, forKey: Keys.step)
        }

        public func setMode(_ mode: AgentControlWorkingMode) {
            _ = mode
            workingMode = .localOnly
            defaults.set(AgentControlWorkingMode.localOnly.rawValue, forKey: Keys.mode)
        }

        public func configureCoreServices() async {
            await perform {
                let paths = try AgentControlPaths.userDefault()
                let manager = LaunchAgentManager(paths: paths)
                if await manager.status() != .enabled {
                    self.helperState = try await manager.register()
                } else {
                    self.helperState = .enabled
                }
                await self.notificationCoordinator?.configure()
                self.notificationState = self.notificationCoordinator?.authorizationState ?? .unknown
                self.setStep(.discovery)
            }
        }

        public func discover() async {
            await perform {
                self.integrations = await self.integrationManager.scan()
                self.selectedProviders = Set(self.integrations.filter {
                    $0.detectedVersion != nil && $0.state != .healthy
                }.map(\.provider))
                self.detectedTerminals = TerminalApplication.allCases.filter { application in
                    application != .unknown && application.bundleIdentifiers.contains {
                        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
                    }
                }
                self.setStep(.review)
            }
        }

        public func refreshIntegrations() async {
            await perform {
                self.integrations = await self.integrationManager.scan()
                self.detectedTerminals = TerminalApplication.allCases.filter { application in
                    application != .unknown && application.bundleIdentifiers.contains {
                        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
                    }
                }
            }
        }

        public func preparePreviews() async {
            await perform {
                var values: [HookProvider: ManagedConfigPreview] = [:]
                for provider in self.selectedProviders {
                    values[provider] = try await self.integrationManager.preview(provider: provider)
                }
                self.previews = values
            }
        }

        public func installSelected() async {
            await perform {
                try await self.integrationManager.installAtomically(Array(self.selectedProviders))
                self.integrations = await self.integrationManager.scan()
                self.setStep(.navigation)
            }
        }

        public func repair(_ provider: HookProvider) async {
            await perform {
                try await self.integrationManager.repair(provider)
                self.integrations = await self.integrationManager.scan()
            }
        }

        public func uninstall(_ provider: HookProvider) async {
            await perform {
                try await self.integrationManager.uninstall(provider)
                self.integrations = await self.integrationManager.scan()
            }
        }

        public func restoreBackup(_ provider: HookProvider) async {
            await perform {
                try await self.integrationManager.restoreBackup(provider)
                self.integrations = await self.integrationManager.scan()
            }
        }

        public func preview(_ provider: HookProvider, uninstall: Bool = false) async {
            await perform {
                self.previews[provider] = try await self.integrationManager.preview(provider: provider, uninstall: uninstall)
            }
        }

        public func enableAccessibilityNavigation() {
            navigationPreferences.setAccessibilityNavigationEnabled(true)
            accessibilityEnabled = true
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        public func requestAutomation(for application: TerminalApplication) {
            guard let bundleID = application.bundleIdentifiers.first else { return }
            _ = AutomationPermissionController.status(bundleID: bundleID, askUserIfNeeded: true)
        }

        public func skipNavigationPermissions() {
            setStep(.verification)
        }

        public func verifyTestEvent() async {
            await perform {
                self.testEventSucceeded = try await Self.emitTestEvent(adapterID: AdapterID("agentcontrol-test"))
                guard self.testEventSucceeded else {
                    self.message = .localized("onboarding.verify.notAcknowledgedMonitorOnly")
                    return
                }
                self.complete()
            }
        }

        public func testIntegration(_ provider: HookProvider) async {
            await perform {
                self.testEventSucceeded = false
                let records = await self.integrationManager.scan()
                self.integrations = records
                guard records.first(where: { $0.provider == provider })?.state == .healthy else {
                    self.testEventSucceeded = false
                    self.message = .localized("integrations.test.installOrRepairFirst")
                    return
                }
                self.testEventSucceeded = try await Self.emitProviderTestEvent(provider)
                if !self.testEventSucceeded {
                    self.message = .localized("integrations.test.notAcknowledged")
                }
            }
        }

        public func continueMonitorOnly() {
            complete()
        }

        public func cancelOnboarding() {
            // No configuration is written before the explicit atomic install step.
            // A completed atomic install remains a valid, repairable integration.
            isOnboardingPresented = false
        }

        public func restartOnboarding() {
            defaults.removeObject(forKey: Keys.completed)
            setStep(.welcome)
            isOnboardingPresented = true
        }

        private func complete() {
            defaults.set(true, forKey: Keys.completed)
            defaults.removeObject(forKey: Keys.step)
            isOnboardingPresented = false
        }

        private func perform(_ operation: () async throws -> Void) async {
            guard !busy else { return }
            busy = true
            message = nil
            defer { busy = false }
            do {
                try await operation()
            } catch is CancellationError {
                message = .localized("integrations.operation.cancelled")
            } catch {
                message = .verbatim(RedactedDiagnosticExporter.sanitize(String(describing: error)))
            }
        }

        private static func emitTestEvent(adapterID: AdapterID) async throws -> Bool {
            let now = Date()
            let sessionID = SessionID(UUID())
            let nodeID = NodeID(UUID())
            let project = ProjectReference(
                id: ProjectID(UUID()),
                name: "yusufiwt Test",
                rootURL: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            )
            let session = AgentSession(
                id: sessionID,
                nodeID: nodeID,
                adapterID: adapterID,
                externalSessionID: "integration-self-test-\(adapterID.rawValue)",
                project: project,
                terminalContext: nil,
                parentSessionID: nil,
                state: .discovered,
                startedAt: now,
                endedAt: nil,
                lastMeaningfulEventAt: now,
                snapshotRevision: 0
            )
            let envelope = EventEnvelope(
                eventID: EventID(UUID()),
                eventType: "session.stateChanged",
                source: EventSource(adapterID: session.adapterID, adapterVersion: "1", nodeID: nodeID),
                sessionID: sessionID,
                sequence: 1,
                occurredAt: now,
                receivedAt: now,
                payload: .object(["state": .string(SessionState.running.rawValue)]),
                privacyClass: .publicMetadata,
                correlationID: EnvelopeID(UUID()),
                schemaHash: "agentcontrol-onboarding-v1"
            )
            let paths = try AgentControlPaths.userDefault()
            let client = AgentControlHookClient(configuration: HookConfiguration(
                socketURL: paths.socketURL,
                spoolDirectory: paths.spoolDirectory,
                statusTimeoutMilliseconds: 1000
            ))
            let response = await client.emit(HelperEventSubmission(envelope: envelope, initialSession: session))
            if case let .eventAccepted(disposition) = response {
                return disposition != .spooled && disposition != .rejectedTransition
            }
            return false
        }

        private static func emitProviderTestEvent(_ provider: HookProvider) async throws -> Bool {
            let token = "integration-self-test-\(provider.rawValue)-\(UUID().uuidString.lowercased())"
            let paths = try AgentControlPaths.userDefault()
            let client = AgentControlHookClient(configuration: HookConfiguration(
                socketURL: paths.socketURL,
                spoolDirectory: paths.spoolDirectory,
                statusTimeoutMilliseconds: 1000
            ))
            let eventNames = provider == .cursor ? ["sessionStart", "sessionEnd"] : ["SessionStart", "Stop"]
            for eventName in eventNames {
                let mapping = try ProviderHookMapper().map(
                    provider: provider,
                    input: .object([
                        "hook_event_name": .string(eventName),
                        "session_id": .string(token),
                        "conversation_id": .string(token),
                        "cwd": .string("/private/tmp"),
                        "workspace_roots": .array([.string("/private/tmp")])
                    ]),
                    environment: ["AGENTCONTROL_PROVIDER_VERSION": "1.0.0", "PWD": "/private/tmp"]
                )
                for submission in mapping.submissions {
                    guard case let .eventAccepted(disposition) = await client.emit(submission, notification: true),
                          disposition != .spooled,
                          disposition != .rejectedTransition
                    else { return false }
                }
            }
            return true
        }

        private enum Keys {
            static let completed = "onboarding.completed.v1"
            static let step = "onboarding.step.v1"
            static let mode = "onboarding.mode.v1"
        }
    }
#endif
