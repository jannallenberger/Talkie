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

    /// What to say, German. The first entry is the one shown in the UI; the rest are
    /// accepted variants. Matching is tolerant (see `FormatPhraseMatcher`).
    var germanPhrases: [String] {
        switch self {
        case .bulletList:
            return ["in Stichpunkten", "Stichpunkte", "als Liste", "Aufzählung", "Aufzählungszeichen", "Spiegelstriche"]
        case .numberedList:
            return ["nummerierte Liste", "nummeriert", "Nummerierung", "durchnummeriert"]
        case .todoList:
            return ["als To-do-Liste", "To-do-Liste", "Aufgabenliste", "Checkliste", "Aufgaben", "To-dos"]
        case .allCaps:
            return ["alles groß", "Großbuchstaben", "Großschreibung", "Capslock", "Feststelltaste", "alles in Großbuchstaben"]
        case .lowercase:
            return ["alles klein", "Kleinbuchstaben", "Kleinschreibung", "alles in Kleinbuchstaben"]
        case .quotes:
            return ["in Anführungszeichen", "Anführungszeichen", "in Gänsefüßchen", "Gänsefüßchen", "als Zitat", "Zitat"]
        case .parentheses:
            return ["in Klammern", "Klammern", "Klammer"]
        case .heading:
            return ["als Überschrift", "Überschrift", "Titel"]
        case .verbatim:
            return ["wörtlich", "als Code", "Code", "unverändert", "Wort für Wort"]
        case .email:
            return ["als E-Mail", "E-Mail", "als Mail", "Mail"]
        case .formal:
            return ["formell", "förmlich", "formal", "professionell", "Sie-Form"]
        case .shorter:
            return ["kürzer", "kürzen", "kurz und knapp", "knapper", "kurz"]
        case .translateToEnglish:
            return ["auf Englisch", "ins Englische", "Englisch", "übersetze ins Englische"]
        case .translateToGerman:
            return ["auf Deutsch", "ins Deutsche", "Deutsch", "übersetze ins Deutsche"]
        }
    }

    /// What to say, English. First entry is shown in the UI.
    var englishPhrases: [String] {
        switch self {
        case .bulletList:
            return ["bullet points", "bullet list", "bullets", "as a list", "list"]
        case .numberedList:
            return ["numbered list", "numbered", "numbers"]
        case .todoList:
            return ["to-do list", "todo list", "checklist", "to-dos", "tasks"]
        case .allCaps:
            return ["all caps", "caps lock", "capslock", "caps", "uppercase", "capital letters", "capitals"]
        case .lowercase:
            return ["all lowercase", "lowercase", "lower case", "small letters"]
        case .quotes:
            return ["in quotes", "quotation marks", "quotes", "quote"]
        case .parentheses:
            return ["in parentheses", "parentheses", "brackets", "in brackets"]
        case .heading:
            return ["as a heading", "heading", "headline", "title"]
        case .verbatim:
            return ["verbatim", "as code", "code", "word for word", "literally"]
        case .email:
            return ["as an email", "email", "e-mail", "as a mail"]
        case .formal:
            return ["formal", "formally", "more formal", "professional"]
        case .shorter:
            return ["shorter", "shorten", "make it shorter", "concise", "short"]
        case .translateToEnglish:
            return ["in English", "English", "translate to English"]
        case .translateToGerman:
            return ["in German", "German", "translate to German"]
        }
    }

    /// The phrase to show in the UI language (German UI → German phrase, otherwise
    /// English — the two languages the matcher understands).
    func shownPhrase(uiLanguageCode: String?) -> String {
        (uiLanguageCode?.lowercased().hasPrefix("de") == true ? germanPhrases : englishPhrases)[0]
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
    /// Back to normal text ("normal", "Ende", …).
    case end

    /// Phrases that end the active format.
    static let germanEndPhrases = ["normal", "Ende", "normaler Text", "Stopp", "Schluss", "fertig", "aus"]
    static let englishEndPhrases = ["normal", "end", "plain text", "stop", "done", "off"]
}
