import Foundation

// MARK: - Setup by your AI agent (MCP `update_settings`)
//
// The user's AI agent can set Talkie up through the bundled MCP server: their name,
// the bird's name, the app language, the languages they speak and the look. Like
// every MCP write it arrives as one queued suggestion in the inbox
// (`DictionaryInbox`), is applied visibly with an Undo pill, and only through the
// same setters the Settings pages use. Everything decidable is here and pure:
// which values are accepted (anything Talkie doesn't support is dropped, never
// guessed), and what the pill says.

/// The settings an agent may change, as they travel in the inbox file. Every field
/// optional: absent = leave as is.
///
/// MIRROR: `Sources/TalkieMCP/TalkieStore.swift` → `SettingsMirror`. Any field change
/// here MUST be applied there in the same commit (mirror-don't-import).
struct AgentSettingsChange: Codable, Equatable, Sendable {
    var userName: String?
    var assistantName: String?
    /// An app (interface) language code ("de", "pt-BR"…) or "system" for the Mac's.
    var appLanguage: String?
    /// Spoken languages, primary first, as catalog ids ("en-US", "de-DE"…).
    var spokenLanguages: [String]?
    /// `TalkieAccent` raw value.
    var accent: String?
    /// `TalkieBackdropStyle` raw value.
    var backdrop: String?
    /// `TalkieAppearanceMode` raw value: "system", "light" or "dark".
    var appearance: String?
}

/// The interface languages Talkie ships, and how the per-app choice is stored:
/// macOS reads `AppleLanguages` from the app's own defaults at launch (the same key
/// System Settings ▸ Language & Region ▸ Applications writes), so a change applies
/// the next time Talkie starts.
enum AppLanguage {
    /// The shipped localisations, in the order the picker shows them.
    static let supported: [String] = ["en", "de", "fr", "es", "it", "pt-BR", "nl", "ja", "ko", "zh-Hans"]
    /// The value meaning "follow the Mac".
    static let system = "system"
    static let key = "AppleLanguages"

    /// The language's own name for itself ("Deutsch", "日本語").
    static func displayName(_ code: String) -> String {
        if code == system { return "Match the Mac".loc }
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code)?.localizedCapitalized ?? code
    }

    /// A supported code for `raw`, or nil. Accepts any case and "_" or "-", and a
    /// bare language for a regional one ("pt" → "pt-BR", "zh" → "zh-Hans").
    static func normalized(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        if cleaned.lowercased() == system { return system }
        if let exact = supported.first(where: { $0.lowercased() == cleaned.lowercased() }) { return exact }
        let lang = cleaned.split(separator: "-").first.map { $0.lowercased() } ?? ""
        return supported.first { $0.split(separator: "-").first.map { $0.lowercased() } == lang }
    }

    /// The app's own choice (not the Mac's): a supported code, or `system`.
    static func current(in defaults: UserDefaults = .standard) -> String {
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) }
        guard let list = domain?[key] as? [String], let first = list.first,
              let code = normalized(first) else { return system }
        return code
    }

    /// Store the choice; Talkie shows it from its next launch.
    static func set(_ code: String, in defaults: UserDefaults = .standard) {
        if code == system { defaults.removeObject(forKey: key) } else { defaults.set([code], forKey: key) }
    }

    /// The language Talkie is showing right now (what the bundle resolved at launch).
    static var showing: String {
        Bundle.main.preferredLocalizations.first.flatMap(normalized) ?? "en"
    }
}

/// A validated `AgentSettingsChange`: only values Talkie supports, ready to apply.
struct AgentSettingsPlan: Equatable, Sendable {
    var userName: String?
    var assistantName: String?
    var appLanguage: String?
    var spokenLanguages: [String]?
    var accent: TalkieAccent?
    var backdrop: TalkieBackdropStyle?
    var appearance: TalkieAppearanceMode?

    var isEmpty: Bool {
        userName == nil && assistantName == nil && appLanguage == nil && spokenLanguages == nil
            && accent == nil && backdrop == nil && appearance == nil
    }
}

enum AgentSetup {
    static let maxNameLength = 40

    /// Keep what Talkie supports; drop the rest. Names are trimmed and capped (an
    /// empty name clears it); languages must be catalog languages (region optional,
    /// de-duplicated, order kept, at least one); look values must be known cases.
    @MainActor
    static func plan(_ change: AgentSettingsChange) -> AgentSettingsPlan {
        var plan = AgentSettingsPlan()
        if let raw = change.userName {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.count <= maxNameLength, !name.contains(where: \.isNewline) { plan.userName = name }
        }
        if let raw = change.assistantName {
            let name = AppSettings.normalizedParrotName(raw)
            if !raw.contains(where: \.isNewline) { plan.assistantName = name }
        }
        if let raw = change.appLanguage { plan.appLanguage = AppLanguage.normalized(raw) }
        if let raw = change.spokenLanguages {
            var seen = Set<String>()
            let ids = raw.compactMap(catalogLanguage).filter { seen.insert($0).inserted }
            if !ids.isEmpty { plan.spokenLanguages = ids }
        }
        plan.accent = change.accent.flatMap { TalkieAccent(rawValue: $0.lowercased()) }
        plan.backdrop = change.backdrop.flatMap { TalkieBackdropStyle(rawValue: $0.lowercased()) }
        plan.appearance = change.appearance.flatMap { TalkieAppearanceMode(rawValue: $0.lowercased()) }
        return plan
    }

    /// A catalog language id for "de-DE", "de_DE", "de" or "German"; nil if Talkie
    /// doesn't offer it.
    static func catalogLanguage(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if let byName = talkieLanguageCatalog.first(where: {
            $0.name.caseInsensitiveCompare(cleaned) == .orderedSame
                || $0.shortName.caseInsensitiveCompare(cleaned) == .orderedSame
        }) { return byName.id }
        let id = canonicalLocaleID(cleaned.replacingOccurrences(of: "_", with: "-"))
        return talkieLanguageCatalog.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.id
    }

    /// The plan minus what is already set, so a repeat call is a silent no-op.
    static func changes(_ plan: AgentSettingsPlan, from current: AgentSettingsPlan) -> AgentSettingsPlan {
        var out = AgentSettingsPlan()
        if let v = plan.userName, v != current.userName { out.userName = v }
        if let v = plan.assistantName, v != current.assistantName { out.assistantName = v }
        if let v = plan.appLanguage, v != current.appLanguage { out.appLanguage = v }
        if let v = plan.spokenLanguages, v != current.spokenLanguages { out.spokenLanguages = v }
        if let v = plan.accent, v != current.accent { out.accent = v }
        if let v = plan.backdrop, v != current.backdrop { out.backdrop = v }
        if let v = plan.appearance, v != current.appearance { out.appearance = v }
        return out
    }

    /// The pill's list of what changed, in the user's language ("your name, languages").
    static func summary(of plan: AgentSettingsPlan) -> String {
        var parts: [String] = []
        if plan.userName != nil { parts.append("your name".loc) }
        if plan.assistantName != nil { parts.append("the bird's name".loc) }
        if plan.spokenLanguages != nil { parts.append("the languages you speak".loc) }
        if plan.appLanguage != nil { parts.append("the app language".loc) }
        if plan.accent != nil || plan.backdrop != nil || plan.appearance != nil { parts.append("the look".loc) }
        return ListFormatter.localizedString(byJoining: parts)
    }

    /// What Undo puts back: the previous value of every field `delta` changes. A
    /// backdrop change also restores the accent it brought along.
    static func undoPlan(for delta: AgentSettingsPlan, before: AgentSettingsPlan) -> AgentSettingsPlan {
        var out = AgentSettingsPlan()
        if delta.userName != nil { out.userName = before.userName }
        if delta.assistantName != nil { out.assistantName = before.assistantName }
        if delta.appLanguage != nil { out.appLanguage = before.appLanguage }
        if delta.spokenLanguages != nil { out.spokenLanguages = before.spokenLanguages }
        if delta.backdrop != nil { out.backdrop = before.backdrop; out.accent = before.accent }
        if delta.accent != nil { out.accent = before.accent }
        if delta.appearance != nil { out.appearance = before.appearance }
        return out
    }

    // MARK: Apply

    /// The current values, as a plan (what `changes` compares against and Undo restores).
    @MainActor
    static func snapshot(settings: AppSettings, appearance: AppearanceStore,
                         defaults: UserDefaults = .standard) -> AgentSettingsPlan {
        AgentSettingsPlan(userName: settings.userName, assistantName: settings.parrotName,
                          appLanguage: AppLanguage.current(in: defaults),
                          spokenLanguages: settings.spokenLanguages,
                          accent: appearance.look.accent, backdrop: appearance.look.backdrop,
                          appearance: appearance.look.mode)
    }

    /// Apply a plan through the same setters the Settings pages use. A backdrop
    /// without an accent brings its own accent, as choosing it in Settings does.
    @MainActor
    static func apply(_ plan: AgentSettingsPlan, settings: AppSettings, appearance: AppearanceStore,
                      defaults: UserDefaults = .standard) {
        if let v = plan.userName { settings.userName = v }
        if let v = plan.assistantName { settings.parrotName = v }
        if let v = plan.spokenLanguages { settings.spokenLanguages = v }
        if let v = plan.appLanguage { AppLanguage.set(v, in: defaults) }
        if plan.accent != nil || plan.backdrop != nil || plan.appearance != nil {
            appearance.update { look in
                if let b = plan.backdrop { look.backdrop = b; look.accent = b.accent }
                if let a = plan.accent { look.accent = a }
                if let m = plan.appearance { look.mode = m }
            }
        }
    }
}
