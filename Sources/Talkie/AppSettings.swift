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

/// A language Talkie can transcribe / auto-detect. `id` is a locale identifier.
struct TalkieLanguage: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Common languages offered in Settings (a subset of SpeechTranscriber's locales).
let talkieLanguageCatalog: [TalkieLanguage] = [
    .init(id: "en-US", name: "English (US)"),
    .init(id: "en-GB", name: "English (UK)"),
    .init(id: "de-DE", name: "German"),
    .init(id: "fr-FR", name: "French"),
    .init(id: "es-ES", name: "Spanish"),
    .init(id: "it-IT", name: "Italian"),
    .init(id: "pt-BR", name: "Portuguese (Brazil)"),
    .init(id: "nl-NL", name: "Dutch"),
    .init(id: "ja-JP", name: "Japanese"),
    .init(id: "ko-KR", name: "Korean"),
    .init(id: "zh-CN", name: "Chinese (Simplified)"),
]

/// Normalize a stored/seeded locale id to a clean transcriber locale. On a
/// German-region Mac with an English UI, `Locale.current.identifier` is
/// `en_US@rg=dezzzz` — a Unicode *region-override* id whose language folds to
/// `en`, so it silently transcribes in English. This maps any such id back to a
/// catalog locale the speech models actually recognize (`en_US@rg=dezzzz` → `en-US`).
func canonicalLocaleID(_ id: String) -> String {
    let loc = Locale(identifier: id)
    guard let lang = loc.language.languageCode?.identifier else { return id }
    let region = loc.region?.identifier
    if let exact = talkieLanguageCatalog.first(where: {
        let c = Locale(identifier: $0.id)
        return c.language.languageCode?.identifier == lang && c.region?.identifier == region
    }) { return exact.id }
    if let langOnly = talkieLanguageCatalog.first(where: {
        Locale(identifier: $0.id).language.languageCode?.identifier == lang
    }) { return langOnly.id }
    return region.map { "\(lang)-\($0)" } ?? id
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
    /// Languages the user speaks. The first is the primary; when there's more
    /// than one, Talkie auto-detects which language each dictation was in.
    @Published var spokenLanguages: [String] {
        didSet {
            defaults.set(spokenLanguages, forKey: Keys.spokenLanguages)
            // Keep the primary locale in sync with the first selected language.
            if let first = spokenLanguages.first { localeIdentifier = first }
            notifyChanged()
        }
    }
    @Published var autoCapitalize: Bool {
        didSet { defaults.set(autoCapitalize, forKey: Keys.autoCapitalize) }
    }
    @Published var cleanupFillers: Bool {
        didSet { defaults.set(cleanupFillers, forKey: Keys.cleanupFillers) }
    }
    @Published var learnFromEdits: Bool {
        didSet { defaults.set(learnFromEdits, forKey: Keys.learnFromEdits) }
    }
    /// On-device LLM cleanup intensity (none / light / medium / high).
    @Published var cleanupLevel: CleanupLevel {
        didSet { defaults.set(cleanupLevel.rawValue, forKey: Keys.cleanupLevel) }
    }
    /// When on, the cleanup personality adapts to the app you're dictating into
    /// (Messages → friendly, Mail → professional, code → faithful, …).
    @Published var appAdaptiveCleanup: Bool {
        didSet { defaults.set(appAdaptiveCleanup, forKey: Keys.appAdaptiveCleanup) }
    }
    /// Per-app-category style overrides (AppCategory.rawValue → CleanupStyle.rawValue).
    @Published var appCleanupStyles: [String: String] {
        didSet { defaults.set(appCleanupStyles, forKey: Keys.appCleanupStyles) }
    }
    /// Bias recognition with names/identifiers from the app you're dictating into.
    @Published var contextAwareness: Bool {
        didSet { defaults.set(contextAwareness, forKey: Keys.contextAwareness) }
    }
    /// Vibe coding: snap spoken filenames to the real files in your project.
    @Published var vibeCoding: Bool {
        didSet { defaults.set(vibeCoding, forKey: Keys.vibeCoding) }
    }
    /// What Talkie calls you (set during onboarding; shown on the dashboard).
    @Published var userName: String {
        didSet { defaults.set(userName, forKey: Keys.userName) }
    }
    /// True once the first-run onboarding has been completed.
    @Published var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Keys.hasOnboarded) }
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
            Keys.localeIdentifier: canonicalLocaleID(Locale.current.identifier),
            Keys.autoCapitalize: true,
            Keys.cleanupFillers: true,
            Keys.learnFromEdits: true,
            Keys.cleanupLevel: CleanupLevel.medium.rawValue,
            Keys.appAdaptiveCleanup: true,
            Keys.contextAwareness: true,
            Keys.vibeCoding: false,
            Keys.userName: "",
            Keys.hasOnboarded: false,
            Keys.playSounds: true,
            Keys.launchAtLogin: false,
        ])
        activationKey = ActivationKey(rawValue: d.string(forKey: Keys.activationKey) ?? "") ?? .rightOption
        activationMode = ActivationMode(rawValue: d.string(forKey: Keys.activationMode) ?? "") ?? .holdToTalk
        insertionMode = InsertionMode(rawValue: d.string(forKey: Keys.insertionMode) ?? "") ?? .paste
        let primary = canonicalLocaleID(d.string(forKey: Keys.localeIdentifier) ?? Locale.current.identifier)
        localeIdentifier = primary
        let storedLanguages = d.stringArray(forKey: Keys.spokenLanguages)
        // Canonicalize every stored language (migrating any junk region-override id
        // like `en_US@rg=dezzzz` to `en-US`) and de-dupe, preserving order.
        let rawLanguages = (storedLanguages?.isEmpty == false) ? storedLanguages! : [primary]
        var seenLocales = Set<String>()
        spokenLanguages = rawLanguages.map(canonicalLocaleID).filter { seenLocales.insert($0).inserted }
        autoCapitalize = d.bool(forKey: Keys.autoCapitalize)
        cleanupFillers = d.bool(forKey: Keys.cleanupFillers)
        learnFromEdits = d.bool(forKey: Keys.learnFromEdits)
        cleanupLevel = CleanupLevel(rawValue: d.string(forKey: Keys.cleanupLevel) ?? "") ?? .medium
        appAdaptiveCleanup = d.bool(forKey: Keys.appAdaptiveCleanup)
        appCleanupStyles = (d.dictionary(forKey: Keys.appCleanupStyles) as? [String: String])
            ?? AppSettings.defaultAppCleanupStyles
        contextAwareness = d.bool(forKey: Keys.contextAwareness)
        vibeCoding = d.bool(forKey: Keys.vibeCoding)
        userName = d.string(forKey: Keys.userName) ?? ""
        hasOnboarded = d.bool(forKey: Keys.hasOnboarded)
        playSounds = d.bool(forKey: Keys.playSounds)
        launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
    }

    /// Sensible per-category defaults for the adaptive cleanup personality.
    static let defaultAppCleanupStyles: [String: String] = [
        AppCategory.coding.rawValue: CleanupStyle.faithful.rawValue,
        AppCategory.terminal.rawValue: CleanupStyle.faithful.rawValue,
        AppCategory.mail.rawValue: CleanupStyle.professional.rawValue,
        AppCategory.chat.rawValue: CleanupStyle.friendly.rawValue,
        AppCategory.notes.rawValue: CleanupStyle.neutral.rawValue,
        AppCategory.browser.rawValue: CleanupStyle.neutral.rawValue,
        AppCategory.design.rawValue: CleanupStyle.neutral.rawValue,
        AppCategory.other.rawValue: CleanupStyle.neutral.rawValue,
    ]

    /// The cleanup style for an app category (user override, else default).
    func cleanupStyle(for category: AppCategory) -> CleanupStyle {
        if let raw = appCleanupStyles[category.rawValue], let style = CleanupStyle(rawValue: raw) {
            return style
        }
        return AppSettings.defaultAppCleanupStyles[category.rawValue]
            .flatMap(CleanupStyle.init) ?? .neutral
    }

    private enum Keys {
        static let activationKey = "activationKey"
        static let activationMode = "activationMode"
        static let insertionMode = "insertionMode"
        static let localeIdentifier = "localeIdentifier"
        static let spokenLanguages = "spokenLanguages"
        static let autoCapitalize = "autoCapitalize"
        static let cleanupFillers = "cleanupFillers"
        static let learnFromEdits = "learnFromEdits"
        static let cleanupLevel = "cleanupLevel"
        static let appAdaptiveCleanup = "appAdaptiveCleanup"
        static let appCleanupStyles = "appCleanupStyles"
        static let contextAwareness = "contextAwareness"
        static let vibeCoding = "vibeCoding"
        static let userName = "userName"
        static let hasOnboarded = "hasOnboarded"
        static let playSounds = "playSounds"
        static let launchAtLogin = "launchAtLogin"
    }
}
