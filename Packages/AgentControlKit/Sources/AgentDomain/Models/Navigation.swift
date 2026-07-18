import Foundation

public enum NavigationResultLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case unsupported
    case projectFolder
    case application
    case window
    case exactPane

    private var rank: Int {
        switch self {
        case .unsupported: 0
        case .projectFolder: 1
        case .application: 2
        case .window: 3
        case .exactPane: 4
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum NavigationFailureReason: String, Codable, Sendable, Equatable {
    case contextMissing
    case applicationNotInstalled
    case exactTargetUnavailable
    case accessibilityNotGranted
    case automationNotGranted
    case extensionUnavailable
    case commandFailed
    case openFailed
}

public struct NavigationResult: Codable, Sendable, Equatable {
    public let level: NavigationResultLevel
    public let applicationBundleID: String?
    public let mechanism: String
    public let reason: NavigationFailureReason?

    public init(
        level: NavigationResultLevel,
        applicationBundleID: String?,
        mechanism: String,
        reason: NavigationFailureReason? = nil
    ) {
        self.level = level
        self.applicationBundleID = applicationBundleID
        self.mechanism = mechanism
        self.reason = reason
    }
}

public enum TerminalApplication: String, Codable, Sendable, CaseIterable {
    case terminal
    case iTerm2
    case ghostty
    case warp
    case wezTerm
    case visualStudioCode
    case cursor
    case unknown

    public init(bundleIdentifier: String) {
        switch bundleIdentifier {
        case "com.apple.Terminal": self = .terminal
        case "com.googlecode.iterm2": self = .iTerm2
        case "com.mitchellh.ghostty": self = .ghostty
        case "dev.warp.Warp-Stable", "dev.warp.Warp": self = .warp
        case "com.github.wez.wezterm": self = .wezTerm
        case "com.microsoft.VSCode": self = .visualStudioCode
        case "com.todesktop.230313mzl4w4u92": self = .cursor
        default: self = .unknown
        }
    }

    public var bundleIdentifiers: [String] {
        switch self {
        case .terminal: ["com.apple.Terminal"]
        case .iTerm2: ["com.googlecode.iterm2"]
        case .ghostty: ["com.mitchellh.ghostty"]
        case .warp: ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        case .wezTerm: ["com.github.wez.wezterm"]
        case .visualStudioCode: ["com.microsoft.VSCode"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .unknown: []
        }
    }
}
