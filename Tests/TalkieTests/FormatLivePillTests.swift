import XCTest
@testable import Talkie

/// The pill's live text after a format command: regions in their format, the
/// command's own words left out (`FormatLivePreview.displayed`).
final class FormatLivePillTests: XCTestCase {
    private let book = FormatPhraseBook.builtIn

    private func placed(_ resolution: FormatSpanResolution, before: String, now: String,
                        said: Bool = true) -> FormatLivePreview.Placed? {
        FormatLivePreview.placed(resolution, saidAnything: said, before: before, now: now, book: book)
    }

    private func shown(_ text: String, _ commands: [FormatLivePreview.Placed], lang: String? = "en") -> String {
        FormatLivePreview.displayed(text, commands: commands, languageCode: lang)
    }

    // MARK: Where the command sits

    func testCommandWordsAreLocatedInTheLiveText() {
        let p = placed(.applied(.allCaps), before: "this is", now: "This is. All caps very urgent")
        XCTAssertEqual(p, .init(start: 2, end: 4, effect: .format(.preset(.allCaps))))
    }

    func testWordsShownLateAndWordsSaidAfterStayText() {
        // "need" was said before the key but appeared after it; "milk" came after
        // the second press. Only "bullet list" is the command.
        let p = placed(.applied(.bulletList), before: "I", now: "I need bullet list milk")
        XCTAssertEqual(p?.start, 2)
        XCTAssertEqual(p?.end, 4)
    }

    func testEndAndInsertAndUnrecognised() {
        XCTAssertEqual(placed(.ended, before: "one two", now: "one two normal text three")?.effect, .end)
        XCTAssertNil(placed(.notRecognised("banana"), before: "one", now: "one banana"))
        let address = UserCommand(name: "My address", phrases: ["my address"], action: .insert(text: "1 Main St"))
        let custom = FormatPhraseBook(disabledPresets: [], synonyms: [:], userCommands: [address])
        let p = FormatLivePreview.placed(.inserted(address), saidAnything: true, before: "send it to",
                                         now: "send it to my address please", book: custom)
        XCTAssertEqual(p, .init(start: 3, end: 5, effect: .insert("1 Main St")))
    }

    func testTwoPressesWithNothingSaidEndTheFormat() {
        let p = placed(.ended, before: "caps one two", now: "caps one two", said: false)
        XCTAssertEqual(p, .init(start: 3, end: 3, effect: .end))
    }

    func testPhraseThatCannotBeLocatedTakesAllHeardWords() {
        // Recognised from another language's reading: the live words are not the phrase.
        let p = placed(.applied(.allCaps), before: "eins", now: "eins all cups")
        XCTAssertEqual(p?.start, 1)
        XCTAssertEqual(p?.end, 3)
    }

    // MARK: What the pill shows

    func testWordsAfterTheCommandAreShownInTheFormat() {
        let caps = FormatLivePreview.Placed(start: 2, end: 4, effect: .format(.preset(.allCaps)))
        XCTAssertEqual(shown("This is all caps very urgent", [caps]), "This is VERY URGENT")
        // Right after the command, before anything else was said: just the text so far.
        XCTAssertEqual(shown("This is all caps", [caps]), "This is")
    }

    func testEndingReturnsToNormalText() {
        let commands: [FormatLivePreview.Placed] = [
            .init(start: 1, end: 3, effect: .format(.preset(.allCaps))),
            .init(start: 5, end: 7, effect: .end),
        ]
        XCTAssertEqual(shown("note all caps very urgent normal text thanks a lot", commands),
                       "note VERY URGENT thanks a lot")
    }

    func testListsQuotesParenthesesHeadingAndCode() {
        let at0 = { (preset: FormatPreset) in
            [FormatLivePreview.Placed(start: 1, end: 2, effect: .format(.preset(preset)))]
        }
        XCTAssertEqual(shown("Buy x milk. Eggs. Bread", at0(.bulletList)), "Buy\n- Milk\n- Eggs\n- Bread")
        XCTAssertEqual(shown("Buy x milk. Eggs", at0(.numberedList)), "Buy\n1. Milk\n2. Eggs")
        XCTAssertEqual(shown("Buy x milk. Eggs", at0(.todoList)), "Buy\n- [ ] Milk\n- [ ] Eggs")
        XCTAssertEqual(shown("Said x less is more", at0(.quotes)), "Said \u{201C}less is more\u{201D}")
        XCTAssertEqual(shown("Er sagte x weniger ist mehr", [.init(start: 2, end: 3, effect: .format(.preset(.quotes)))],
                             lang: "de"), "Er sagte \u{201E}weniger ist mehr\u{201C}")
        XCTAssertEqual(shown("Fine x see below", at0(.parentheses)), "Fine (see below)")
        XCTAssertEqual(shown("Intro x next steps", at0(.heading)), "Intro\n# Next steps")
        XCTAssertEqual(shown("Run x git status", at0(.verbatim)), "Run `git status`")
        XCTAssertEqual(shown("Title x Read Me", at0(.lowercase)), "Title read me")
    }

    func testModelFormatsAreShownAsHeard() {
        for preset in [FormatPreset.email, .formal, .shorter, .translateToEnglish, .translateToGerman] {
            XCTAssertFalse(FormatLivePreview.showsLive(.preset(preset)), preset.rawValue)
            let command = FormatLivePreview.Placed(start: 1, end: 2, effect: .format(.preset(preset)))
            XCTAssertEqual(shown("hello x can you send it", [command]).replacingOccurrences(of: "\n", with: " "),
                           "hello can you send it", preset.rawValue)
        }
        for preset in FormatPreset.allCases where !preset.usesModel {
            XCTAssertTrue(FormatLivePreview.showsLive(.preset(preset)), preset.rawValue)
        }
    }

    func testUserCommands() {
        let shout = UserCommand(name: "Shout", phrases: ["shout"], action: .textCase(.upper))
        let star = UserCommand(name: "Stars", phrases: ["stars"], action: .wrap(before: "**", after: "**"))
        let arrow = UserCommand(name: "Arrows", phrases: ["arrows"], action: .linePrefix("> "))
        let polite = UserCommand(name: "Polite", phrases: ["polite"], action: .rewrite(instruction: "be polite"))
        func at1(_ c: UserCommand) -> [FormatLivePreview.Placed] { [.init(start: 1, end: 2, effect: .format(.user(c)))] }
        XCTAssertEqual(shown("so x very loud", at1(shout)), "so VERY LOUD")
        XCTAssertEqual(shown("so x bold words", at1(star)), "so **bold words**")
        XCTAssertEqual(shown("so x first. Second", at1(arrow)), "so\n> First\n> Second")
        XCTAssertEqual(shown("so x send it", at1(polite)), "so send it")
        XCTAssertTrue(FormatLivePreview.showsLive(.user(shout)))
        XCTAssertFalse(FormatLivePreview.showsLive(.user(polite)))
        // A fixed text takes the command's place and leaves the format as it is.
        let insert = FormatLivePreview.Placed(start: 2, end: 4, effect: .insert("1 Main St"))
        XCTAssertEqual(shown("send to my address today", [insert]), "send to 1 Main St today")
    }

    func testNoCommandsMeansTheTextAsItIs() {
        XCTAssertEqual(shown("just some plain words", []), "just some plain words")
        XCTAssertEqual(shown("", []), "")
    }

    func testACommandBeyondTheTextWaits() {
        // The recogniser took words back after the command was placed.
        let caps = FormatLivePreview.Placed(start: 6, end: 8, effect: .format(.preset(.allCaps)))
        XCTAssertEqual(shown("only three words", [caps]), "only three words")
    }

    // MARK: Firm and still-changing parts

    func testFirmPartIsWhatTheCommittedWordsAlreadyProduce() {
        let caps = [FormatLivePreview.Placed(start: 1, end: 3, effect: .format(.preset(.allCaps)))]
        let a = FormatLivePreview.displayed(finalized: "note all caps very", volatile: "urgent now",
                                            commands: caps, languageCode: "en")
        XCTAssertEqual(a.firm, "note VERY")
        XCTAssertEqual(a.rest, " URGENT NOW")
        XCTAssertEqual(a.firm + a.rest, "note VERY URGENT NOW")

        let quotes = [FormatLivePreview.Placed(start: 0, end: 1, effect: .format(.preset(.quotes)))]
        let q = FormatLivePreview.displayed(finalized: "x less is", volatile: "more", commands: quotes,
                                            languageCode: "en")
        XCTAssertEqual(q.firm + q.rest, "\u{201C}less is more\u{201D}")
        XCTAssertEqual(q.firm, "\u{201C}less is")

        let list = [FormatLivePreview.Placed(start: 0, end: 1, effect: .format(.preset(.bulletList)))]
        let l = FormatLivePreview.displayed(finalized: "x milk.", volatile: "Eggs", commands: list, languageCode: "en")
        XCTAssertEqual(l.firm, "- Milk")
        XCTAssertEqual(l.rest, "\n- Eggs")

        let none = FormatLivePreview.displayed(finalized: "all firm", volatile: "", commands: [], languageCode: nil)
        XCTAssertEqual(none.firm, "all firm")
        XCTAssertEqual(none.rest, "")
    }

    func testSharedWordCountIgnoresRepunctuation() {
        XCTAssertEqual(FormatLivePreview.sharedWordCount(before: "ich brauche", after: "Ich brauche. Alles groß"), 2)
        XCTAssertEqual(FormatLivePreview.sharedWordCount(before: "", after: "bullet points"), 0)
        XCTAssertEqual(FormatLivePreview.sharedWordCount(before: "a b c", after: "a x"), 1)
    }
}
