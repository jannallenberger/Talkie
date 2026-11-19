import NaturalLanguage
import XCTest
@testable import Talkie

/// Second-pass review: ordinary sentences of someone who dictates instructions to a coding
/// agent and talks ABOUT punctuation, lines and edits. Written before the fixes; the
/// first pass (6d0d97f) changed 34 of the 45 literal sentences and missed 2 of the 23
/// commands. Pure string tests, nothing touches Application Support.
final class SpokenPunctuationAdversarialTests: XCTestCase {

    /// Must come back unchanged (talk about punctuation, sentence use).
    static let literal: [(lang: String, text: String)] = [
        ("de", "Fragezeichen oder Punkt?"),
        ("de", "Doppelpunkt, Semikolon und Slash"),
        ("de", "Schrägstrich oder Bindestrich, was ist besser?"),
        ("de", "Klammer auf und Klammer zu fehlen noch"),
        ("de", "Gedankenstrich und Bindestrich sind verschieden"),
        ("de", "Fragezeichen am Ende ist falsch"),
        ("de", "Kannst du Fragezeichen durch Punkte ersetzen"),
        ("de", "Backslash funktioniert unter Windows anders"),
        ("de", "Unterstrich statt Leerzeichen bitte"),
        ("de", "Mach aus dem Semikolon einen Doppelpunkt"),
        ("de", "Hier fehlt Doppelpunkt"),
        ("de", "Doppelpunkt statt Semikolon"),
        ("de", "Wir nehmen Slash statt Backslash"),
        ("de", "Bitte ersetz Doppelpunkt durch Gedankenstrich"),
        ("de", "Semikolon trennt die beiden Sätze"),
        ("de", "Ausrufezeichen wirken schnell aggressiv"),
        ("de", "Sternchen für gute Arbeit gibt es morgen"),
        ("de", "Setz das Fragezeichen ans Ende"),
        ("de", "Wo genau kommt der Schrägstrich hin"),
        ("de", "Er hat Anführungszeichen auf der Tastatur gesucht"),
        ("de", "Raute oder Sternchen, egal"),
        ("de", "Ist Doppelpunkt oder Semikolon richtig?"),
        ("de", "Gleichheitszeichen und Pluszeichen fehlen"),
        ("de", "dann machen wir in einer neuen Zeile darunter einmal das"),
        ("de", "Slash oder Backslash im Pfad?"),
        ("en", "colon or semicolon, which one?"),
        ("en", "Use slash or backslash"),
        ("en", "backslash matters in windows"),
        ("en", "We should slash prices"),
        ("en", "underscore the importance of tests"),
        ("en", "slash the prices by half"),
        ("en", "Question mark at the end, please"),
        ("en", "colon cancer screening is important"),
        ("en", "asterisk marks the footnote"),
        ("en", "em dash or en dash?"),
        ("en", "Ellipsis looks lazy here"),
        ("en", "Replace colon with semicolon"),
        ("en", "Hyphen versus dash"),
        ("en", "Semicolon separates the clauses"),
        ("en", "exclamation mark at the end of the title"),
        ("en", "Swap underscore for hyphen"),
        ("en", "plus sign and equals sign"),
        ("en", "open quote and close quote are both needed"),
        ("en", "Put a colon or a semicolon there"),
        ("en", "Then we put it on a new line below the result"),
    ]

    /// Must be replaced (a mark said on its own).
    static let commands: [(lang: String, text: String, expected: String)] = [
        ("de", "Hallo Doppelpunkt das ist ein Test", "Hallo: das ist ein Test"),
        ("de", "Kommst du morgen Fragezeichen", "Kommst du morgen?"),
        ("de", "Das ist super Ausrufezeichen", "Das ist super!"),
        ("de", "Bist du sicher Fragezeichen Kommst du mit", "Bist du sicher? Kommst du mit"),
        ("de", "Tee und Schrägstrich oder Kaffee", "Tee und/oder Kaffee"),
        ("de", "Klammer auf siehe unten Klammer zu", "(siehe unten)"),
        ("de", "Pfad Backslash Dokumente", "Pfad\\Dokumente"),
        ("de", "Funktion Unterstrich Name", "Funktion_Name"),
        ("de", "Zwei Optionen Doppelpunkt A oder B", "Zwei Optionen: A oder B"),
        ("de", "Fußnote Sternchen, siehe unten.", "Fußnote * siehe unten."),
        ("de", "Das Thema Raute wichtig", "Das Thema #wichtig"),
        ("de", "Achtung Doppelpunkt bitte nicht stören", "Achtung: bitte nicht stören"),
        ("de", "Hallo Fragezeichen Ausrufezeichen", "Hallo?!"),
        ("en", "Note colon this is important", "Note: this is important"),
        ("en", "Is this right question mark", "Is this right?"),
        ("en", "So we ship it M dash then we test.", "So we ship it—then we test."),
        ("en", "path backslash documents", "path\\documents"),
        ("en", "max at sign example dot com", "max@example dot com"),
        ("en", "Password, asterisk, asterisk.", "Password * *."),
        ("en", "The topic hash sign important.", "The topic #important."),
        ("en", "Wait ellipsis I'm not sure", "Wait… I'm not sure"),
        ("en", "coffee forward slash tea", "coffee/tea"),
        ("en", "Then open parenthesis as I said close parenthesis it works", "Then (as I said) it works"),
    ]

    private static func counts(_ run: (String, String) -> String) -> (falsePositives: [String], misses: [String]) {
        let fp = literal.filter { run($0.text, $0.lang) != $0.text }.map(\.text)
        let miss = commands.filter { run($0.text, $0.lang) != $0.expected }.map(\.text)
        return (fp, miss)
    }

    func testAdversarialSetWithTagger() throws {
        try XCTSkipUnless(SpokenPunctuation.taggerAvailable(.german) && SpokenPunctuation.taggerAvailable(.english),
                          "no lexical-class tagger model on this Mac")
        let r = Self.counts { SpokenPunctuation.apply($0, languageCode: $1) }
        print("ADVERSARIAL (tagger): false positives \(r.falsePositives.count)/\(Self.literal.count), misses \(r.misses.count)/\(Self.commands.count)")
        XCTAssertEqual(r.falsePositives, [])
        XCTAssertEqual(r.misses, [])
    }

    /// Without the tagger (a Mac or CI runner without the NaturalLanguage model) the word
    /// lists alone must still keep every literal sentence; only the listed sentences that
    /// need a word class stay unprotected.
    func testAdversarialSetWithWordListsOnly() {
        let r = Self.counts { SpokenPunctuation.apply($0, languageCode: $1, useTagger: false) }
        print("ADVERSARIAL (lists only): false positives \(r.falsePositives.count)/\(Self.literal.count), misses \(r.misses.count)/\(Self.commands.count)")
        XCTAssertEqual(r.falsePositives, Self.needsTagger)
        XCTAssertEqual(r.misses, [])
    }

    /// The literal sentences only the tagger protects (a verb or adjective it recognises).
    static let needsTagger: [String] = []

    func testAdversarialSetIsIdempotent() {
        for c in Self.commands {
            let once = SpokenPunctuation.apply(c.text, languageCode: c.lang)
            XCTAssertEqual(SpokenPunctuation.apply(once, languageCode: c.lang), once, c.text)
        }
    }
}
