#if os(macOS)
    import AgentDomain
    import AgentHookKit
    import AgentMacUI
    import Foundation
    import Testing

    @Suite("Phase 10 navigation and onboarding")
    struct Phase10NavigationTests {
        @Test("IDE stop waits for a matching terminal acknowledgment", arguments: [true, false])
        @MainActor
        func stopAcknowledgment(sent: Bool) async throws {
            var dispatchedURL: URL?
            let stopper = TerminalStopCoordinator(openExtensionURL: { dispatchedURL = $0; return true })
            let terminal = TerminalContext(
                applicationBundleID: "com.microsoft.VSCode", correlationToken: "verified-token", capturedAt: Date()
            )
            let task = Task { await stopper.stop(context: terminal) }
            for _ in 0 ..< 100 where dispatchedURL == nil {
                await Task.yield()
            }
            let url = try #require(dispatchedURL)
            var callback = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            callback.scheme = "agentcontrol"
            callback.host = "stop-result"
            callback.path = ""
            callback.queryItems?.append(URLQueryItem(name: "sent", value: String(sent)))
            try stopper.handleCallback(#require(callback.url))
            #expect(await task.value == (sent ? .signalSent : .unavailable(.exactTargetUnavailable)))
        }

        @Test("Supported exact-pane adapters choose official APIs before accessibility")
        func exactPanePlans() throws {
            let planner = TerminalNavigationPlanner()
            let permissions = NavigationPermissionSnapshot(
                accessibilityEnabled: true,
                automationAuthorizedBundleIDs: [
                    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"
                ]
            )

            let terminal = planner.plan(
                context: context(bundleID: "com.apple.Terminal", paneID: "/dev/ttys001"),
                projectURL: nil,
                permissions: permissions
            )
            guard case let .appleScript(bundleID, _, arguments, level) = try #require(terminal.attempts.first) else {
                Issue.record("Terminal.app did not plan AppleScript first")
                return
            }
            #expect(bundleID == "com.apple.Terminal")
            #expect(arguments == ["/dev/ttys001"])
            #expect(level == .exactPane)

            let wezTerm = planner.plan(
                context: context(bundleID: "com.github.wez.wezterm", paneID: "42"),
                projectURL: nil,
                permissions: permissions
            )
            guard case .wezTermCLI(paneID: "42") = try #require(wezTerm.attempts.first) else {
                Issue.record("WezTerm did not plan its CLI first")
                return
            }

            for bundleID in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"] {
                let plan = planner.plan(context: context(bundleID: bundleID, paneID: "terminal"), projectURL: nil, permissions: permissions)
                guard case let .extensionURL(url, level) = try #require(plan.attempts.first) else {
                    Issue.record("IDE did not plan its URI handler first")
                    continue
                }
                #expect(level == .exactPane)
                #expect(url.absoluteString.contains("token=session-token"))
            }
        }

        @Test("Ghostty uses authorized AppleScript and Warp uses its official workspace URL")
        func ghosttyAndWarpPlans() throws {
            let planner = TerminalNavigationPlanner()
            let permissions = NavigationPermissionSnapshot(
                accessibilityEnabled: false,
                automationAuthorizedBundleIDs: ["com.mitchellh.ghostty"]
            )
            let ghostty = planner.plan(
                context: context(bundleID: "com.mitchellh.ghostty", paneID: "surface-1"),
                projectURL: nil,
                permissions: permissions
            )
            guard case .appleScript = try #require(ghostty.attempts.first) else {
                Issue.record("Ghostty did not use its AppleScript dictionary")
                return
            }
            let warp = planner.plan(
                context: context(bundleID: "dev.warp.Warp-Stable", paneID: nil),
                projectURL: URL(fileURLWithPath: "/private/tmp/project", isDirectory: true),
                permissions: permissions
            )
            guard case let .extensionURL(url, level) = try #require(warp.attempts.first) else {
                Issue.record("Warp did not plan its workspace URI")
                return
            }
            #expect(url.scheme == "warp")
            #expect(level == .projectFolder)
        }

        @Test("Missing permissions degrade to activation without scheduling a permission prompt")
        func permissionFallback() throws {
            let plan = TerminalNavigationPlanner().plan(
                context: context(bundleID: "com.apple.Terminal", paneID: "/dev/ttys002"),
                projectURL: URL(fileURLWithPath: "/private/tmp/project"),
                permissions: NavigationPermissionSnapshot(accessibilityEnabled: false)
            )
            #expect(plan.fallbackReason == .automationNotGranted)
            #expect(!plan.attempts.contains {
                if case .appleScript = $0 {
                    true
                } else {
                    false
                }
            })
            #expect(!plan.attempts.contains {
                if case .accessibility = $0 {
                    true
                } else {
                    false
                }
            })
            guard case .activate = try #require(plan.attempts.first) else {
                Issue.record("Application activation was not the first safe fallback")
                return
            }
        }

        @Test("Stop availability requires a fresh exact target and never supports Warp fallback")
        @MainActor
        func stopAvailability() {
            let now = Date(timeIntervalSince1970: 1_784_320_000)
            let stopper = TerminalStopCoordinator(maximumContextAge: 60)
            #expect(stopper.availability(
                for: context(bundleID: "com.microsoft.VSCode", paneID: "terminal"), at: now
            ) == .available)
            #expect(stopper.availability(
                for: TerminalContext(
                    applicationBundleID: "com.microsoft.VSCode", correlationToken: "session-token",
                    capturedAt: now.addingTimeInterval(-61)
                ),
                at: now
            ) == .contextStale)
            #expect(stopper.availability(
                for: context(bundleID: "dev.warp.Warp-Stable", paneID: nil), at: now
            ) == .unsupportedTerminal)
        }

        @Test("Interrupted onboarding checkpoints safely without touching provider configuration")
        @MainActor
        func onboardingCheckpoint() throws {
            let suite = "Phase10OnboardingTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let home = URL(fileURLWithPath: "/private/tmp/ac-phase10-onboarding-\(UUID().uuidString)", isDirectory: true)
            let manager = ManagedProviderIntegrationManager(
                homeDirectory: home,
                hookExecutableURL: URL(fileURLWithPath: "/app/agentcontrol-hook"),
                receiptURL: home.appendingPathComponent("receipts.json")
            )
            var coordinator: Phase10Coordinator? = Phase10Coordinator(
                defaults: defaults,
                integrationManager: manager,
                navigationPreferences: NavigationPreferences(defaults: defaults)
            )
            coordinator?.setStep(.review)
            coordinator?.cancelOnboarding()
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/hooks.json").path))
            coordinator = Phase10Coordinator(
                defaults: defaults,
                integrationManager: manager,
                navigationPreferences: NavigationPreferences(defaults: defaults)
            )
            #expect(coordinator?.onboardingStep == .review)
        }

        private func context(bundleID: String, paneID: String?) -> TerminalContext {
            TerminalContext(
                applicationBundleID: bundleID,
                paneIdentifier: paneID,
                workspaceURI: URL(fileURLWithPath: "/private/tmp/project", isDirectory: true),
                correlationToken: "session-token",
                capturedAt: Date(timeIntervalSince1970: 1_784_320_000)
            )
        }
    }
#endif
