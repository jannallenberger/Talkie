import XCTest
@testable import Talkie

/// Structural dictation commands: a free-standing "new line" / "new paragraph"
/// (EN) or "neue Zeile" / "neuer Absatz" (DE) becomes a real break; the SAME
/// words embedded in a phrase stay literal. This is a false-positive corpus —
/// the embedded-literal negatives are the load-bearing cases.
final class StructuralCommandsTests: XCTestCase {
    private func eq(_ input: String, _ expected: String, _ code: String? = "en",
                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(StructuralCommands.apply(input, languageCode: code),
                       expected, file: file, line: line)
    }

    // MARK: - English positives (free-standing → break)

    func testNewLineBetweenSentences() {
        eq("world. New line. Hello", "world\nHello")
    }

    func testNewParagraphBetweenSentences() {
        eq("First thought. New paragraph. Second thought.", "First thought\n\nSecond thought.")
    }

    func testNewLineUtteranceFinal() {
        eq("Sign it. New line", "Sign it\n")
    }

    func testNewParagraphUtteranceFinal() {
        eq("Sign it. New paragraph", "Sign it\n\n")
    }

    func testNewLineUtteranceInitial() {
        // Utterance-initial: the phrase is bounded by the text start and a period,
        // so it fires and the following word is capitalized.
        eq("New line. Hello there", "\nHello there")
    }

    func testSingleWordNewline() {
        // A sentence period was consumed on both sides, so the following word is
        // capitalized per the "capitalize when a boundary was consumed" rule.
        eq("done. newline. more", "done\nMore")
    }

    func testCommaDelimitedCommandSwallowsComma() {
        // A cleanup pass sometimes renders the parenthetical command with commas;
        // the break replaces them so no stray ", " survives.
        eq("here, new line, there", "here\nthere")
    }

    func testCapitalizesFollowingWordAfterPeriod() {
        eq("end of line. New line. next bit", "end of line\nNext bit")
    }

    // MARK: - English negatives (embedded → MUST stay literal)

    func testEmbeddedNewLineManager() {
        eq("the new line manager approved", "the new line manager approved")
    }

    func testEmbeddedNewParagraphOfContract() {
        eq("a new paragraph of the contract", "a new paragraph of the contract")
    }

    func testEmbeddedAddANewLineHere() {
        // "a" before and "here" after — both soft boundaries, no fire.
        eq("please add a new line here", "please add a new line here")
    }

    func testBareNewLineWithoutPunctuationDoesNotFire() {
        // No punctuation on the trailing side: conservatively left literal, because
        // this is where a false positive would be most costly.
        eq("New line hello world", "New line hello world")
    }

    func testNewLineAsSubjectMidSentence() {
        eq("the new paragraph looks good", "the new paragraph looks good")
    }

    func testNewLineFollowedByWordNoPunct() {
        eq("start a new line of code", "start a new line of code")
    }

    // MARK: - Multiple commands per utterance

    func testMultipleNewLines() {
        eq("First. New line. Second. New line. Third.", "First\nSecond\nThird.")
    }

    func testMixedLineAndParagraph() {
        eq("Intro. New paragraph. Body. New line. Aside.", "Intro\n\nBody\nAside.")
    }

    // MARK: - Idempotency (already broken → no double break)

    func testIdempotentWhenAlreadyBroken() {
        // Cleanup already turned the command into a real break; nothing literal is
        // left to match, so re-running inserts no second break.
        eq("world\nHello", "world\nHello")
    }

    func testApplyTwiceEqualsApplyOnce() {
        let once = StructuralCommands.apply("world. New line. Hello", languageCode: "en")
        let twice = StructuralCommands.apply(once, languageCode: "en")
        XCTAssertEqual(once, twice, "structural pass must be idempotent")
        XCTAssertEqual(twice, "world\nHello")
    }

    // MARK: - German positives

    func testGermanNeueZeile() {
        eq("Erster Satz. Neue Zeile. Zweiter Satz.", "Erster Satz\nZweiter Satz.", "de")
    }

    func testGermanNeuerAbsatz() {
        eq("Einleitung. Neuer Absatz. Hauptteil.", "Einleitung\n\nHauptteil.", "de")
    }

    func testGermanNeueZeileUtteranceFinal() {
        eq("Unterschrift. Neue Zeile", "Unterschrift\n", "de")
    }

    // MARK: - German negatives (embedded)

    func testGermanEmbeddedNeueZeile() {
        // "eine neue Zeile Code" — embedded, must stay literal.
        eq("das ist eine neue Zeile Code", "das ist eine neue Zeile Code", "de")
    }

    func testGermanEmbeddedNeuerAbsatz() {
        eq("ein neuer Absatz des Vertrags", "ein neuer Absatz des Vertrags", "de")
    }

    // MARK: - Language gating

    func testGermanPhraseInactiveUnderEnglish() {
        // Under an English locale the German phrase is not a command — stays literal.
        eq("Text. Neue Zeile. Text.", "Text. Neue Zeile. Text.", "en")
    }

    func testEnglishPhraseActiveUnderNilLocale() {
        // Unknown/nil language defaults to English handling.
        eq("world. New line. Hello", "world\nHello", nil)
    }

    func testEnglishPhraseInactiveUnderGerman() {
        // Under a German locale the English phrase is not treated as a command.
        eq("Text. New line. Text.", "Text. New line. Text.", "de")
    }

    // MARK: - Edge cases

    func testEmptyString() {
        eq("", "", "en")
    }

    func testNoCommandPlainProse() {
        eq("the quick brown fox jumps", "the quick brown fox jumps")
    }

    func testWholeUtteranceIsCommand() {
        eq("New line", "\n")
    }

    func testCaseInsensitiveTrigger() {
        // Recognizer/cleanup casing shouldn't matter to the trigger; the consumed
        // period still capitalizes the following word.
        eq("done. NEW LINE. more", "done\nMore")
    }
}
