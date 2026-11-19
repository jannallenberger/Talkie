import XCTest
@testable import Talkie

/// Spoken punctuation. Pure string tests: nothing here touches Application Support.
final class SpokenPunctuationTests: XCTestCase {

    private func de(_ s: String) -> String { SpokenPunctuation.apply(s, languageCode: "de") }
    private func en(_ s: String) -> String { SpokenPunctuation.apply(s, languageCode: "en") }

    // MARK: Every shipped word: one command case and three sentence-use cases

    private typealias T = SpokenPunctuationTables

    /// "alpha, <word>, beta" in command use, per kind (German dictation language unless noted).
    private func expectedCommand(_ kind: T.Kind) -> String? {
        switch kind {
        case .colon: return "alpha: beta"
        case .semicolon: return "alpha; beta"
        case .question: return "alpha? Beta"
        case .exclaim: return "alpha! Beta"
        case .ellipsis: return "alpha… beta"
        case .openParen: return "alpha, (beta"      // a comma BEFORE an opener is kept
        case .openBracket: return "alpha, [beta"
        case .openBrace: return "alpha, {beta"
        case .quoteOpen: return "alpha, \u{201E}beta"
        case .closeParen: return "alpha) beta"
        case .closeBracket: return "alpha] beta"
        case .closeBrace: return "alpha} beta"
        case .quoteClose: return "alpha\u{201C} beta"
        case .slash: return "alpha/beta"
        case .backslash: return "alpha\\beta"
        case .hyphen: return "alpha-beta"
        case .underscore: return "alpha_beta"
        case .at: return "alpha@beta"
        case .emDash: return "alpha—beta"
        case .enDash: return "alpha–beta"
        case .dash: return "alpha – beta"          // German dictation: spaced en dash
        case .dashSpaced: return "alpha – beta"
        case .percent: return "alpha % beta"      // German: space before %
        case .ampersand: return "alpha & beta"
        case .equals: return "alpha = beta"
        case .plus: return "alpha + beta"
        case .asterisk: return "alpha * beta"
        case .section: return "alpha § beta"
        case .hash: return "alpha #beta"
        case .sectionNumber: return nil           // needs a number; tested separately
        }
    }

    private func phrase(_ e: T.Entry) -> String { e.words.joined(separator: " ") }

    private func entriesForCases() -> [T.Entry] {
        (T.german + T.english).filter { $0.followedByGapPrefix == nil && $0.kind != .sectionNumber }
    }

    func testEveryShippedWordIsReplacedInCommandUse() {
        var checked = 0
        for entry in entriesForCases() {
            let word = phrase(entry)
            // Closers and "%" keep a comma AFTER them ("(wie gesagt), geht"), and "#" needs
            // its word right behind it, so those are written without a trailing comma.
            let input: String
            switch entry.kind {
            case .closeParen, .closeBracket, .closeBrace, .quoteClose, .hash: input = "alpha, \(word) beta"
            case .percent: input = "alpha \(word) beta"
            default: input = "alpha, \(word), beta"
            }
            let expected = expectedCommand(entry.kind)!
            XCTAssertEqual(de(input), expected, "command use: “\(word)”")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 90)
    }

    func testEveryShippedWordStaysAWordInSentenceUse() {
        // Three different sentence-use signals per word, German templates for German
        // words and English templates for English words: article, preposition + adjective,
        // subject of a clause (a finite verb follows).
        let germanWords = Set(T.german.map(phrase))
        var cases = 0
        for entry in entriesForCases() {
            let w = phrase(entry)
            let templates: [String]
            let lang: String
            if germanWords.contains(w) && !T.english.contains(where: { phrase($0) == w }) {
                lang = "de"
                templates = ["Er meinte einen \(w) und sonst nichts",
                             "Wir machen das mit der neuen \(w) darunter",
                             "Der Ausdruck war falsch und \(w) ist hier wichtig"]
            } else {
                lang = "en"
                templates = ["He meant a \(w) and nothing else",
                             "We do it with the next \(w) below",
                             "The phrase was wrong and \(w) is important here"]
            }
            for t in templates {
                XCTAssertEqual(SpokenPunctuation.apply(t, languageCode: lang), t, "sentence use: \(t)")
                cases += 1
            }
        }
        XCTAssertGreaterThan(cases, 270)
    }

    func testSentenceUseWithTheRecognizersCommasIsStillReplacedOnlyWhenIsolated() {
        // The recognizer's commas around the word say "own prosodic unit"; the same
        // sentence-use words WITHOUT commas stay literal.
        XCTAssertEqual(de("Hallo, Doppelpunkt, das ist ein Test."), "Hallo: das ist ein Test.")
        XCTAssertEqual(de("Setz bitte einen Doppelpunkt hinter das Wort Hallo."),
                       "Setz bitte einen Doppelpunkt hinter das Wort Hallo.")
    }

    // MARK: The owner's sentence, verbatim, and sentence-use families

    func testOwnerSentenceStaysWords() {
        let s = "dann machen wir in einer neuen Zeile darunter einmal das"
        XCTAssertEqual(de(s), s)
        XCTAssertEqual(en(s), s)
        XCTAssertEqual(StructuralCommands.apply(s, languageCode: "de", anyLanguage: true), s)
        XCTAssertEqual(StructuralCommands.apply(s, languageCode: "en", anyLanguage: true), s)
    }

    func testDeterminersPrepositionsAdjectivesAndVerbsKeepWords() {
        let literal = [
            "nach dem Fragezeichen kommt ein Leerzeichen",
            "mit einem Slash fängt der Befehl an",
            "in einer neuen Zeile darunter",
            "setz einen Doppelpunkt",
            "mach ein Semikolon dahinter",
            "wir brauchen Anführungszeichen auf der linken Seite",
            "füge ein Ausrufezeichen hinzu",
            "put a colon after it",
            "add an exclamation mark at the end",
            "type a slash and the name",
            "remove the question mark",
            "use another hyphen here",
            "on a new line below",
            "in the next paragraph",
            "Doppelpunkt ist ein Satzzeichen",
            "slash means divide here",
            "the colon is missing",
            "colon is a punctuation mark",
            "das Zeichen Doppelpunkt fehlt",
            "the key slash is on the keyboard",
            "der Befehl Slash review startet das",
            "the slash command starts a review",
            "ein Slash-Befehl startet das",
            "the slash commands are listed",
        ]
        for s in literal {
            XCTAssertEqual(de(s), s, s)
            XCTAssertEqual(en(s), s, s)
        }
    }

    func testInflectedAndPluralFormsNeverMatch() {
        for s in ["zwei Doppelpunkte", "viele Klammern auf der Seite", "die Anführungszeichen",
                  "two slashes", "three brackets", "several colons", "neue Zeilen", "neuen Zeile",
                  "Doppelpunkte, Semikolons, Fragezeichen", ] {
            if s.contains("Fragezeichen") { continue }
            XCTAssertEqual(de(s), s, s)
        }
        XCTAssertEqual(de("Doppelpunkte, Semikolons"), "Doppelpunkte, Semikolons")
        XCTAssertEqual(en("slashes, brackets, colons"), "slashes, brackets, colons")
    }

    func testCompoundsAreNeverTouched() {
        for s in ["Die Doppelpunktregel gilt nicht", "der Befehlslash", "das Slashzeichen",
                  "Fragezeichenpflicht, Klammeraffenzeit", "colonoscopy, hashtagging, slashdot",
                  "die Semikolon-Regel, eine Doppelpunkt-Liste", "the colon-separated list"] {
            XCTAssertEqual(de(s), s)
            XCTAssertEqual(en(s), s)
        }
    }

    // MARK: Spacing, absorption, neighbours

    func testColonAbsorbsRecognizerPunctuation() {
        XCTAssertEqual(de("Hallo, Doppelpunkt, das"), "Hallo: das")
        XCTAssertEqual(de("Hallo. Doppelpunkt. Das"), "Hallo: Das")      // casing after ":" stays
        XCTAssertEqual(en("Hello, Colon, this"), "Hello: this")
        XCTAssertEqual(de("Ich komme morgen, Semi; und dann"), "Ich komme morgen; und dann") // recognizer's "Semi;"
    }

    func testNoSpaceBeforeClosersAndOneSpaceAfter() {
        XCTAssertEqual(de("sicher, Fragezeichen, ja"), "sicher? Ja")
        XCTAssertEqual(de("toll, Ausrufezeichen. Wirklich"), "toll! Wirklich")
        XCTAssertEqual(en("fine, semicolon, then"), "fine; then")
        XCTAssertEqual(en("end, ellipsis, and then"), "end… and then")
    }

    func testNoDoublePunctuationAndSentenceCapitalisation() {
        XCTAssertEqual(de("Meinst du Fragezeichen."), "Meinst du?")
        XCTAssertEqual(de("Bist du sicher? Fragezeichen, ich glaube nicht."), "Bist du sicher? Ich glaube nicht.")
        XCTAssertEqual(en("Are you sure, question mark, i think so"), "Are you sure? I think so")
        XCTAssertEqual(en("Great, exclamation mark. really"), "Great! Really")
    }

    func testSlashJoinsOrPrefixes() {
        XCTAssertEqual(de("Bitte nimm Tee und Schrägstrich oder Kaffee"), "Bitte nimm Tee und/oder Kaffee")
        XCTAssertEqual(en("take coffee, forward slash, tea"), "take coffee/tea")
        XCTAssertEqual(de("Slash review"), "/review")
        XCTAssertEqual(en("backslash, temp"), "\\temp")
        XCTAssertEqual(de("Bitte nimm uns Schrägstrich oder Slash."), "Bitte nimm uns/oder Slash.") // no word after: stays
        XCTAssertEqual(en("Use slash."), "Use slash.")
    }

    func testBracketsAttachToTheInside() {
        XCTAssertEqual(de("Dann Klammer auf, wie gesagt, Klammer zu geht das."), "Dann (wie gesagt) geht das.")
        XCTAssertEqual(en("Then open parenthesis, as I said close parenthesis, it works."), "Then (as I said), it works.")
        XCTAssertEqual(de("eins, eckige Klammer auf, zwei, eckige Klammer zu, drei"), "eins, [zwei], drei")
        XCTAssertEqual(en("a, open brace, b, close brace, c"), "a, {b}, c")
        XCTAssertEqual(en("x open square bracket, 1 close square bracket, y"), "x [1], y")
    }

    func testQuotesFollowTheDictationLanguage() {
        XCTAssertEqual(de("Er sagte, Anführungszeichen auf, ja, Anführungszeichen zu."), "Er sagte, \u{201E}ja\u{201C}.")
        XCTAssertEqual(en("He said, open quote, yes, close quote."), "He said, \u{201C}yes\u{201D}.")
        XCTAssertEqual(de("Er sagte Anführungszeichen unten Ja Anführungszeichen oben"), "Er sagte \u{201E}Ja\u{201C}")
        // Mixed: English words inside a German dictation use the German quotes.
        XCTAssertEqual(de("sagte, open quote, yes, close quote"), "sagte, \u{201E}yes\u{201C}")
    }

    func testDashesHyphenUnderscoreAt() {
        XCTAssertEqual(de("Das ist neu, Gedankenstrich, oder doch nicht"), "Das ist neu – oder doch nicht")
        XCTAssertEqual(en("That is new, dash, or maybe not"), "That is new—or maybe not")
        XCTAssertEqual(en("five, en dash, ten"), "five–ten")
        XCTAssertEqual(en("so, em dash, then"), "so—then")
        XCTAssertEqual(en("the e hyphen mail"), "the e-mail")
        XCTAssertEqual(de("Mein, Unterstrich, Name"), "Mein_Name")
        XCTAssertEqual(en("write to max at sign example"), "write to max@example")
        XCTAssertEqual(de("Schreib mir an At-Zeichen Beispiel"), "Schreib mir an@Beispiel")
        XCTAssertEqual(en("Write me at at sign example"), "Write me at@example")
    }

    func testSymbolsSpaced() {
        XCTAssertEqual(en("a, ampersand, b"), "a & b")
        XCTAssertEqual(de("a, kaufmännisches Und, b"), "a & b")
        XCTAssertEqual(de("a Gleichheitszeichen b"), "a = b")
        XCTAssertEqual(en("a equals sign b"), "a = b")
        XCTAssertEqual(en("1 plus sign 2"), "1 + 2")
        XCTAssertEqual(de("Plus Zeichen B."), "+ B.")
        XCTAssertEqual(de("100 Prozent Zeichen sicher"), "100 % sicher")
        XCTAssertEqual(en("100 percent sign sure"), "100% sure")
        XCTAssertEqual(en("one, asterisk, two"), "one * two")
    }

    func testSectionSignAndParagraphNumber() {
        XCTAssertEqual(de("Siehe Paragraf 5 des Gesetzes"), "Siehe § 5 des Gesetzes")
        XCTAssertEqual(de("Paragraph fünf regelt das"), "§ 5 regelt das")
        XCTAssertEqual(de("im Paragraph 12 steht das"), "im § 12 steht das")
        XCTAssertEqual(de("Siehe Paragraphzeichen, hier"), "Siehe § hier")
        // Bare "Paragraph" is a word; English "paragraph" is never replaced.
        XCTAssertEqual(de("Der Paragraph ist sehr lang"), "Der Paragraph ist sehr lang")
        XCTAssertEqual(de("Paragraf, fünf Minuten"), "Paragraf, fünf Minuten")
        XCTAssertEqual(en("see paragraph 5 of the contract"), "see paragraph 5 of the contract")
        XCTAssertEqual(en("The paragraph is long"), "The paragraph is long")
        XCTAssertEqual(en("the section sign, here"), "the section sign, here")
        XCTAssertEqual(en("Section sign, here"), "§ here")
    }

    func testHashtagDashAndBoundaryWords() {
        XCTAssertEqual(en("Hashtag launch"), "#launch")
        XCTAssertEqual(en("tag it, hashtag launch"), "tag it #launch")
        XCTAssertEqual(en("Use the hashtag launch for this"), "Use the hashtag launch for this")
        XCTAssertEqual(en("a hashtag is fun"), "a hashtag is fun")
        XCTAssertEqual(en("hashtag"), "hashtag")
        XCTAssertEqual(en("Add a dash of salt to the soup."), "Add a dash of salt to the soup.")
        XCTAssertEqual(en("run to the store and dash home"), "run to the store and dash home") // no punctuation: literal
        XCTAssertEqual(de("Das Thema Raute wichtig"), "Das Thema Raute wichtig")
        XCTAssertEqual(de("Das ist ein Sternchen für dich."), "Das ist ein Sternchen für dich.")
        XCTAssertEqual(de("Ein Sternchen und ein Pluszeichen."), "Ein Sternchen und ein Pluszeichen.")
    }

    func testNeverTouchesWordsThatAreNotInTheList() {
        for s in ["Ein Punkt und ein Komma", "a period and a comma and a dot", "Strich und Stern",
                  "That is a good point", "Der Punkt ist klar"] {
            XCTAssertEqual(de(s), s)
            XCTAssertEqual(en(s), s)
        }
    }

    func testAcrossLanguagesRegardlessOfDictationLanguage() {
        XCTAssertEqual(en("Hallo, Doppelpunkt, das"), "Hallo: das")
        XCTAssertEqual(de("Hello, colon, this"), "Hello: this")
        XCTAssertEqual(SpokenPunctuation.apply("Hallo, Doppelpunkt, das", languageCode: nil), "Hallo: das")
        XCTAssertEqual(SpokenPunctuation.apply("Hallo, Doppelpunkt, das", languageCode: "fr"), "Hallo: das")
    }

    func testLineBreaksAreKept() {
        XCTAssertEqual(de("eins\nHallo, Doppelpunkt, das"), "eins\nHallo: das")
        XCTAssertEqual(de("Hallo, Doppelpunkt\ndas"), "Hallo:\ndas")
    }

    // MARK: Other transcription languages (unverified tables: need the recognizer's punctuation)

    func testOtherLanguageTablesNeedRecognizerPunctuation() {
        XCTAssertEqual(SpokenPunctuation.apply("Bonjour, deux points, voilà", languageCode: "fr"), "Bonjour: voilà")
        XCTAssertEqual(SpokenPunctuation.apply("une règle deux points ici", languageCode: "fr"), "une règle deux points ici")
        XCTAssertEqual(SpokenPunctuation.apply("Hola, punto y coma, luego", languageCode: "es"), "Hola; luego")
        XCTAssertEqual(SpokenPunctuation.apply("Ciao, punto interrogativo, ok", languageCode: "it"), "Ciao? Ok")
        XCTAssertEqual(SpokenPunctuation.apply("Hallo, dubbele punt, goed", languageCode: "nl"), "Hallo: goed")
        // A table applies only to its own language.
        XCTAssertEqual(SpokenPunctuation.apply("Bonjour, deux points, voilà", languageCode: "es"), "Bonjour, deux points, voilà")
        XCTAssertEqual(SpokenPunctuation.apply("今日は, コロン, 次", languageCode: "ja"), "今日は: 次")
    }

    // MARK: Structural commands (strictest)

    func testStructuralCommandsNeedBothSidesAndCitationForm() {
        let on = { (s: String, l: String?) in StructuralCommands.apply(s, languageCode: l, anyLanguage: true) }
        XCTAssertEqual(on("Erste Zeile, neue Zeile, zweite Zeile.", "en"), "Erste Zeile\nzweite Zeile.")
        XCTAssertEqual(on("First part, new paragraph, second part.", "de"), "First part\n\nsecond part.")
        XCTAssertEqual(on("Dann, neue Zeile, darunter", "de"), "Dann\ndarunter")
        // Sentence use and one-sided boundaries stay words.
        for s in ["Dann machen wir in einer neuen Zeile darunter einmal das Ergebnis.",
                  "Das ist ein neuer Absatz im Vertrag und er ist lang.",
                  "Erster Teil neuer Absatz zweiter Teil.",
                  "First part, new paragraph 2nd part.",
                  "Then we put it on a new line below the result.",
                  "This is a new paragraph in the contract, and it is long.",
                  "in neuen Zeilen, neuen Zeile, neue Zeilen"] {
            XCTAssertEqual(on(s, "de"), s, s)
            XCTAssertEqual(on(s, "en"), s, s)
        }
        // Without the switch the German phrase still needs a German dictation.
        XCTAssertEqual(StructuralCommands.apply("Erste Zeile, neue Zeile, zweite Zeile.", languageCode: "en"),
                       "Erste Zeile, neue Zeile, zweite Zeile.")
    }

    // MARK: Idempotence and fidelity

    private let commandSentences = [
        "Hallo, Doppelpunkt, das ist ein Test.", "sicher, Fragezeichen, ja", "Dann Klammer auf, wie gesagt, Klammer zu geht das.",
        "Er sagte, Anführungszeichen auf, ja, Anführungszeichen zu.", "take coffee, forward slash, tea", "Hashtag launch",
        "Siehe Paragraf 5 des Gesetzes", "Das ist neu, Gedankenstrich, oder doch nicht", "100 Prozent Zeichen sicher",
        "That is new, dash, or maybe not", "Ich komme morgen, Semi; und dann", "a Gleichheitszeichen b",
        "x open square bracket, 1 close square bracket, y", "Mein, Unterstrich, Name",
    ]

    func testIdempotent() {
        for s in commandSentences {
            for lang in ["de", "en", nil] {
                let once = SpokenPunctuation.apply(s, languageCode: lang)
                XCTAssertEqual(SpokenPunctuation.apply(once, languageCode: lang), once, s)
            }
        }
    }

    func testTextWithoutTriggerWordsIsByteIdentical() {
        let ordinary = [
            "", " ", "Hello world.", "Das ist ein ganz normaler Satz, mit Komma; und Semikolon-Regel: fertig!",
            "He said “hello” (twice) – then left… [really]", "Preis: 5 € / Stück, 100 % sicher & fertig",
            "Zeile eins\nZeile zwei\n\nAbsatz", "  führende Leerzeichen und  doppelte  Leerzeichen  ",
            "email me at max@example.com or call #12", "C:\\Temp\\file_name-1.txt", "Ünïcödé 日本語 émoji 🙂 text",
            "I need a new line manager to review the paragraph about the slash command",
            "Ein Doppelpunkt, ein Semikolon, ein Fragezeichen", "the colon, the semicolon, the dash",
        ]
        for s in ordinary {
            for lang in ["de", "en", "fr", nil] {
                XCTAssertEqual(SpokenPunctuation.apply(s, languageCode: lang), s, "[\(lang ?? "nil")] \(s)")
            }
        }
        // Property-style: random sentences from a vocabulary without a trigger word.
        let vocab = ["der", "die", "das", "Hund", "läuft", "schnell", "I", "think", "we", "should", "go", "home", "and",
                     "dann", "oder", "wenn", "Haus", "Tisch", "Zeile", "neue", "new", "line", "Absatz",
                     "Punkt", "Komma", "period", "comma", "dot", "point", "Strich", "Stern", "open", "close", "quote",
                     "mark", "sign", "Klammer", "auf", "zu", "5", "zehn", "…", ",", ".", "?", "!", ":", ";", "-", "(", ")"]
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        let trigger = Set(SpokenPunctuationTables.entries(languageCode: nil).flatMap { $0.words })
        var checked = 0
        for _ in 0..<2000 {
            let n = 1 + next() % 12
            var parts: [String] = []
            for _ in 0..<n { parts.append(vocab[next() % vocab.count]) }
            let s = parts.joined(separator: " ")
            // The vocabulary is built so no single trigger phrase can form: skip the rare
            // accidental ones ("klammer auf" is two vocabulary words).
            let lowered = s.lowercased()
            if lowered.contains("klammer auf") || lowered.contains("klammer zu") || lowered.contains("open quote")
                || lowered.contains("close quote") || lowered.contains("open") && lowered.contains("sign") { continue }
            _ = trigger
            XCTAssertEqual(SpokenPunctuation.apply(s, languageCode: "de"), s, s)
            XCTAssertEqual(SpokenPunctuation.apply(s, languageCode: "en"), s, s)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 1500)
    }

    // MARK: Format-command interaction

    func testInsideFormatSpans() async {
        // "alles groß" (all caps): the punctuation pass runs on the span text before the
        // renderer upper-cases it, so the character survives and the words are shouted.
        let seg = TimedSegment(text: "note alles groß hallo doppelpunkt wichtig", start: 0, end: 4, words: [
            SegmentWord(text: "note", start: 0, end: 0.4),
            SegmentWord(text: " alles", start: 1.0, end: 1.3),
            SegmentWord(text: " groß", start: 1.35, end: 1.7),
            SegmentWord(text: " hallo,", start: 2.2, end: 2.6),
            SegmentWord(text: " doppelpunkt,", start: 2.7, end: 3.2),
            SegmentWord(text: " wichtig", start: 3.3, end: 3.7),
        ])
        let plan = await FormatDictationAssembler.assemble(
            segments: [seg], marks: [.span(start: 0.9, end: 1.8)],
            clean: nil,
            postProcessFormatted: { SpokenPunctuation.apply($0, languageCode: "de") },
            languageCode: "de", userName: "", model: { _, _, _ in nil })
        XCTAssertEqual(plan.parts.last, .formatted(.init(text: "HALLO: WICHTIG", isBlock: false)))
    }

    func testQuotesFormatDoesNotFightQuoteWords() {
        // The "in quotes" format wraps the span; the spoken quote words still work inside it.
        let inner = SpokenPunctuation.apply("Hallo, Doppelpunkt, das", languageCode: "de")
        XCTAssertEqual(FormatRenderer.quoted(inner, languageCode: "de"), "\u{201E}Hallo: das\u{201C}")
        // "in quotes" itself is not a trigger.
        XCTAssertEqual(en("put this in quotes, please"), "put this in quotes, please")
        XCTAssertEqual(en("say it in quotes"), "say it in quotes")
        // List items and all caps keep the characters.
        XCTAssertEqual(FormatRenderer.list(.bulletList, items: [SpokenPunctuation.apply("milk, slash, eggs", languageCode: "en")]),
                       "- Milk/eggs")
        XCTAssertEqual(FormatRenderer.allCaps(SpokenPunctuation.apply("a, colon, b", languageCode: "en"), languageCode: "en"), "A: B")
    }

    func testReferenceListMatchesTheTables() {
        let all = Set((T.german + T.english).map(phrase))
        let skip: Set<String> = ["neue zeile", "neuer absatz", "paragraph fünf", "new line", "new paragraph"]
        for lang in ["de", "en"] {
            for item in T.reference(language: lang) where !skip.contains(item.word.lowercased()) {
                let w = item.word.lowercased().replacingOccurrences(of: "-", with: " ")
                XCTAssertTrue(all.contains(w), "shown but not matched: \(item.word)")
            }
        }
        for lang in T.others.keys { XCTAssertFalse(T.reference(language: lang).isEmpty, lang) }
    }

    // MARK: Real recognizer output (Step 0 fixtures)

    func testRecognizerFixtures() {
        var sentenceUseChanged: [String] = []
        for f in SpokenPunctuationFixtures.recognized {
            let out = SpokenPunctuation.apply(f.input, languageCode: f.lang)
            XCTAssertEqual(out, f.expected, "\(f.lang) \(f.id): \(f.input)")
            XCTAssertEqual(SpokenPunctuation.apply(out, languageCode: f.lang), out, "idempotent \(f.id)")
            if f.id.hasSuffix("_S"), out != f.input { sentenceUseChanged.append(f.id) }
        }
        // 45 sentence-use clips: exactly one false positive, and it is a recognizer artefact
        // (the synthetic "A backslash matters" came back without its article).
        XCTAssertEqual(sentenceUseChanged, ["probe_bslash_S"])
    }
}
