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
        case .rightOption: return "Right ⌥ Option".loc
        case .leftOption: return "Left ⌥ Option".loc
        case .rightControl: return "Right ⌃ Control".loc
        }
    }
}

enum ActivationMode: String, CaseIterable, Codable, Identifiable {
    case holdToTalk
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .holdToTalk: return "Hold to talk".loc
        case .toggle: return "Toggle (press to start, press to stop)".loc
        }
    }
}

enum InsertionMode: String, CaseIterable, Codable, Identifiable {
    case paste
    case type

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paste: return "Paste (fast)".loc
        case .type: return "Type character-by-character".loc
        }
    }
}

/// A language Talkie can transcribe / auto-detect. `id` is a locale identifier.
struct TalkieLanguage: Identifiable, Hashable {
    let id: String
    let name: String

    /// The region's flag emoji, derived from the locale's region subtag
    /// ("en-US" → 🇺🇸, "de-DE" → 🇩🇪). Falls back to a white flag.
    var flag: String {
        let region = id.split(separator: "-").last.map(String.init)?.uppercased() ?? ""
        guard region.count == 2 else { return "🏳️" }
        let base: UInt32 = 0x1F1E6 - 0x41  // regional-indicator A − ASCII 'A'
        var emoji = ""
        for scalar in region.unicodeScalars {
            guard ("A"..."Z").contains(Character(scalar)),
                  let flagScalar = UnicodeScalar(base + scalar.value) else { return "🏳️" }
            emoji.unicodeScalars.append(flagScalar)
        }
        return emoji
    }

    /// The language name without the parenthetical region qualifier, e.g.
    /// "English (US)" → "English", "Portuguese (Brazil)" → "Portuguese".
    var shortName: String {
        guard let paren = name.firstIndex(of: "(") else { return name }
        return String(name[..<paren]).trimmingCharacters(in: .whitespaces)
    }

    /// The country name for the locale's region subtag, e.g. "en-US" → "United
    /// States", "de-DE" → "Germany". Pinned to English so it matches the
    /// hardcoded English catalog names rather than localizing to the system UI.
    /// Used as the card's second line so every tile has a uniform two-line label.
    var regionName: String {
        let region = id.split(separator: "-").last.map(String.init) ?? ""
        return Locale(identifier: "en_US").localizedString(forRegionCode: region) ?? region
    }

    /// The language grid tile's primary label: the short name, but the full
    /// qualified name when another catalog entry shares that short name — so the
    /// two English variants don't both read just "English".
    var gridTitle: String {
        let collides = talkieLanguageCatalog.filter { $0.shortName == shortName }.count > 1
        return collides ? name : shortName
    }
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
    /// Meeting transcription language mode: "auto" (multilingual — auto-detect per
    /// speaker stream) or a specific locale id from `spokenLanguages` (e.g. "de-DE").
    @Published var meetingLanguageMode: String {
        didSet { defaults.set(meetingLanguageMode, forKey: Keys.meetingLanguageMode) }
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
    /// Experimental: paste the raw transcript the instant you stop, then swap in
    /// the cleaned version once the on-device model finishes — so there's no
    /// visible wait. Off by default: the in-place swap selects backward over the
    /// inserted text, which is unreliable if the caret moved or you kept typing.
    @Published var optimisticInsertion: Bool {
        didSet { defaults.set(optimisticInsertion, forKey: Keys.optimisticInsertion) }
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
            Keys.optimisticInsertion: true,
            Keys.cleanupLevel: CleanupLevel.medium.rawValue,
            Keys.meetingLanguageMode: "auto",
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
        // The Languages grid only renders catalog locales, so the stored set must
        // stay catalog-authoritative: canonicalize, drop anything not in the
        // catalog (e.g. a Swedish/Polish Mac whose `sv-SE` canonicalizes to a
        // non-catalog id), de-dupe preserving order, and fall back to en-US if
        // that empties the set. This keeps the grid's count, highlighted tiles,
        // and "keep at least one" guard from ever diverging from what's stored.
        let catalogIDs = Set(talkieLanguageCatalog.map(\.id))
        let rawPrimary = canonicalLocaleID(d.string(forKey: Keys.localeIdentifier) ?? Locale.current.identifier)
        let storedLanguages = d.stringArray(forKey: Keys.spokenLanguages)
        let rawLanguages = (storedLanguages?.isEmpty == false) ? storedLanguages! : [rawPrimary]
        var seenLocales = Set<String>()
        let seeded = rawLanguages.map(canonicalLocaleID)
            .filter { catalogIDs.contains($0) && seenLocales.insert($0).inserted }
        let finalLanguages = seeded.isEmpty ? ["en-US"] : seeded
        spokenLanguages = finalLanguages
        localeIdentifier = finalLanguages.first ?? "en-US"
        autoCapitalize = d.bool(forKey: Keys.autoCapitalize)
        cleanupFillers = d.bool(forKey: Keys.cleanupFillers)
        learnFromEdits = d.bool(forKey: Keys.learnFromEdits)
        optimisticInsertion = d.bool(forKey: Keys.optimisticInsertion)
        cleanupLevel = CleanupLevel(rawValue: d.string(forKey: Keys.cleanupLevel) ?? "") ?? .medium
        meetingLanguageMode = d.string(forKey: Keys.meetingLanguageMode) ?? "auto"
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
        static let optimisticInsertion = "optimisticInsertion"
        static let cleanupLevel = "cleanupLevel"
        static let meetingLanguageMode = "meetingLanguageMode"
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
