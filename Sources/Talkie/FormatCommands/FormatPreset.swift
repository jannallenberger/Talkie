import Foundation

/// "Format while you dictate": the formats a spoken command can switch the following
/// speech into. Hold the command key during a dictation, say one of a preset's phrases
/// (German or English), let go — everything you say after that is pasted in this
/// format until the mode ends.
///
/// The first nine are deterministic and instant (`FormatRenderer`); the last five
/// need the on-device model (`FormatModelPass`) and are marked as slower in the UI.
enum FormatPreset: String, CaseIterable, Sendable, Equatable, Identifiable {
    case bulletList
    case numberedList
    case todoList
    case allCaps
    case lowercase
    case quotes
    case parentheses
    case heading
    case verbatim
    case email
    case formal
    case shorter
    case translateToEnglish
    case translateToGerman

    var id: String { rawValue }

    /// Needs the on-device language model (slower; may be unavailable).
    var usesModel: Bool {
        switch self {
        case .email, .formal, .shorter, .translateToEnglish, .translateToGerman: return true
        default: return false
        }
    }

    /// List presets split their region into items (by pauses and sentences).
    var isList: Bool {
        self == .bulletList || self == .numberedList || self == .todoList
    }

    /// Block formats sit on their own lines in the pasted text; inline formats flow
    /// with the sentence around them.
    var isBlock: Bool {
        switch self {
        case .bulletList, .numberedList, .todoList, .heading, .email: return true
        default: return false
        }
    }

    /// The name shown in the pill chip and the Commands page (English source; `.loc`).
    var displayName: String {
        switch self {
        case .bulletList: return "Bullet list".loc
        case .numberedList: return "Numbered list".loc
        case .todoList: return "To-do list".loc
        case .allCaps: return "ALL CAPS".loc
        case .lowercase: return "lowercase".loc
        case .quotes: return "In quotation marks".loc
        case .parentheses: return "In parentheses".loc
        case .heading: return "Heading".loc
        case .verbatim: return "Verbatim / code".loc
        case .email: return "As an e-mail".loc
        case .formal: return "Formal".loc
        case .shorter: return "Shorter".loc
        case .translateToEnglish: return "Translate to English".loc
        case .translateToGerman: return "Translate to German".loc
        }
    }

    /// What to say, German / English (kept for callers that want just these two).
    var germanPhrases: [String] { FormatPhrases.phrases(self, language: "de") }
    var englishPhrases: [String] { FormatPhrases.phrases(self, language: "en") }

    /// Every built-in phrase, every transcription language.
    var allPhrases: [String] { FormatPhrases.allPhrases(self) }

    /// The phrase to show in the UI language (its own table when there is one,
    /// otherwise English). Every language's phrases always work, whatever is shown.
    func shownPhrase(uiLanguageCode: String?) -> String {
        let lang = FormatPhrases.language(of: uiLanguageCode) ?? "en"
        return FormatPhrases.phrases(self, language: lang).first ?? englishPhrases[0]
    }

    /// A tiny before → after example for the Commands page (English source; `.loc`).
    var example: (before: String, after: String) {
        switch self {
        case .bulletList: return ("milk … eggs … bread".loc, "- Milk\n- Eggs\n- Bread".loc)
        case .numberedList: return ("call Anna … send the file".loc, "1. Call Anna\n2. Send the file".loc)
        case .todoList: return ("book the room … order lunch".loc, "- [ ] Book the room\n- [ ] Order lunch".loc)
        case .allCaps: return ("this is urgent".loc, "THIS IS URGENT".loc)
        case .lowercase: return ("Read Me".loc, "read me".loc)
        case .quotes: return ("less is more".loc, "\u{201C}less is more\u{201D}".loc)
        case .parentheses: return ("see below".loc, "(see below)".loc)
        case .heading: return ("next steps".loc, "# Next steps".loc)
        case .verbatim: return ("git status", "`git status`")
        case .email: return ("thanks for the call …".loc, "Hi,\n\nThanks for the call …\n\nBest regards".loc)
        case .formal: return ("can you send it".loc, "Could you please send it?".loc)
        case .shorter: return ("a long ramble".loc, "one tight sentence".loc)
        case .translateToEnglish: return ("Wir sehen uns morgen", "See you tomorrow")
        case .translateToGerman: return ("See you tomorrow", "Wir sehen uns morgen")
        }
    }
}

/// What one spoken command span means.
enum FormatCommand: Equatable, Sendable {
    /// Switch the following speech into this format (replacing any active one).
    case apply(FormatPreset)
    /// A user-made command: format what follows, or insert its fixed text.
    case user(UserCommand)
    /// Back to normal text ("normal", "Ende", …).
    case end

    /// The name to show for it (pill chip, conflict messages).
    var displayName: String {
        switch self {
        case .apply(let p): return p.displayName
        case .user(let c): return c.name
        case .end: return "Back to normal text".loc
        }
    }

    /// Phrases that end the active format.
    static var germanEndPhrases: [String] { FormatPhrases.endPhrases(language: "de") }
    static var englishEndPhrases: [String] { FormatPhrases.endPhrases(language: "en") }
}
