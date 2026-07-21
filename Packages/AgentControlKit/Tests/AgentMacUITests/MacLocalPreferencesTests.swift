import AgentMacUI
import Foundation
import Testing

@Suite("Mac Local shell and settings", .serialized)
struct MacLocalPreferencesTests {
    @Test("Notch-first Control Center removes duplicate operational sections")
    func controlCenterInformationArchitecture() {
        #expect(ControlCenterInformationArchitecture.primarySections == [
            .integrations,
            .rules,
            .history,
            .diagnostics
        ])
        #expect(!ControlCenterInformationArchitecture.primarySections.contains(.overview))
        #expect(!ControlCenterInformationArchitecture.primarySections.contains(.active))
        #expect(!ControlCenterInformationArchitecture.primarySections.contains(.inbox))
        #expect(ControlCenterInformationArchitecture.navigationSection(for: .analytics) == .history)
        #expect(ControlCenterInformationArchitecture.navigationSection(for: .privacy) == .diagnostics)
    }

    @Test("Panel and language preferences persist with safe defaults")
    @MainActor
    func applicationPreferencePersistence() throws {
        let suiteName = "AgentMacUITests.application-preferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = MacLocalPreferencesStore(defaults: defaults)
        #expect(fresh.value == MacLocalPreferences())
        #expect(fresh.value.language == .system)
        #expect(fresh.value.showPanelForAttention)
        #expect(fresh.value.closePanelAfterDecision)
        #expect(fresh.value.autoHideActivity)

        let customized = MacLocalPreferences(
            language: .turkish,
            showPanelForAttention: false,
            closePanelAfterDecision: false,
            autoHideActivity: false
        )
        fresh.save(customized)

        #expect(MacLocalPreferencesStore(defaults: defaults).value == customized)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["tr"])
    }

    @Test("Unknown settings versions fail back to privacy-safe defaults")
    @MainActor
    func unknownVersionFallback() throws {
        let suiteName = "AgentMacUITests.application-preferences-version.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let future = MacLocalPreferences(
            version: MacLocalPreferences.currentVersion + 1,
            language: .english,
            showPanelForAttention: false,
            closePanelAfterDecision: false,
            autoHideActivity: false
        )
        try defaults.set(JSONEncoder().encode(future), forKey: MacLocalPreferencesStore.storageKey)

        #expect(MacLocalPreferencesStore(defaults: defaults).value == MacLocalPreferences())
    }

    @Test("Language choices map to stable locales")
    func languageLocales() {
        #expect(MacLocalLanguage.turkish.locale.identifier == "tr")
        #expect(MacLocalLanguage.english.locale.identifier == "en")
    }
}
