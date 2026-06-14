import Foundation

/// Which key activates dictation. Hold-to-talk uses a modifier so a plain hold
/// doesn't leak keystrokes into the focused app; toggle mode uses a chord.
enum ActivationKey: String, CaseIterable, Codable, Identifiable {
    case rightOption
    case leftOption
    case rightControl
    // NOTE: Fn/Globe was removed — macOS reserves it for "Change Input Source"
    // (language switch), so it can't be cleanly used as a hold-to-talk key.

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightOption: return "Right ⌥ Option"
        case .leftOption: return "Left ⌥ Option"
        case .rightControl: return "Right ⌃ Control"
        }
    }
}

enum ActivationMode: String, CaseIterable, Codable, Identifiable {
    case holdToTalk
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .holdToTalk: return "Hold to talk"
        case .toggle: return "Toggle (press to start, press to stop)"
        }
    }
}

enum InsertionMode: String, CaseIterable, Codable, Identifiable {
    case paste
    case type

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paste: return "Paste (fast)"
        case .type: return "Type character-by-character"
        }
    }
}

/// Scalar app preferences, persisted in `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var activationKey: ActivationKey {
        didSet { defaults.set(activationKey.rawValue, forKey: Keys.activationKey); notifyChanged() }
    }
    @Published var activationMode: ActivationMode {
        didSet { defaults.set(activationMode.rawValue, forKey: Keys.activationMode); notifyChanged() }
    }
    @Published var insertionMode: InsertionMode {
        didSet { defaults.set(insertionMode.rawValue, forKey: Keys.insertionMode) }
    }
    @Published var localeIdentifier: String {
        didSet { defaults.set(localeIdentifier, forKey: Keys.localeIdentifier) }
    }
    @Published var autoCapitalize: Bool {
        didSet { defaults.set(autoCapitalize, forKey: Keys.autoCapitalize) }
    }
    @Published var cleanupFillers: Bool {
        didSet { defaults.set(cleanupFillers, forKey: Keys.cleanupFillers) }
    }
    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Keys.playSounds); notifyChanged() }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            LaunchAtLogin.set(launchAtLogin)
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .talkieSettingsChanged, object: nil)
    }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Keys.activationKey: ActivationKey.rightOption.rawValue,
            Keys.activationMode: ActivationMode.holdToTalk.rawValue,
            Keys.insertionMode: InsertionMode.paste.rawValue,
            Keys.localeIdentifier: Locale.current.identifier,
            Keys.autoCapitalize: true,
            Keys.cleanupFillers: true,
            Keys.playSounds: true,
            Keys.launchAtLogin: false,
        ])
        activationKey = ActivationKey(rawValue: d.string(forKey: Keys.activationKey) ?? "") ?? .rightOption
        activationMode = ActivationMode(rawValue: d.string(forKey: Keys.activationMode) ?? "") ?? .holdToTalk
        insertionMode = InsertionMode(rawValue: d.string(forKey: Keys.insertionMode) ?? "") ?? .paste
        localeIdentifier = d.string(forKey: Keys.localeIdentifier) ?? Locale.current.identifier
        autoCapitalize = d.bool(forKey: Keys.autoCapitalize)
        cleanupFillers = d.bool(forKey: Keys.cleanupFillers)
        playSounds = d.bool(forKey: Keys.playSounds)
        launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
    }

    private enum Keys {
        static let activationKey = "activationKey"
        static let activationMode = "activationMode"
        static let insertionMode = "insertionMode"
        static let localeIdentifier = "localeIdentifier"
        static let autoCapitalize = "autoCapitalize"
        static let cleanupFillers = "cleanupFillers"
        static let playSounds = "playSounds"
        static let launchAtLogin = "launchAtLogin"
    }
}
