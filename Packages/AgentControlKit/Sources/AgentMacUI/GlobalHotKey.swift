#if os(macOS)
    import AppKit
    import Foundation

    @MainActor
    public struct GlobalHotKeySetting: Codable, Hashable {
        public static let currentVersion = 1
        public static let controlOptionSpace = GlobalHotKeySetting(
            version: currentVersion,
            keyCode: 49,
            modifierRawValue: NSEvent.ModifierFlags([.control, .option]).rawValue
        )
        public static let commandShiftA = GlobalHotKeySetting(
            version: currentVersion,
            keyCode: 0,
            modifierRawValue: NSEvent.ModifierFlags([.command, .shift]).rawValue
        )

        public let version: Int
        public let keyCode: UInt16
        public let modifierRawValue: UInt

        public init(version: Int = currentVersion, keyCode: UInt16, modifierRawValue: UInt) {
            self.version = version
            self.keyCode = keyCode
            self.modifierRawValue = modifierRawValue
        }

        fileprivate var modifiers: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifierRawValue)
                .intersection(.deviceIndependentFlagsMask)
        }
    }

    @MainActor
    public final class GlobalHotKeyPreferences {
        public static let storageKey = "globalHotKey.v1"
        private let defaults: UserDefaults

        public init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        public func load() -> GlobalHotKeySetting {
            guard let data = defaults.data(forKey: Self.storageKey),
                  let value = try? JSONDecoder().decode(GlobalHotKeySetting.self, from: data),
                  value.version == GlobalHotKeySetting.currentVersion
            else { return .controlOptionSpace }
            return value
        }

        public func save(_ value: GlobalHotKeySetting) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    @MainActor
    public final class GlobalHotKeyController {
        private var globalMonitor: Any?
        private var localMonitor: Any?
        private let action: @MainActor () -> Void
        private var setting: GlobalHotKeySetting

        public init(
            setting: GlobalHotKeySetting = .controlOptionSpace,
            action: @escaping @MainActor () -> Void
        ) {
            self.setting = setting
            self.action = action
        }

        public func update(_ value: GlobalHotKeySetting) {
            let wasRunning = globalMonitor != nil || localMonitor != nil
            stop()
            setting = value
            if wasRunning {
                start()
            }
        }

        public func start() {
            guard globalMonitor == nil, localMonitor == nil else { return }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard self?.matches(event) == true else { return }
                Task { @MainActor in self?.action() }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard self?.matches(event) == true else { return event }
                self?.action()
                return nil
            }
        }

        public func stop() {
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
            }
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
            }
            globalMonitor = nil
            localMonitor = nil
        }

        private func matches(_ event: NSEvent) -> Bool {
            event.keyCode == setting.keyCode
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == setting.modifiers
        }
    }
#endif
