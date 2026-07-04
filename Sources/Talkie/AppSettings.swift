import Foundation

/// Which key activates dictation. Hold-to-talk uses a modifier so a plain hold
/// doesn't leak keystrokes into the focused app; toggle mode uses a chord.
enum ActivationKey: String, CaseIterable, Codable, Identifiable {
    case rightOption
    case leftOption
    case rightControl
    // NOTE: Fn/Globe was removed — macOS reserves it for "Change Input Source"
    // (language switch), so it can't be cleanly used as a hold-to-talk key.
    // Alternative HID triggers: a mouse's two side buttons (button 4/5). Anything
    // that reaches macOS as one of these physical buttons — many foot pedals and
    // accessibility switches do — can drive the same gesture family (B7). These
    // are NOT modifiers, so they take the mouse-event path in `HotKeyMonitor`.
    case mouseButton4
    case mouseButton5

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightOption: return "Right ⌥ Option".loc
        case .leftOption: return "Left ⌥ Option".loc
        case .rightControl: return "Right ⌃ Control".loc
        case .mouseButton4: return "Mouse Button 4 (side)".loc
        case .mouseButton5: return "Mouse Button 5 (side)".loc
        }
    }

    /// True when this trigger is a mouse side button rather than a keyboard
    /// modifier — the two use disjoint event paths in `HotKeyMonitor` (a keyboard
    /// key ignores mouse events and a mouse button ignores `flagsChanged`).
    var isMouseButton: Bool {
        switch self {
        case .mouseButton4, .mouseButton5: return true
        case .rightOption, .leftOption, .rightControl: return false
        }
    }

    /// SF Symbol used to render this trigger as a glyph in the picker row and the
    /// onboarding keycap. `nil` for keyboard modifiers (their `displayName` already
    /// carries the ⌥/⌃ glyph); the mouse buttons get a mouse symbol since there's
    /// no single character for "side button".
    var symbolName: String? {
        isMouseButton ? "computermouse" : nil
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
        case .mouseButton4, .mouseButton5:
            // A mouse side button isn't a keyboard modifier, so no keyboard chord
            // can collide with it — default to ⌃⌘V (Control is the tidier pairing).
            return PasteShortcut(secondary: .control, display: "⌃⌘V")
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
    /// Show the live meeting pill under the notch while a recording is in progress.
    /// H1 folded the separate "show the live topic" toggle into this one — the pill is
    /// where the live topic and chapters surface, so a single switch governs all of it.
    @Published var showMeetingPill: Bool {
        didSet { defaults.set(showMeetingPill, forKey: Keys.showMeetingPill); notifyChanged() }
    }
    /// Keep each recorded meeting's raw audio in ~/Talkie Meetings/ (D9), so clicking
    /// a transcript line plays that exact moment. Default **OFF**: retaining raw call
    /// audio is a real privacy + disk decision (~30 MB/hour per captured stream), so
    /// it's an explicit opt-in, and it's snapshotted at recording START (not read live),
    /// so flipping it mid-call never changes what a recording already committed to.
    /// Never applies to dictation, whose audio is deliberately ephemeral.
    @Published var keepMeetingAudio: Bool {
        didSet { defaults.set(keepMeetingAudio, forKey: Keys.keepMeetingAudio); notifyChanged() }
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
    /// visible wait. Off by default (H1 flipped the registered default to match this
    /// doc and the "Experimental — may misfire" UI label): the in-place swap selects
    /// backward over the inserted text, which is unreliable if the caret moved or you
    /// kept typing. A user who explicitly enabled it keeps their stored `true`.
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
    /// Per-app-category cleanup *style* — Talkie's single cleanup model. Maps
    /// AppCategory.rawValue → CleanupStyle.rawValue; the resolved style is the
    /// whole story (its own intensity + tone), fed to the pipeline, the per-app
    /// editor, and the HUD. There is no separate intensity level or adaptive
    /// master toggle any more (H2).
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
    /// Project roots the user declined the one-tap "Index 〈Repo〉 filenames?" offer
    /// for (A9). Sticky per root so a decline is honored forever — we never re-offer
    /// the same repo. Hidden state only (no settings row); the manual Vibe Coding
    /// toggle + folder picker remain the visible override.
    @Published var declinedVibeRoots: [String] {
        didSet { defaults.set(declinedVibeRoots, forKey: Keys.declinedVibeRoots) }
    }
    /// Unix time of the most recent Vibe Coding offer, so we show at most one a day
    /// and never nag. Hidden state only. `0` means "never offered".
    @Published var lastVibeOfferUnix: Double {
        didSet { defaults.set(lastVibeOfferUnix, forKey: Keys.lastVibeOfferUnix) }
    }
    /// What Talkie calls you (set during onboarding; shown on the dashboard).
    @Published var userName: String {
        didSet { defaults.set(userName, forKey: Keys.userName) }
    }
    /// K6 — the optional name for the bird itself (default `""` — unnamed). When
    /// set it personalizes the learned ping ("Kiwi learned …") and, later, Wrapped
    /// narration. Purely cosmetic: an empty name changes nothing, so this is not a
    /// behavioral toggle. The setter normalizes on the way in — whitespace-trimmed
    /// and capped at `parrotNameMaxLength` characters — so the HUD/dashboard pill
    /// can never be blown out by a pasted essay, and every reader (ping, Wrapped)
    /// sees the same clean value without re-trimming. Privacy: this is personal
    /// data, so it is deliberately absent from the diagnostic bundle's whitelist
    /// (`BugBundle.Environment`) and must never be baked into an exported/shared
    /// artifact by default.
    @Published var parrotName: String {
        didSet {
            let clean = AppSettings.normalizedParrotName(parrotName)
            if clean != parrotName {
                // Re-entrant assignment runs didSet again, but `clean` is a fixed
                // point of the normalizer, so it settles after one bounce.
                parrotName = clean
                return
            }
            defaults.set(parrotName, forKey: Keys.parrotName)
        }
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
    /// Pause currently-playing media while you dictate, then resume it. Covers
    /// scriptable players (Apple Music / Spotify) directly, and — since H1 removed the
    /// separate opt-in — also nudges the system play/pause key for anything else that's
    /// actually outputting audio (browsers, podcasts). The media-key nudge is gated on
    /// real output activity in `MusicController.pauseForDictation`, so it never fires
    /// blindly.
    @Published var pauseMusicWhileDictating: Bool {
        didSet { defaults.set(pauseMusicWhileDictating, forKey: Keys.pauseMusicWhileDictating) }
    }
    /// Show the always-on floating macaw ("Bird Buddy") above every app while Talkie
    /// runs. Posts a change so the app can show/hide it live when toggled.
    @Published var showBirdBuddy: Bool {
        didSet { defaults.set(showBirdBuddy, forKey: Keys.showBirdBuddy); notifyChanged() }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .talkieSettingsChanged, object: nil)
    }

    /// The persisted "Keep audio with meeting notes" choice, read straight from the
    /// standard store (the same one the `@Published keepMeetingAudio` writes to). Exposed
    /// as a `nonisolated static` so `MeetingRecorder.start()` can snapshot it at recording
    /// START without an injected closure — the recorder is composed by AppDelegate, but
    /// this one privacy-gated flag is read directly (mirroring how `InboxWatchPreferences`
    /// / `ExportPreferences` singletons are read at their point of use) so the concurrent
    /// AppDelegate work stays untouched. Defaults to `false` (an unset key reads false),
    /// matching the registered default — meetings keep NO audio unless the user opts in.
    nonisolated static var keepMeetingAudioEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.keepMeetingAudio)
    }

    // MARK: - Vibe Coding in-context offer (A9)

    /// Whether the one-tap "Index 〈Repo〉 filenames?" offer may be shown for `root`
    /// right now: vibe coding is still off, this exact root was never declined, and
    /// we haven't already offered today. Pure decision — `now` is injected so the
    /// throttle is testable. The caller has already resolved `root` to a real git
    /// working copy via `ProjectRootDetector`.
    func mayOfferVibeIndexing(forRoot root: String, now: Date = Date()) -> Bool {
        guard !vibeCoding else { return false }
        guard !declinedVibeRoots.contains(root) else { return false }
        // At most one offer per calendar day-ish window (24h), so a burst of coding
        // dictations can't turn into a pile of pills.
        if lastVibeOfferUnix > 0,
           now.timeIntervalSince1970 - lastVibeOfferUnix < 24 * 60 * 60 {
            return false
        }
        return true
    }

    /// Record that an offer was just shown (starts the once-a-day throttle).
    func noteVibeOfferShown(now: Date = Date()) {
        lastVibeOfferUnix = now.timeIntervalSince1970
    }

    /// Remember that the user declined the offer for `root` — never re-offer it.
    func declineVibeRoot(_ root: String) {
        guard !declinedVibeRoots.contains(root) else { return }
        declinedVibeRoots.append(root)
    }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Keys.activationKey: ActivationKey.rightOption.rawValue,
            Keys.localeIdentifier: canonicalLocaleID(Locale.current.identifier),
            Keys.learnFromEdits: true,
            Keys.historyRetentionDays: 7,
            Keys.claudeTranscriptLearning: "unset",
            // H1 resolved the optimisticInsertion contradiction: registered default is
            // now `false`, matching the doc comment and the "Experimental — may misfire"
            // label. Anyone who had explicitly turned it on keeps their stored `true`.
            Keys.optimisticInsertion: false,
            Keys.crossSurfaceCommandsEnabled: false,
            Keys.meetingLanguageMode: "auto",
            Keys.autoDetectMeetings: true,
            Keys.showMeetingPill: true,
            Keys.keepMeetingAudio: false,
            Keys.contextAwareness: true,
            Keys.vibeCoding: false,
            Keys.lastVibeOfferUnix: 0.0,
            Keys.userName: "",
            Keys.parrotName: "",
            Keys.hasOnboarded: false,
            Keys.playSounds: true,
            Keys.launchAtLogin: false,
            Keys.pauseMusicWhileDictating: true,
            Keys.showBirdBuddy: true,
        ])
        activationKey = ActivationKey(rawValue: d.string(forKey: Keys.activationKey) ?? "") ?? .rightOption
        // B4 migration: the Hold/Toggle Mode picker is gone — every user now gets the
        // one gesture family (hold to talk, tap twice to lock, tap to stop), so there
        // is no mode to persist. Silently drop the stale scalar so it doesn't linger
        // in the plist; the old `ActivationMode` enum is deleted outright.
        d.removeObject(forKey: Keys.activationMode)
        // B2 migration: the global "Insert text by" control is gone — paste is now the
        // universal default and any app that needs typing learns it per-bundle (or the
        // user sets it in the per-app rule sheet). Silently drop the stale scalar so it
        // doesn't linger in the plist; `InsertionMode` survives as an internal enum.
        d.removeObject(forKey: Keys.insertionMode)
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
        // H2 migration: the parallel cleanup *intensity level* and the adaptive
        // master toggle are gone — the per-category *style* is now Talkie's only
        // cleanup model. A user who had "Adapt the style to the app" OFF was on the
        // level path; fold their chosen level into a style and stamp it across every
        // category once, so their cleanup keeps behaving the way it did (High →
        // Concise everywhere, Medium → Neutral, Light → Faithful, None → Off). Then
        // drop both legacy keys so they can't linger. Adaptive-ON users (the default)
        // already resolved by style, so they migrate to nothing and see no change.
        AppSettings.migrateLevelToStyleIfNeeded(d)
        learnFromEdits = d.bool(forKey: Keys.learnFromEdits)
        historyRetentionDays = d.integer(forKey: Keys.historyRetentionDays)
        claudeTranscriptLearning = d.string(forKey: Keys.claudeTranscriptLearning) ?? "unset"
        optimisticInsertion = d.bool(forKey: Keys.optimisticInsertion)
        crossSurfaceCommandsEnabled = d.bool(forKey: Keys.crossSurfaceCommandsEnabled)
        meetingLanguageMode = d.string(forKey: Keys.meetingLanguageMode) ?? "auto"
        autoDetectMeetings = d.bool(forKey: Keys.autoDetectMeetings)
        showMeetingPill = d.bool(forKey: Keys.showMeetingPill)
        keepMeetingAudio = d.bool(forKey: Keys.keepMeetingAudio)
        meetingAllowlist = AppSettings.decodeAllowlist(d.data(forKey: Keys.meetingAllowlist))
        mutedMeetingApps = d.stringArray(forKey: Keys.mutedMeetingApps) ?? []
        appCleanupStyles = (d.dictionary(forKey: Keys.appCleanupStyles) as? [String: String])
            ?? AppSettings.defaultAppCleanupStyles
        contextAwareness = d.bool(forKey: Keys.contextAwareness)
        vibeCoding = d.bool(forKey: Keys.vibeCoding)
        declinedVibeRoots = d.stringArray(forKey: Keys.declinedVibeRoots) ?? []
        lastVibeOfferUnix = d.double(forKey: Keys.lastVibeOfferUnix)
        userName = d.string(forKey: Keys.userName) ?? ""
        // Normalize on load too, so a value written by an older build (or edited in
        // the plist by hand) can't smuggle in whitespace or an over-long name.
        parrotName = AppSettings.normalizedParrotName(d.string(forKey: Keys.parrotName) ?? "")
        hasOnboarded = d.bool(forKey: Keys.hasOnboarded)
        playSounds = d.bool(forKey: Keys.playSounds)
        launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
        preferredInputDeviceUID = d.string(forKey: Keys.preferredInputDeviceUID)
        pauseMusicWhileDictating = d.bool(forKey: Keys.pauseMusicWhileDictating)
        showBirdBuddy = d.bool(forKey: Keys.showBirdBuddy)
        // H1: drop the four toggle-sweep keys from the plist so nothing stale lingers.
        // Their behaviors are now unconditional-by-construction (see the property
        // deletions above); leaving orphaned values would be harmless but untidy.
        AppSettings.removeSweptToggleKeys(d)
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

    /// K6 — the longest a parrot name may be. Chosen to keep the learned-ping pill
    /// and the dashboard header on one line even in the widest scripts; a pasted
    /// paragraph is silently clipped rather than allowed to blow out the layout.
    static let parrotNameMaxLength = 24

    /// Normalize a raw parrot name into the stored form: whitespace/newlines
    /// trimmed off both ends, then clipped to `parrotNameMaxLength` characters
    /// (by grapheme cluster, so an emoji or accented letter counts as one). Pure
    /// and idempotent — `normalized(normalized(x)) == normalized(x)` — which the
    /// `didSet` re-entrancy guard relies on. Kept static so it is unit-testable
    /// without an `AppSettings` instance.
    static func normalizedParrotName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > parrotNameMaxLength else { return trimmed }
        return String(trimmed.prefix(parrotNameMaxLength))
    }

    /// The cleanup style for an app category (user override, else default).
    func cleanupStyle(for category: AppCategory) -> CleanupStyle {
        if let raw = appCleanupStyles[category.rawValue], let style = CleanupStyle(rawValue: raw) {
            return style
        }
        return AppSettings.defaultAppCleanupStyles[category.rawValue]
            .flatMap(CleanupStyle.init) ?? .neutral
    }

    /// The style a legacy cleanup *intensity level* folds into, now that style is
    /// the only cleanup model: `none → off`, `light → faithful`, `medium → neutral`,
    /// `high → concise`. Kept as a pure static so the migration is unit-testable.
    static func migratedStyle(forLegacyLevel level: String) -> CleanupStyle {
        switch level {
        case "none":   return .off
        case "light":  return .faithful
        case "medium": return .neutral
        case "high":   return .concise
        default:       return .neutral   // matches the old level default (medium)
        }
    }

    /// H2 one-time migration (see the call site in `init`). A user who had the
    /// adaptive master toggle OFF was driven by a single global intensity *level*
    /// applied to every app; fold that level into the equivalent *style* and stamp
    /// it across every category so their cleanup keeps behaving the same. Then drop
    /// all four now-deleted keys so nothing stale lingers in the plist. Idempotent:
    /// once the legacy keys are gone this does nothing.
    static func migrateLevelToStyleIfNeeded(_ d: UserDefaults) {
        // Only stamp categories when the user was actually on the level path
        // (adaptive OFF). `object(forKey:)` distinguishes "never set" from "false".
        if d.object(forKey: Keys.appAdaptiveCleanup) != nil, d.bool(forKey: Keys.appAdaptiveCleanup) == false {
            let level = d.string(forKey: Keys.cleanupLevel) ?? "medium"
            let style = migratedStyle(forLegacyLevel: level).rawValue
            var styles = (d.dictionary(forKey: Keys.appCleanupStyles) as? [String: String])
                ?? AppSettings.defaultAppCleanupStyles
            for category in AppCategory.allCases { styles[category.rawValue] = style }
            d.set(styles, forKey: Keys.appCleanupStyles)
        }
        // Drop every control this feature deleted (both level-path keys and the two
        // Basic-cleanup toggles) so they can't resurface. Users who had disabled
        // capitalization or filler-stripping now get the always-on smart defaults.
        d.removeObject(forKey: Keys.cleanupLevel)
        d.removeObject(forKey: Keys.appAdaptiveCleanup)
        d.removeObject(forKey: Keys.autoCapitalize)
        d.removeObject(forKey: Keys.cleanupFillers)
    }

    /// H1 "great toggle sweep" cleanup: the re-paste, implicit-command-target,
    /// media-key-fallback, and live-topic toggles were deleted because each was
    /// safe-by-construction or folded into another switch. Drop their stored values so
    /// they don't linger orphaned in the plist. No migration of intent is needed — the
    /// behaviors are now always-on (or, for the live topic, governed by `showMeetingPill`).
    /// Idempotent: once the keys are gone this does nothing.
    static func removeSweptToggleKeys(_ d: UserDefaults) {
        d.removeObject(forKey: Keys.implicitCommandTarget)
        d.removeObject(forKey: Keys.pasteLastShortcutEnabled)
        d.removeObject(forKey: Keys.pauseMusicMediaKeyFallback)
        d.removeObject(forKey: Keys.meetingLiveTopic)
    }

    private enum Keys {
        static let activationKey = "activationKey"
        /// Legacy key — the Hold/Toggle Mode picker was removed in B4 (one unified
        /// gesture family). Retained only so `init` can `removeObject` the stale
        /// value from existing installs.
        static let activationMode = "activationMode"
        /// Legacy key — the global insertion-mode control was removed in B2. Retained
        /// only so `init` can `removeObject` the stale value from existing installs.
        static let insertionMode = "insertionMode"
        static let localeIdentifier = "localeIdentifier"
        static let spokenLanguages = "spokenLanguages"
        /// Legacy key — the "Capitalize the first letter" toggle was removed in H2
        /// (capitalization is now an always-on smart default). Retained only so the
        /// H2 migration can `removeObject` the stale value from existing installs.
        static let autoCapitalize = "autoCapitalize"
        /// Legacy key — the "Remove filler words" toggle was removed in H2 (filler
        /// stripping is now always-on when the AI didn't already do it). Retained only
        /// so the H2 migration can `removeObject` the stale value.
        static let cleanupFillers = "cleanupFillers"
        static let learnFromEdits = "learnFromEdits"
        static let historyRetentionDays = "historyRetentionDays"
        static let claudeTranscriptLearning = "claudeTranscriptLearning"
        static let optimisticInsertion = "optimisticInsertion"
        static let crossSurfaceCommandsEnabled = "crossSurfaceCommandsEnabled"
        /// Legacy key — the "let commands target your last dictation" toggle was removed
        /// in H1 (the implicit-selection fallback is now always on, still bounded by
        /// `ImplicitSelectionGate` + an HUD preview). Retained only so `init` can
        /// `removeObject` the stale value from existing installs.
        static let implicitCommandTarget = "implicitCommandTarget"
        /// Legacy key — the cleanup *intensity level* was removed in H2 (per-category
        /// style is the only cleanup model). Retained only so the H2 migration can read
        /// it to fold the old level into a style, then `removeObject` it.
        static let cleanupLevel = "cleanupLevel"
        static let meetingLanguageMode = "meetingLanguageMode"
        static let autoDetectMeetings = "autoDetectMeetings"
        static let showMeetingPill = "showMeetingPill"
        /// Legacy key — the standalone "show the live topic" toggle was folded into
        /// `showMeetingPill` in H1 (one switch governs the pill and its live-topic
        /// display). Chapters are NOT governed by it: D8 decoupled chapter computation
        /// from the pill (chapters are a saved-notes artifact, produced on every
        /// recording). Retained only so `init` can `removeObject` the stale value.
        static let meetingLiveTopic = "meetingLiveTopic"
        static let keepMeetingAudio = "keepMeetingAudio"
        static let meetingAllowlist = "meetingAllowlist"
        static let mutedMeetingApps = "mutedMeetingApps"
        /// Legacy key — the re-paste enable/disable toggle was removed in H1 (the chord
        /// is collision-proof by construction, so it's always live). Retained only so
        /// `init` can `removeObject` the stale value from existing installs.
        static let pasteLastShortcutEnabled = "pasteLastShortcutEnabled"
        /// Legacy key — the "Adapt the style to the app" master toggle was removed in
        /// H2 (per-category style is always the active path). Retained only so the H2
        /// migration can read it (adaptive OFF → fold the old level into a style) and
        /// then `removeObject` it.
        static let appAdaptiveCleanup = "appAdaptiveCleanup"
        static let appCleanupStyles = "appCleanupStyles"
        static let contextAwareness = "contextAwareness"
        static let vibeCoding = "vibeCoding"
        static let declinedVibeRoots = "declinedVibeRoots"
        static let lastVibeOfferUnix = "lastVibeOfferUnix"
        static let userName = "userName"
        static let parrotName = "parrotName"
        static let hasOnboarded = "hasOnboarded"
        static let playSounds = "playSounds"
        static let launchAtLogin = "launchAtLogin"
        static let preferredInputDeviceUID = "preferredInputDeviceUID"
        static let pauseMusicWhileDictating = "pauseMusicWhileDictating"
        /// Legacy key — the "also pause other apps" sub-toggle was removed in H1 (the
        /// media-key fallback is now always allowed, gated on real output activity in
        /// `MusicController`). Retained only so `init` can `removeObject` the stale value.
        static let pauseMusicMediaKeyFallback = "pauseMusicMediaKeyFallback"
        static let showBirdBuddy = "showBirdBuddy"
    }
}
