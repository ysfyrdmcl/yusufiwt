#if os(macOS)
    import Foundation
    import Observation

    public enum MacLocalLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
        case system
        case turkish
        case english

        public var id: String {
            rawValue
        }

        public var locale: Locale {
            switch self {
            case .system:
                .autoupdatingCurrent
            case .turkish:
                Locale(identifier: "tr")
            case .english:
                Locale(identifier: "en")
            }
        }

        fileprivate var appleLanguages: [String]? {
            switch self {
            case .system: nil
            case .turkish: ["tr"]
            case .english: ["en"]
            }
        }
    }

    public struct MacLocalPreferences: Codable, Sendable, Equatable {
        public static let currentVersion = 1

        public var version: Int
        public var language: MacLocalLanguage
        public var showPanelForAttention: Bool
        public var closePanelAfterDecision: Bool
        public var autoHideActivity: Bool

        public init(
            version: Int = currentVersion,
            language: MacLocalLanguage = .system,
            showPanelForAttention: Bool = true,
            closePanelAfterDecision: Bool = true,
            autoHideActivity: Bool = true
        ) {
            self.version = version
            self.language = language
            self.showPanelForAttention = showPanelForAttention
            self.closePanelAfterDecision = closePanelAfterDecision
            self.autoHideActivity = autoHideActivity
        }
    }

    @MainActor
    @Observable
    public final class MacLocalPreferencesStore {
        public static let storageKey = "mac-local.ui-preferences.v1"

        public private(set) var value: MacLocalPreferences

        @ObservationIgnored
        private let defaults: UserDefaults

        public init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
            value = Self.storedValue(in: defaults) ?? MacLocalPreferences()
        }

        public func save(_ newValue: MacLocalPreferences) {
            var current = newValue
            current.version = MacLocalPreferences.currentVersion
            value = current
            if let data = try? JSONEncoder().encode(current) {
                defaults.set(data, forKey: Self.storageKey)
            }
            if let languages = current.language.appleLanguages {
                defaults.set(languages, forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
        }

        private static func storedValue(in defaults: UserDefaults) -> MacLocalPreferences? {
            guard let data = defaults.data(forKey: storageKey) else { return nil }
            guard let value = try? JSONDecoder().decode(MacLocalPreferences.self, from: data),
                  value.version == MacLocalPreferences.currentVersion
            else { return nil }
            return value
        }
    }
#endif
