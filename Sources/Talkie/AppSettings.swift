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

/// The "paste last transcript" chord, derived so it can NEVER collide with the
/// dictation activation key — holding it must not arm dictation. Command is always
/// part of it (Command is never an activation key); the second modifier is whichever
/// one the activation key does *not* use. The letter key is always V.
struct PasteShortcut: Sendable, Equatable {
    enum Secondary: Sendable, Equatable { case control, option }
    var secondary: Secondary
    /// Human-readable label in canonical modifier order, e.g. "⌃⌘V" or "⌥⌘V".
    var display: String
}

extension ActivationKey {
    /// The re-paste shortcut that avoids this activation key's modifier, so the combo
    /// can't double as a dictation trigger. Recomputed live when the user rebinds.
    var pasteShortcut: PasteShortcut {
        switch self {
        case .rightOption, .leftOption:
            // Activation uses Option → pair Command with Control instead.
            return PasteShortcut(secondary: .control, display: "⌃⌘V")
        case .rightControl:
            // Activation uses Control → pair Command with Option instead.
            return PasteShortcut(secondary: .option, display: "⌥⌘V")
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

/// How long dictation history is kept before pruning. Backed by an `Int` days
/// value in `AppSettings` (`0` = forever) so persistence stays a plain scalar;
/// this enum only supplies the fixed set of choices the Settings picker offers
/// and their honest labels. Retention is a threat-model decision (a lawyer wants
/// it short; a hobbyist may want it all) — no smart default can know which, so
/// it is a user-chosen control, not a silent hardcoded 7-day window.
enum HistoryRetention: Int, CaseIterable, Identifiable {
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    case forever = 0

    var id: Int { rawValue }

    /// Map any stored days value onto the nearest defined option so the picker
    /// always has a valid selection even if the number was written by a future
    /// build (falls back to the 7-day default).
    static func from(days: Int) -> HistoryRetention {
        HistoryRetention(rawValue: days) ?? .sevenDays
    }

    var displayName: String {
        switch self {
        case .oneDay: return "1 day".loc
        case .sevenDays: return "7 days".loc
        case .thirtyDays: return "30 days".loc
        case .ninetyDays: return "90 days".loc
        case .forever: return "Forever".loc
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
    /// Proactively detect meetings (another app is mic-hot) and offer to record.
    /// The *offer* always requires an explicit tap — auto-detect on, auto-record never.
    @Published var autoDetectMeetings: Bool {
        didSet { defaults.set(autoDetectMeetings, forKey: Keys.autoDetectMeetings); notifyChanged() }
    }
    /// Offer to record even when an *unknown* (non-allowlisted) app is on the mic.
    /// Noisier; off by default.
    @Published var offerMeetingForAnyMicApp: Bool {
        didSet { defaults.set(offerMeetingForAnyMicApp, forKey: Keys.offerMeetingForAnyMicApp); notifyChanged() }
    }
    /// Show the live meeting pill under the notch while a recording is in progress.
    @Published var showMeetingPill: Bool {
        didSet { defaults.set(showMeetingPill, forKey: Keys.showMeetingPill); notifyChanged() }
    }
    /// Show the live "subtopic" inside the meeting pill (a sub-feature of the pill).
    @Published var meetingLiveTopic: Bool {
        didSet { defaults.set(meetingLiveTopic, forKey: Keys.meetingLiveTopic); notifyChanged() }
    }
    /// The known-meeting-app allowlist that drives detection. Stored JSON-encoded
    /// (UserDefaults has no array-of-Codable), decoded fault-tolerantly to the seed.
    @Published var meetingAllowlist: [MeetingApp] {
        didSet { defaults.set(AppSettings.encodeAllowlist(meetingAllowlist), forKey: Keys.meetingAllowlist); notifyChanged() }
    }
    /// Bundle ids the user muted (via repeated dismissals); never offered.
    @Published var mutedMeetingApps: [String] {
        didSet { defaults.set(mutedMeetingApps, forKey: Keys.mutedMeetingApps); notifyChanged() }
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
    /// How many days of dictation history to keep before pruning. `0` = forever.
    /// Registered default is 7, so untouched installs behave exactly as before.
    /// A privacy/threat-model choice surfaced as a picker in Settings ▸ Privacy &
    /// Permissions; `AppDelegate` mirrors changes into `HistoryStore` so shrinking
    /// it re-prunes live. See `HistoryRetention` for the offered choices.
    @Published var historyRetentionDays: Int {
        didSet { defaults.set(historyRetentionDays, forKey: Keys.historyRetentionDays) }
    }
    /// One-time consent for learning corrections from your Claude Code prompts (the
    /// AX-blind coding/terminal surface). Tri-state on purpose — `"unset"` until the
    /// first time a scan *would* run, then `"granted"` or `"denied"` for good.
    /// Deliberately NOT a settings row: reading a conversation file is qualitatively
    /// different from watching the field Talkie just pasted into, so a silent default
    /// would betray the trust story — but a permanent toggle would be sprawl. The
    /// one-time HUD offer is the smart default. Additionally gated behind
    /// `learnFromEdits`, so turning edit-learning off disables this too.
    @Published var claudeTranscriptLearning: String {
        didSet { defaults.set(claudeTranscriptLearning, forKey: Keys.claudeTranscriptLearning) }
    }
    /// Experimental: paste the raw transcript the instant you stop, then swap in
    /// the cleaned version once the on-device model finishes — so there's no
    /// visible wait. Off by default: the in-place swap selects backward over the
    /// inserted text, which is unreliable if the caret moved or you kept typing.
    @Published var optimisticInsertion: Bool {
        didSet { defaults.set(optimisticInsertion, forKey: Keys.optimisticInsertion) }
    }
    /// Experimental, off by default: lets a spoken cross-surface request ("email
    /// Sarah the action items from my last meeting") run as a command instead of
    /// being dictated literally. Touches the live command-routing path on every
    /// dictation, so it stays a manual opt-in until it's dogfooded.
    @Published var crossSurfaceCommandsEnabled: Bool {
        didSet { defaults.set(crossSurfaceCommandsEnabled, forKey: Keys.crossSurfaceCommandsEnabled) }
    }
    /// On by default: when a command like "make this a list" has nothing
    /// selected, fall back to treating your last dictation (same app, within
    /// `ImplicitSelectionGate.maxAge`) as the target instead of silently
    /// typing the command out literally. Unlike `crossSurfaceCommandsEnabled`,
    /// this changes nothing about which utterances get matched as commands —
    /// only what happens once a command is already matched and has nowhere to
    /// act — and every use is gated behind an explicit HUD preview before
    /// anything is written, so it's safe to default on.
    @Published var implicitCommandTarget: Bool {
        didSet { defaults.set(implicitCommandTarget, forKey: Keys.implicitCommandTarget) }
    }
    /// Enable the ⌥⌘V shortcut that re-pastes your most recent transcript into the
    /// focused field (and surface it in the pill when a dictation couldn't paste).
    @Published var pasteLastShortcutEnabled: Bool {
        didSet { defaults.set(pasteLastShortcutEnabled, forKey: Keys.pasteLastShortcutEnabled) }
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
    /// The microphone dictation should capture from, by device UID. `nil` means
    /// "Automatic" — resolve the best real input device at the start of each session.
    @Published var preferredInputDeviceUID: String? {
        didSet {
            if let uid = preferredInputDeviceUID, !uid.isEmpty {
                defaults.set(uid, forKey: Keys.preferredInputDeviceUID)
            } else {
                defaults.removeObject(forKey: Keys.preferredInputDeviceUID)
            }
        }
    }
    /// Pause currently-playing media (Apple Music / Spotify, and — with the fallback
    /// on — anything else outputting audio) while you dictate, then resume it.
    @Published var pauseMusicWhileDictating: Bool {
        didSet { defaults.set(pauseMusicWhileDictating, forKey: Keys.pauseMusicWhileDictating) }
    }
    /// When pausing music and no scriptable player (Music/Spotify) was playing, also
    /// nudge the system play/pause key for other apps. Best-effort and blind (can't
    /// read state), so it's off by default; gated on real output activity.
    @Published var pauseMusicMediaKeyFallback: Bool {
        didSet { defaults.set(pauseMusicMediaKeyFallback, forKey: Keys.pauseMusicMediaKeyFallback) }
    }
    /// Show the always-on floating macaw ("Bird Buddy") above every app while Talkie
    /// runs. Posts a change so the app can show/hide it live when toggled.
    @Published var showBirdBuddy: Bool {
        didSet { defaults.set(showBirdBuddy, forKey: Keys.showBirdBuddy); notifyChanged() }
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
            Keys.historyRetentionDays: 7,
            Keys.claudeTranscriptLearning: "unset",
            Keys.optimisticInsertion: true,
            Keys.crossSurfaceCommandsEnabled: false,
            Keys.implicitCommandTarget: true,
            Keys.cleanupLevel: CleanupLevel.medium.rawValue,
            Keys.meetingLanguageMode: "auto",
            Keys.autoDetectMeetings: true,
            Keys.offerMeetingForAnyMicApp: false,
            Keys.showMeetingPill: true,
            Keys.meetingLiveTopic: true,
            Keys.pasteLastShortcutEnabled: true,
            Keys.appAdaptiveCleanup: true,
            Keys.contextAwareness: true,
            Keys.vibeCoding: false,
            Keys.userName: "",
            Keys.hasOnboarded: false,
            Keys.playSounds: true,
            Keys.launchAtLogin: false,
            Keys.pauseMusicWhileDictating: true,
            Keys.showBirdBuddy: true,
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
        historyRetentionDays = d.integer(forKey: Keys.historyRetentionDays)
        claudeTranscriptLearning = d.string(forKey: Keys.claudeTranscriptLearning) ?? "unset"
        optimisticInsertion = d.bool(forKey: Keys.optimisticInsertion)
        crossSurfaceCommandsEnabled = d.bool(forKey: Keys.crossSurfaceCommandsEnabled)
        implicitCommandTarget = d.bool(forKey: Keys.implicitCommandTarget)
        cleanupLevel = CleanupLevel(rawValue: d.string(forKey: Keys.cleanupLevel) ?? "") ?? .medium
        meetingLanguageMode = d.string(forKey: Keys.meetingLanguageMode) ?? "auto"
        autoDetectMeetings = d.bool(forKey: Keys.autoDetectMeetings)
        offerMeetingForAnyMicApp = d.bool(forKey: Keys.offerMeetingForAnyMicApp)
        showMeetingPill = d.bool(forKey: Keys.showMeetingPill)
        meetingLiveTopic = d.bool(forKey: Keys.meetingLiveTopic)
        meetingAllowlist = AppSettings.decodeAllowlist(d.data(forKey: Keys.meetingAllowlist))
        mutedMeetingApps = d.stringArray(forKey: Keys.mutedMeetingApps) ?? []
        pasteLastShortcutEnabled = d.bool(forKey: Keys.pasteLastShortcutEnabled)
        appAdaptiveCleanup = d.bool(forKey: Keys.appAdaptiveCleanup)
        appCleanupStyles = (d.dictionary(forKey: Keys.appCleanupStyles) as? [String: String])
            ?? AppSettings.defaultAppCleanupStyles
        contextAwareness = d.bool(forKey: Keys.contextAwareness)
        vibeCoding = d.bool(forKey: Keys.vibeCoding)
        userName = d.string(forKey: Keys.userName) ?? ""
        hasOnboarded = d.bool(forKey: Keys.hasOnboarded)
        playSounds = d.bool(forKey: Keys.playSounds)
        launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
        preferredInputDeviceUID = d.string(forKey: Keys.preferredInputDeviceUID)
        pauseMusicWhileDictating = d.bool(forKey: Keys.pauseMusicWhileDictating)
        pauseMusicMediaKeyFallback = d.bool(forKey: Keys.pauseMusicMediaKeyFallback)
        showBirdBuddy = d.bool(forKey: Keys.showBirdBuddy)
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

    /// Encode the meeting allowlist for UserDefaults (no array-of-Codable convenience).
    static func encodeAllowlist(_ list: [MeetingApp]) -> Data {
        (try? JSONEncoder().encode(list)) ?? Data()
    }

    /// Decode the stored allowlist, falling back to the built-in seed on any failure
    /// or an empty set, so detection always has apps to match.
    static func decodeAllowlist(_ data: Data?) -> [MeetingApp] {
        guard let data,
              let list = try? JSONDecoder().decode([MeetingApp].self, from: data),
              !list.isEmpty
        else { return MeetingApp.builtInAllowlist }
        return list
    }

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
        static let historyRetentionDays = "historyRetentionDays"
        static let claudeTranscriptLearning = "claudeTranscriptLearning"
        static let optimisticInsertion = "optimisticInsertion"
        static let crossSurfaceCommandsEnabled = "crossSurfaceCommandsEnabled"
        static let implicitCommandTarget = "implicitCommandTarget"
        static let cleanupLevel = "cleanupLevel"
        static let meetingLanguageMode = "meetingLanguageMode"
        static let autoDetectMeetings = "autoDetectMeetings"
        static let offerMeetingForAnyMicApp = "offerMeetingForAnyMicApp"
        static let showMeetingPill = "showMeetingPill"
        static let meetingLiveTopic = "meetingLiveTopic"
        static let meetingAllowlist = "meetingAllowlist"
        static let mutedMeetingApps = "mutedMeetingApps"
        static let pasteLastShortcutEnabled = "pasteLastShortcutEnabled"
        static let appAdaptiveCleanup = "appAdaptiveCleanup"
        static let appCleanupStyles = "appCleanupStyles"
        static let contextAwareness = "contextAwareness"
        static let vibeCoding = "vibeCoding"
        static let userName = "userName"
        static let hasOnboarded = "hasOnboarded"
        static let playSounds = "playSounds"
        static let launchAtLogin = "launchAtLogin"
        static let preferredInputDeviceUID = "preferredInputDeviceUID"
        static let pauseMusicWhileDictating = "pauseMusicWhileDictating"
        static let pauseMusicMediaKeyFallback = "pauseMusicMediaKeyFallback"
        static let showBirdBuddy = "showBirdBuddy"
    }
}
