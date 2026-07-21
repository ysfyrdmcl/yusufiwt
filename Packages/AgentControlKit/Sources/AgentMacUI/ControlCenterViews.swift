#if os(macOS)
    import SwiftUI

    public enum ControlCenterInformationArchitecture {
        public static let primarySections: [DashboardSection] = [
            .integrations,
            .rules,
            .history,
            .diagnostics
        ]

        public static func navigationSection(for section: DashboardSection) -> DashboardSection {
            switch section {
            case .analytics: .history
            case .privacy: .diagnostics
            default: section
            }
        }
    }

    private enum HistoryAnalyticsMode: String, CaseIterable, Identifiable {
        case history
        case analytics

        var id: String {
            rawValue
        }

        var section: DashboardSection {
            self == .history ? .history : .analytics
        }

        var titleKey: LocalizedStringKey {
            LocalizedStringKey("controlCenter.history.\(rawValue)")
        }
    }

    struct HistoryAnalyticsControlCenterView: View {
        @Bindable var store: AgentControlStore
        @State private var mode: HistoryAnalyticsMode

        init(store: AgentControlStore) {
            self.store = store
            _mode = State(initialValue: store.selectedSection == .analytics ? .analytics : .history)
        }

        var body: some View {
            VStack(spacing: 0) {
                Picker("controlCenter.history.mode", selection: $mode) {
                    ForEach(HistoryAnalyticsMode.allCases) { mode in
                        Text(mode.titleKey).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, AgentControlSpacing.page)
                .padding(.top, AgentControlSpacing.standard)
                .accessibilityIdentifier("controlCenter.history.mode")

                if mode == .history {
                    HistoryView(store: store)
                } else {
                    AnalyticsView(store: store)
                }
            }
            .task { await select(mode) }
            .onChange(of: mode) { _, value in Task { await select(value) } }
        }

        private func select(_ value: HistoryAnalyticsMode) async {
            store.selectedSection = value.section
            await store.refreshSelectedOperations()
        }
    }

    private enum PrivacyDiagnosticsMode: String, CaseIterable, Identifiable {
        case privacy
        case diagnostics

        var id: String {
            rawValue
        }

        var section: DashboardSection {
            self == .privacy ? .privacy : .diagnostics
        }

        var titleKey: LocalizedStringKey {
            LocalizedStringKey("controlCenter.safety.\(rawValue)")
        }
    }

    struct PrivacyDiagnosticsControlCenterView: View {
        @Bindable var store: AgentControlStore
        @State private var mode: PrivacyDiagnosticsMode

        init(store: AgentControlStore) {
            self.store = store
            _mode = State(initialValue: store.selectedSection == .privacy ? .privacy : .diagnostics)
        }

        var body: some View {
            VStack(spacing: 0) {
                Picker("controlCenter.safety.mode", selection: $mode) {
                    ForEach(PrivacyDiagnosticsMode.allCases) { mode in
                        Text(mode.titleKey).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, AgentControlSpacing.page)
                .padding(.top, AgentControlSpacing.standard)
                .accessibilityIdentifier("controlCenter.safety.mode")

                if mode == .privacy {
                    PrivacySettingsView(store: store)
                } else {
                    DiagnosticsView(store: store)
                }
            }
            .task { await select(mode) }
            .onChange(of: mode) { _, value in Task { await select(value) } }
        }

        private func select(_ value: PrivacyDiagnosticsMode) async {
            store.selectedSection = value.section
            await store.refreshSelectedOperations()
        }
    }
#endif
