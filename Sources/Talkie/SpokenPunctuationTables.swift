import Foundation

/// The words behind `SpokenPunctuation`: what each spoken word becomes, how it glues to
/// its neighbours, and the sentence-use signals that keep a word a word.
///
/// German and English are always on, whatever language is being dictated (the owner
/// switches mid-sentence). The tables for the other transcription languages are small,
/// UNVERIFIED (never run against a real recognizer) and stricter: every entry needs the
/// recognizer's own punctuation next to the word.
enum SpokenPunctuationTables {

    // MARK: Marks

    /// How a mark touches its neighbours.
    enum Glue { case attach, space }

    /// What kind of character a spoken word stands for. The kind fixes spacing,
    /// which recognizer punctuation is absorbed, and whether it ends a sentence.
    enum Kind: Hashable {
        case colon, semicolon, question, exclaim, ellipsis
        case openParen, closeParen, openBracket, closeBracket, openBrace, closeBrace
        case quoteOpen, quoteClose
        case slash, backslash, hyphen, underscore, at
        case emDash, enDash
        case dash          // "dash": em dash unspaced in English, spaced en dash elsewhere
        case dashSpaced    // "Gedankenstrich": always a spaced en dash
        case percent       // "100 %" in German, "100%" elsewhere
        case ampersand, equals, plus, asterisk, section
        case hash          // "#" glued to the next word
        case sectionNumber // "Paragraph fünf" -> "§ 5"

        var openFamily: Family? {
            switch self {
            case .openParen: return .paren
            case .openBracket: return .bracket
            case .openBrace: return .brace
            case .quoteOpen: return .quote
            default: return nil
            }
        }
        var closeFamily: Family? {
            switch self {
            case .closeParen: return .paren
            case .closeBracket: return .bracket
            case .closeBrace: return .brace
            case .quoteClose: return .quote
            default: return nil
            }
        }
        /// Marks written right after the previous word ("Hallo:", "wirklich?", "gesagt)").
        /// Said first, with more words after, they have nothing to attach to.
        var attachesToPrevious: Bool {
            switch self {
            case .colon, .semicolon, .question, .exclaim, .ellipsis,
                 .closeParen, .closeBracket, .closeBrace, .quoteClose,
                 .emDash, .enDash, .dash, .dashSpaced: return true
            default: return false
            }
        }
        var isOpener: Bool { openFamily != nil }
        /// Free-standing symbols ("a = b", "#launch", "100 %").
        var isSymbol: Bool {
            switch self {
            case .ampersand, .equals, .plus, .asterisk, .section, .hash, .percent: return true
            default: return false
            }
        }
        /// Marks that join two words and are meaningless without the second one.
        var isJoin: Bool {
            switch self {
            case .slash, .backslash, .hyphen, .underscore, .at: return true
            default: return false
            }
        }
    }

    enum Family { case paren, bracket, brace, quote }

    /// One spoken phrase. `words` are lower-case tokens; between two tokens only a
    /// space or a hyphen is allowed ("At-Zeichen").
    struct Entry {
        var words: [String]
        var kind: Kind
        /// The recognizer's own punctuation (or the text edge) must touch the word on at
        /// least one side. Used for words that are ordinary too often ("dash", "Sternchen").
        var needsBoundary = false
        /// Words directly before that do NOT count as a sentence-use signal here.
        var ignorePrev: Set<String> = []
        /// A token the recognizer fused: "Semi;" is how it writes a spoken "Semikolon".
        var followedByGapPrefix: Character? = nil
        /// Only in dictation languages whose base code is listed (nil = any).
        var onlyLanguages: Set<String>? = nil
    }

    private static func e(_ phrase: String, _ kind: Kind, boundary: Bool = false,
                          ignorePrev: Set<String> = [], languages: Set<String>? = nil) -> Entry {
        Entry(words: phrase.split(separator: " ").map(String.init), kind: kind, needsBoundary: boundary,
              ignorePrev: ignorePrev, onlyLanguages: languages)
    }

    // MARK: German

    static let german: [Entry] = [
        e("doppelpunkt", .colon), e("doppel punkt", .colon),
        e("semikolon", .semicolon), e("strichpunkt", .semicolon), e("semi kolon", .semicolon),
        Entry(words: ["semi"], kind: .semicolon, followedByGapPrefix: ";"),
        e("fragezeichen", .question),
        e("ausrufezeichen", .exclaim), e("ausrufungszeichen", .exclaim),
        e("auslassungspunkte", .ellipsis), e("auslassungszeichen", .ellipsis),
        e("schrägstrich", .slash), e("schräg strich", .slash), e("slash", .slash),
        e("backslash", .backslash), e("back slash", .backslash), e("umgekehrter schrägstrich", .backslash),
        e("klammer auf", .openParen), e("klammer zu", .closeParen),
        e("runde klammer auf", .openParen), e("runde klammer zu", .closeParen),
        e("eckige klammer auf", .openBracket), e("eckige klammer zu", .closeBracket),
        e("geschweifte klammer auf", .openBrace), e("geschweifte klammer zu", .closeBrace),
        e("anführungszeichen auf", .quoteOpen), e("anführungszeichen unten", .quoteOpen),
        e("anführungszeichen zu", .quoteClose), e("anführungszeichen oben", .quoteClose),
        e("gedankenstrich", .dashSpaced),
        e("bindestrich", .hyphen),
        e("unterstrich", .underscore),
        e("at zeichen", .at, ignorePrev: ["an"]), e("klammeraffe", .at),
        e("prozentzeichen", .percent), e("prozent zeichen", .percent),
        e("et zeichen", .ampersand), e("e zeichen", .ampersand), e("kaufmännisches und", .ampersand),
        e("raute", .hash), e("rautenzeichen", .hash), e("hash zeichen", .hash),
        e("hashtag", .hash, boundary: true),
        e("sternchen", .asterisk),
        e("gleichheitszeichen", .equals),
        e("pluszeichen", .plus), e("plus zeichen", .plus),
        e("paragraphzeichen", .section), e("paragrafzeichen", .section),
        e("paragraph zeichen", .section), e("paragraf zeichen", .section),
        // "Paragraph" is also the English word, so the English spelling counts only when
        // the dictation language is German; the German spelling "Paragraf" always does.
        e("paragraph", .sectionNumber, languages: ["de"]), e("paragraf", .sectionNumber),
    ]

    // MARK: English

    static let english: [Entry] = [
        e("colon", .colon),
        e("semicolon", .semicolon), e("semi colon", .semicolon),
        e("question mark", .question),
        e("exclamation mark", .exclaim), e("exclamation point", .exclaim),
        e("ellipsis", .ellipsis),
        e("slash", .slash), e("forward slash", .slash),
        e("backslash", .backslash), e("back slash", .backslash),
        e("open parenthesis", .openParen), e("close parenthesis", .closeParen),
        e("open paren", .openParen), e("close paren", .closeParen),
        e("left parenthesis", .openParen), e("right parenthesis", .closeParen),
        e("open round bracket", .openParen), e("close round bracket", .closeParen),
        // "bracket" is "[" (programmer usage); "parenthesis" is "(".
        e("open bracket", .openBracket), e("close bracket", .closeBracket),
        e("open square bracket", .openBracket), e("close square bracket", .closeBracket),
        e("open brace", .openBrace), e("close brace", .closeBrace),
        e("open curly bracket", .openBrace), e("close curly bracket", .closeBrace),
        e("open quote", .quoteOpen), e("open quotes", .quoteOpen), e("begin quote", .quoteOpen),
        e("close quote", .quoteClose), e("close quotes", .quoteClose),
        e("end quote", .quoteClose), e("unquote", .quoteClose),
        e("dash", .dash, boundary: true),
        // The recognizer writes a spoken "em dash" as "M dash" (measured).
        e("em dash", .emDash), e("m dash", .emDash), e("en dash", .enDash),
        e("hyphen", .hyphen),
        e("underscore", .underscore),
        e("at sign", .at, ignorePrev: ["at"]), e("at symbol", .at, ignorePrev: ["at"]),
        e("percent sign", .percent), e("percent symbol", .percent),
        e("ampersand", .ampersand),
        e("hash sign", .hash), e("hash symbol", .hash),
        e("hashtag", .hash, boundary: true),
        e("asterisk", .asterisk),
        e("equals sign", .equals), e("equal sign", .equals),
        e("plus sign", .plus),
        e("section sign", .section),
    ]

    // MARK: Other transcription languages (UNVERIFIED; always need the recognizer's punctuation)

    /// Hand-written from general knowledge, never tested against a recognizer. Every entry
    /// is forced to `needsBoundary`. Japanese, Chinese and Korean entries only match when
    /// the recognizer writes the word as a separate token.
    static let others: [String: [Entry]] = [
        "fr": [e("deux points", .colon), e("point virgule", .semicolon),
               e("point d'interrogation", .question), e("point d'exclamation", .exclaim),
               e("barre oblique", .slash), e("ouvrir la parenthèse", .openParen),
               e("fermer la parenthèse", .closeParen), e("ouvrez les guillemets", .quoteOpen),
               e("fermez les guillemets", .quoteClose), e("arobase", .at),
               e("esperluette", .ampersand), e("tiret du bas", .underscore)],
        "es": [e("punto y coma", .semicolon), e("signo de interrogación", .question),
               e("signo de exclamación", .exclaim), e("barra diagonal", .slash),
               e("abrir paréntesis", .openParen), e("cerrar paréntesis", .closeParen),
               e("abrir comillas", .quoteOpen), e("cerrar comillas", .quoteClose),
               e("guion bajo", .underscore), e("arroba", .at)],
        "it": [e("punto e virgola", .semicolon), e("punto interrogativo", .question),
               e("punto esclamativo", .exclaim), e("barra obliqua", .slash),
               e("apri parentesi", .openParen), e("chiudi parentesi", .closeParen),
               e("apri virgolette", .quoteOpen), e("chiudi virgolette", .quoteClose),
               e("chiocciola", .at), e("trattino basso", .underscore), e("e commerciale", .ampersand)],
        "pt": [e("ponto e vírgula", .semicolon), e("ponto de interrogação", .question),
               e("ponto de exclamação", .exclaim), e("abre parênteses", .openParen),
               e("fecha parênteses", .closeParen), e("abre aspas", .quoteOpen),
               e("fecha aspas", .quoteClose), e("arroba", .at), e("e comercial", .ampersand)],
        "nl": [e("dubbele punt", .colon), e("puntkomma", .semicolon), e("vraagteken", .question),
               e("uitroepteken", .exclaim), e("schuine streep", .slash),
               e("haakje openen", .openParen), e("haakje sluiten", .closeParen),
               e("aanhalingsteken openen", .quoteOpen), e("aanhalingsteken sluiten", .quoteClose),
               e("apenstaartje", .at), e("koppelteken", .hyphen)],
        "ja": [e("コロン", .colon), e("セミコロン", .semicolon), e("クエスチョンマーク", .question),
               e("感嘆符", .exclaim), e("スラッシュ", .slash), e("アットマーク", .at),
               e("アンダーバー", .underscore), e("ハイフン", .hyphen)],
        "ko": [e("콜론", .colon), e("세미콜론", .semicolon), e("물음표", .question),
               e("느낌표", .exclaim), e("슬래시", .slash), e("여는 괄호", .openParen),
               e("닫는 괄호", .closeParen)],
        "zh": [e("冒号", .colon), e("分号", .semicolon), e("问号", .question), e("感叹号", .exclaim),
               e("斜杠", .slash), e("左括号", .openParen), e("右括号", .closeParen),
               e("下划线", .underscore)],
    ]

    // MARK: Sentence-use signals (German and English; lower-case)

    private static func set(_ s: String) -> Set<String> {
        Set(s.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init))
    }

    /// Directly BEFORE the word: the word is a noun in a sentence, not a command.
    /// Determiners, prepositions, adjectives, quantifiers, and verbs that take the word as
    /// an object ("setz einen …", "add a …"). Plain numbers are deliberately absent:
    /// "10 Doppelpunkt 30" and "5 slash 6" are command use.
    static let literalBefore: Set<String> = set("""
        der die das den dem des ein eine einen einem einer eines kein keine keinen keinem keiner \
        dieser diese dieses diesen diesem jeder jede jedes jeden jedem mein meine meinen meinem meiner \
        dein deine deinen deinem deiner sein seine seinen seinem seiner ihr ihre ihren ihrem ihrer \
        unser unsere unseren unserem welcher welche welches welchen manche mancher alle aller allen \
        alles beide beiden einige einigen mehrere viele wenige paar mehr weniger \
        in im ins an am ans auf aufs bei beim mit nach von vom vor vorm zu zum zur zwischen über \
        unter hinter neben für durch gegen ohne um bis aus ab seit statt wegen während \
        neue neuen neuer neues neuem nächste nächsten nächster nächstes erste ersten erster zweite \
        zweiten letzte letzten letzter gleiche gleichen gleiches selbe doppelte doppelten richtige \
        richtigen falsche falschen fehlende fehlenden passende passenden einzelne einzelnen leere \
        leeren kleine kleinen große großen lange langen kurze kurzen weitere weiteren zusätzliche \
        zusätzlichen folgende folgenden vorherige vorherigen andere anderen ganzen ganze \
        setz setze setzen setzt mach mache machen füg füge fügen entfern entferne entfernen lösch \
        lösche löschen schreib schreibe tipp tippe nutz nutze nutzen verwende verwenden benutze \
        benutzen brauchen brauche braucht brauchst haben habe hab hat suche streich ersetze \
        ersetzen nenn nenne nimm nehmen ändere ergänze lass lassen vergiss vermeide vermeiden \
        drück drücke heißt heisst bedeutet auch als fehlt fehlen gehört gehören folgt steht
        the a an this that these those my your his her its our their another each every any some \
        no both all one other
        in on at with without after before behind between from to into onto of for by about around \
        over under through during until since like as via per inside outside near above below beside
        new next last first second third same extra additional following final correct wrong \
        missing proper single double blank empty big small long short previous stray trailing \
        leading whole entire actual real little quick mad
        add adds adding added remove removes removing removed put puts use uses using used type \
        types typing typed insert inserts inserting inserted delete deletes deleting deleted need \
        needs needed include includes write writes writing say says forget forgot avoid press \
        presses hit have has had get got make makes making see show name call called named replace \
        replaced change also
        """)

    /// Directly AFTER the word: it is the subject of a clause (a finite verb or copula).
    static let literalAfter: Set<String> = set("""
        ist sind war waren wäre fehlt fehlen bedeutet bedeuten heißt heißen steht stehen kommt \
        kommen gehört gehören muss müssen soll sollen kann können wird werden hat haben macht \
        machen gibt geht gehen
        is are was were be been means mean goes go comes come should must can could will would has \
        have had does do needs need sits sit stands stand looks look makes make gets get belongs \
        isn't doesn't matters matter works work marks separates separate denotes indicates \
        represents starts start ends end follows seems appears breaks helps
        funktioniert funktionieren trennt trennen markiert zeigt beginnt endet folgt kennzeichnet \
        wirkt sieht stört fehlte
        """)

    /// Either side: the sentence is ABOUT punctuation, not using it.
    static let aboutPunctuation: Set<String> = set("""
        zeichen symbol taste tasten befehl befehle kürzel tastenkürzel tastatur wort worte wörter \
        begriff bezeichnung namens genannt
        symbol key keys character characters command commands shortcut keyboard word words term \
        called named label token punctuation
        """)

    /// Directly AFTER the word: a preposition makes it a noun ("Fragezeichen durch Punkte
    /// ersetzen", "colon in the title"). The tagger adds more when it is available.
    static let prepositions: Set<String> = set("""
        in im ins an am ans auf aufs bei beim mit nach von vom vor zum zur zwischen über unter \
        hinter neben für durch gegen ohne um bis aus ab seit statt anstatt wegen während
        in on at with without after before behind between from to into onto of for by about \
        around over under through during until since via per inside outside near above below \
        instead
        """)

    /// Directly AFTER a joining mark: a determiner ("underscore the importance").
    static let determiners: Set<String> = set("""
        der die das den dem des ein eine einen einem einer eines
        the a an this these those
        """)

    /// English auxiliaries and modals: "we should slash prices", "to underscore".
    static let auxiliaries: Set<String> = set("should would could can will must may might shall to don't didn't won't")

    /// Articles only (no demonstratives): "mit der neuen …", "a big …".
    static let articles: Set<String> = set("der die das den dem des ein eine einen einem einer eines the a an")

    /// Clause-joining words: "und Semikolon trennt …" is a subject.
    static let conjunctions: Set<String> = set("und aber oder weil dass wenn ob and but or because that if whether")

    /// Plain punctuation nouns that are never replaced but count as a mark name in a
    /// list ("Fragezeichen oder Punkt?", "colons and semicolons").
    static let markNouns: Set<String> = set("""
        punkt punkte komma kommas kommata strich striche leerzeichen klammer klammern doppelpunkte \
        semikolons semikola schrägstriche slashes backslashes bindestriche gedankenstriche \
        unterstriche zeile zeilen absatz absätze raute rauten sternchen anführungszeichen
        period periods comma commas dot dots space spaces colons semicolons brackets bracket \
        parenthesis parentheses paren parens quote quotes hyphens dashes underscores asterisks \
        hashtags line lines paragraph paragraphs
        """)

    /// Words that link two items of a list. Returns the connector's length at `k`.
    static func connectorLength(_ lowered: [String], at k: Int) -> Int? {
        guard k < lowered.count else { return nil }
        if k + 1 < lowered.count, twoWordConnectors.contains([lowered[k], lowered[k + 1]]) { return 2 }
        return connectors.contains(lowered[k]) ? 1 : nil
    }

    /// The start index of a connector that ends at word `k`, or nil.
    static func connectorStart(_ lowered: [String], endingAt k: Int) -> Int? {
        guard k >= 0, k < lowered.count else { return nil }
        if k >= 1, twoWordConnectors.contains([lowered[k - 1], lowered[k]]) { return k - 1 }
        return connectors.contains(lowered[k]) ? k : nil
    }

    private static let connectors: Set<String> = set("""
        und oder bzw beziehungsweise sowie statt anstatt als versus vs and or nor than
        """)
    private static let twoWordConnectors: Set<[String]> = [["instead", "of"], ["rather", "than"], ["anstelle", "von"]]

    /// Words that start a person's own sentence-initial determiner use ("A" the letter).
    static let numberWords: [String: String] = [
        "ein": "1", "eins": "1", "zwei": "2", "drei": "3", "vier": "4", "fünf": "5", "sechs": "6",
        "sieben": "7", "acht": "8", "neun": "9", "zehn": "10", "elf": "11", "zwölf": "12",
    ]

    static func entries(languageCode: String?) -> [Entry] {
        var all = german + english
        if let code = languageCode?.lowercased().prefix(2), let extra = others[String(code)] {
            all += extra.map { var x = $0; x.needsBoundary = true; return x }
        }
        // Longest phrase first so "eckige klammer auf" beats "klammer auf".
        return all.sorted { $0.words.count > $1.words.count }
    }
}

// MARK: - Reference list for the Commands page

extension SpokenPunctuationTables {
    /// What the page shows: the spoken citation form and the character it becomes, per
    /// language. Words are spoken-language data, so they are not localized. The wording
    /// matches the tables above; a test keeps the two in step.
    static func reference(language: String) -> [(word: String, mark: String)] {
        switch language {
        case "de":
            return [("Doppelpunkt", ":"), ("Semikolon", ";"), ("Fragezeichen", "?"), ("Ausrufezeichen", "!"),
                    ("Schrägstrich", "/"), ("Backslash", "\\"), ("Klammer auf", "("), ("Klammer zu", ")"),
                    ("eckige Klammer auf", "["), ("eckige Klammer zu", "]"),
                    ("geschweifte Klammer auf", "{"), ("geschweifte Klammer zu", "}"),
                    ("Anführungszeichen auf", "\u{201E}"), ("Anführungszeichen zu", "\u{201C}"),
                    ("Gedankenstrich", "–"), ("Bindestrich", "-"), ("Unterstrich", "_"),
                    ("At-Zeichen", "@"), ("Prozentzeichen", "%"), ("Et-Zeichen", "&"),
                    ("Raute", "#"), ("Sternchen", "*"), ("Gleichheitszeichen", "="), ("Pluszeichen", "+"),
                    ("Paragraphzeichen", "§"), ("Paragraph fünf", "§ 5"), ("Auslassungspunkte", "…"),
                    ("neue Zeile", "↵"), ("neuer Absatz", "¶")]
        case "en":
            return [("colon", ":"), ("semicolon", ";"), ("question mark", "?"), ("exclamation mark", "!"),
                    ("slash", "/"), ("backslash", "\\"), ("open parenthesis", "("), ("close parenthesis", ")"),
                    ("open bracket", "["), ("close bracket", "]"), ("open brace", "{"), ("close brace", "}"),
                    ("open quote", "\u{201C}"), ("close quote", "\u{201D}"),
                    ("dash", "—"), ("hyphen", "-"), ("underscore", "_"), ("at sign", "@"),
                    ("percent sign", "%"), ("ampersand", "&"), ("hash sign", "#"), ("asterisk", "*"),
                    ("equals sign", "="), ("plus sign", "+"), ("section sign", "§"), ("ellipsis", "…"),
                    ("new line", "↵"), ("new paragraph", "¶")]
        default:
            let glyph: [Kind: String] = [
                .colon: ":", .semicolon: ";", .question: "?", .exclaim: "!", .slash: "/",
                .openParen: "(", .closeParen: ")", .quoteOpen: "\u{201C}", .quoteClose: "\u{201D}",
                .at: "@", .underscore: "_", .ampersand: "&", .hyphen: "-",
            ]
            return (others[language] ?? []).compactMap { entry in
                glyph[entry.kind].map { (entry.words.joined(separator: " "), $0) }
            }
        }
    }
}
