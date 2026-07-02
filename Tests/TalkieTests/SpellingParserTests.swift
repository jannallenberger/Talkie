import XCTest
@testable import Talkie

/// The pure spelling-parser table: NATO alphabet, plain/quirk letter names, digits,
/// connectors, the "capital" modifier, and — critically — the conservative fall-through
/// that keeps ordinary prose starting with the verb "spell" from being eaten.
/// `SpellingParser.parse` is deterministic and side-effect free, so this is the whole
/// contract; the router precedence lives in `CommandRouterTests`.
final class SpellingParserTests: XCTestCase {

    // MARK: NATO alphabet — the reliable, documented path

    func testNatoSpellsTalkie() {
        XCTAssertEqual(
            SpellingParser.parse("spell tango alpha lima kilo india echo"), "talkie",
            "the NATO alphabet is the reliable path and must assemble contiguously")
    }

    func testNatoWithLiteralDigitAndDash() {
        // Acceptance criterion: "spell capital tango one two three dash x-ray" → "T123-x".
        // "x-ray" is a hyphenated letter-name kept WHOLE by the tokenizer (→ x), while the
        // standalone "dash" token is the connector. Covers capital + word-digits + a
        // spoken dash + the recognizer's constant "x-ray" spelling of X in one string.
        XCTAssertEqual(
            SpellingParser.parse("spell capital tango one two three dash x-ray"), "T123-x",
            "capital uppercases only the T; digits and the dash assemble in order, x-ray → x")
    }

    func testExRayHomophoneForX() {
        // The risks note calls out "ex-ray" by name as a recognizer spelling of X.
        XCTAssertEqual(
            SpellingParser.parse("spell ex-ray alpha yankee"), "xay",
            "ex-ray is the recognizer's other spelling of the letter X")
    }

    func testKubernetesShorthand() {
        // The headline example from the spec: "spell kilo-8-sierra" → "k8s".
        XCTAssertEqual(
            SpellingParser.parse("spell kilo-8-sierra"), "k8s",
            "hyphen-joined NATO+digit is the k8s escape hatch")
    }

    // MARK: Capitalization

    func testCapitalUppercasesNextLetterOnly() {
        XCTAssertEqual(
            SpellingParser.parse("spell capital tango alpha lima kilo"), "Talk",
            "'capital' uppercases only the immediately following letter")
    }

    func testCapitalPersistsAcrossConnector() {
        XCTAssertEqual(
            SpellingParser.parse("spell alpha dash capital bravo"), "a-B",
            "the capital flag survives an intervening connector and lands on the next letter")
    }

    // MARK: Digits

    func testSpokenDigitsBecomeNumerals() {
        XCTAssertEqual(
            SpellingParser.parse("spell one two three"), "123",
            "spoken digit names map to numerals")
    }

    func testLiteralDigitsPassThrough() {
        XCTAssertEqual(
            SpellingParser.parse("spell 8 6 7"), "867",
            "digits the recognizer already emitted pass straight through")
    }

    // MARK: Connectors

    func testConnectorsInsertLiterally() {
        XCTAssertEqual(
            SpellingParser.parse("spell alpha underscore bravo dot charlie"), "a_b.c",
            "underscore/dot connectors insert their literal glyph")
    }

    func testSpaceConnectorInserts() {
        XCTAssertEqual(
            SpellingParser.parse("spell alpha space bravo"), "a b",
            "output is contiguous unless 'space' is spoken")
    }

    func testAtAndSlash() {
        XCTAssertEqual(
            SpellingParser.parse("spell alpha at bravo slash charlie"), "a@b/c",
            "at and slash connectors assemble an email/path-like string")
    }

    // MARK: Recognizer-quirk letter homophones (the whole point of the table)

    func testRecognizerHomophoneSpellings() {
        // The recognizer garbles bare letters into homophones: b→"be", c→"sea",
        // x→"ex-ray"/"ex", y→"why". These must still spell.
        XCTAssertEqual(SpellingParser.parse("spell be see dee"), "bcd",
                       "be/see/dee homophones map to b/c/d")
        XCTAssertEqual(SpellingParser.parse("spell ex why zee"), "xyz",
                       "ex/why/zee homophones map to x/y/z")
        XCTAssertEqual(SpellingParser.parse("spell sea tea pea"), "ctp",
                       "sea/tea/pea homophones map to c/t/p")
    }

    func testBareSingleLettersHonored() {
        XCTAssertEqual(SpellingParser.parse("spell k 8 s"), "k8s",
                       "bare single letters the recognizer emits are honored alongside digits")
    }

    // MARK: The conservative fall-through (prose must NOT be eaten)

    func testProseStartingWithSpellFallsThrough() {
        // The load-bearing safety case: "spell it out for the team in the doc" is prose,
        // not a command — "it/out/for/the/team/in/doc" aren't all spellable, so parse
        // fails and the caller dictates it normally.
        XCTAssertNil(
            SpellingParser.parse("spell it out for the team in the doc"),
            "prose using 'spell' as a verb must fall through to normal dictation")
    }

    func testSingleSpellableTokenFallsThrough() {
        XCTAssertNil(
            SpellingParser.parse("spell alpha"),
            "one spellable token is below the ≥2 floor — likely the verb, so fall through")
    }

    func testCapitalPlusOneLetterFallsThrough() {
        // "capital" is a modifier, not a spellable unit, so "spell capital tango" has only
        // ONE spellable token and must fall through — the floor counts letters/digits,
        // not modifiers or connectors.
        XCTAssertNil(
            SpellingParser.parse("spell capital tango"),
            "capital + a single letter is one spellable token, below the floor")
    }

    func testConnectorsDoNotCountTowardFloor() {
        // "alpha dash" is one spellable + one connector — still below the ≥2 floor.
        XCTAssertNil(
            SpellingParser.parse("spell alpha dash"),
            "a connector is structural and does not count toward the ≥2 spellable floor")
    }

    func testUnknownTokenMidSpellFails() {
        XCTAssertNil(
            SpellingParser.parse("spell alpha bravo wubbleflorp"),
            "an unknown token anywhere fails the parse (conservative — don't guess)")
    }

    func testNoTriggerIsNotACommand() {
        XCTAssertNil(
            SpellingParser.parse("tango alpha lima kilo india echo"),
            "without a leading 'spell' trigger it is not a spelling command")
    }

    func testSpellThatTriggerAlsoWorks() {
        XCTAssertEqual(
            SpellingParser.parse("spell that kilo india echo lima"), "kiel",
            "'spell that' is an accepted trigger phrase")
    }

    // MARK: Robustness

    func testTrailingPunctuationTolerated() {
        XCTAssertEqual(
            SpellingParser.parse("spell alpha, bravo, charlie."), "abc",
            "punctuation the recognizer tacks on is trimmed per token")
    }

    func testEmptyAndTriggerOnly() {
        XCTAssertNil(SpellingParser.parse(""), "empty input is not a command")
        XCTAssertNil(SpellingParser.parse("spell"), "the bare trigger with no body is not a command")
    }
}
