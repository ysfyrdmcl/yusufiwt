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
            LocalizedStringKey("controlCenter.history." + rawValue)
        }
    }

    struct HistoryAnalyticsControlCenterView: View {
        @Bindable var store: AgentControlStore
        private var mode: HistoryAnalyticsMode {
            store.selectedSection == .analytics ? .analytics : .history
        }

        private var modeSelection: Binding<HistoryAnalyticsMode> {
            Binding(get: { mode }, set: { store.selectedSection = $0.section })
        }

        var body: some View {
            VStack(spacing: 0) {
                Picker("controlCenter.history.mode", selection: modeSelection) {
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
            LocalizedStringKey("controlCenter.safety." + rawValue)
        }
    }

    struct PrivacyDiagnosticsControlCenterView: View {
        @Bindable var store: AgentControlStore
        private var mode: PrivacyDiagnosticsMode {
            store.selectedSection == .privacy ? .privacy : .diagnostics
        }

        private var modeSelection: Binding<PrivacyDiagnosticsMode> {
            Binding(get: { mode }, set: { store.selectedSection = $0.section })
        }

        var body: some View {
            VStack(spacing: 0) {
                Picker("controlCenter.safety.mode", selection: modeSelection) {
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
        }
    }
#endif
