import XCTest
@testable import Talkie

/// The routing corpus + pure-edit-computation gate for B9 (voice editing of
/// just-inserted text). Mirrors `CrossSurfaceFalsePositiveTests` in intent: the
/// edit path runs on the finalize path ahead of normal insertion whenever there's a
/// fresh dictation to edit, so a false positive here doesn't just misfire — it eats
/// the user's real spoken words and mutates the text they just dictated. Every
/// near-miss must fail CLOSED (parse to nil, or fail the containment kill switch, or
/// have no eligible target) so it inserts literally.
///
/// Two layers are exercised:
///   1. `EditCommandParser` — the pure parse + rightmost-occurrence edit + the
///      word-bounded case-insensitive containment check (the kill switch).
///   2. `CommandRouter.intent(for:lastInserted:)` — that the parser is wired in with
///      the right precedence and only fires when an eligible `lastInserted` exists.
@MainActor
final class EditCommandRoutingTests: XCTestCase {

    // A stub LLM so the router never needs a real on-device model (edit intents don't
    // use it, but the router holds one). Mirrors CommandRouterTests.
    private struct StubLLM: Summarizer {
        static var isAvailable: Bool { true }
        let requiresNetwork = false
        func generate(instructions: String, input: String) async -> String? { nil }
    }

    /// A router over an EMPTY macro set so a real/leaked user macro on this machine
    /// (the shared `MacroStore` loads `macros.json`) can't intercept a phrase and make
    /// a routing assertion flaky. Restores whatever it found.
    private func withEmptyMacros(_ body: (CommandRouter) -> Void) {
        let macros = MacroStore()
        let saved = macros.macros
        for macro in saved { macros.delete(macro) }
        defer { for macro in saved { macros.add(trigger: macro.trigger, expansion: macro.expansion) } }
        body(CommandRouter(macros: macros, summarizer: StubLLM()))
    }

    private func entry(_ text: String) -> DictationEntry {
        DictationEntry(timestampUnix: Date().timeIntervalSince1970, text: text,
                       appName: "TextEdit", appCategory: "writing", bundleID: "com.apple.TextEdit")
    }

    // MARK: - 1. Pure parse

    func testScratchThatParses() {
        XCTAssertEqual(EditCommandParser.parse("scratch that"), .scratch)
        XCTAssertEqual(EditCommandParser.parse("delete that"), .scratch)
        XCTAssertEqual(EditCommandParser.parse("Scratch that."), .scratch,
                       "trailing punctuation + casing are normalized away")
    }

    func testUndoIsNotAScratchTrigger() {
        XCTAssertNil(EditCommandParser.parse("undo"),
                     "'undo' is overloaded (undo the commit, ⌘Z) — only explicit scratch/delete-that qualify")
        XCTAssertNil(EditCommandParser.parse("undo that"))
    }

    func testReplaceAndChangeParse() {
        // Operands keep their spoken casing (so a capitalized replacement survives);
        // matching is case-insensitive downstream.
        XCTAssertEqual(EditCommandParser.parse("replace Sara with Sarah"),
                       .replace(find: "Sara", replacement: "Sarah"))
        XCTAssertEqual(EditCommandParser.parse("change nine to ten"),
                       .replace(find: "nine", replacement: "ten"))
    }

    /// The replacement may itself contain the separator word — the FIRST separator
    /// splits find|replacement, so "change Monday to next week to Friday" parses as
    /// find "Monday", replacement "next week to Friday".
    func testReplacementMayContainSeparatorWord() {
        XCTAssertEqual(EditCommandParser.parse("change Monday to next week to Friday"),
                       .replace(find: "Monday", replacement: "next week to Friday"))
    }

    func testReplaceMultiWordFindAndReplacement() {
        XCTAssertEqual(EditCommandParser.parse("replace the filter with a new cartridge"),
                       .replace(find: "the filter", replacement: "a new cartridge"))
    }

    /// Malformed replace forms don't parse (missing separator or empty side).
    func testMalformedReplaceDoesNotParse() {
        XCTAssertNil(EditCommandParser.parse("replace"), "no operands")
        XCTAssertNil(EditCommandParser.parse("replace foo"), "no separator")
        XCTAssertNil(EditCommandParser.parse("replace with bar"), "empty find")
        XCTAssertNil(EditCommandParser.parse("change foo to"), "empty replacement")
    }

    /// Prose that merely contains "replace"/"change" mid-sentence must not parse — the
    /// verb has to lead the whole utterance (whole-utterance command, like macros).
    func testProseContainingReplaceMidSentenceDoesNotParse() {
        XCTAssertNil(EditCommandParser.parse("we should replace the old server with a new one next quarter"),
                     "leads with 'we', not 'replace' — ordinary prose, must dictate literally")
        XCTAssertNil(EditCommandParser.parse("I need to change my flight to Tuesday"),
                     "leads with 'I', not 'change' — dictates literally")
    }

    // MARK: - 2. Pure edit computation (rightmost occurrence, casing)

    func testScratchEditIsEmpty() {
        XCTAssertEqual(EditCommandParser.edited(.scratch, in: "anything at all"), "")
    }

    func testReplaceSwapsRightmostOccurrence() {
        // "foo" appears twice; the LAST is the one you just spoke about.
        XCTAssertEqual(
            EditCommandParser.edited(.replace(find: "foo", replacement: "bar"), in: "foo and foo"),
            "foo and bar"
        )
    }

    func testReplacePreservesSurroundingText() {
        XCTAssertEqual(
            EditCommandParser.edited(.replace(find: "sara", replacement: "Sarah"), in: "meet Sara at nine"),
            "meet Sarah at nine",
            "case-insensitive find, replacement inserted verbatim, rest untouched"
        )
    }

    func testReplaceIsWordBoundedNotSubstring() {
        // "cat" must not match inside "category".
        XCTAssertNil(
            EditCommandParser.edited(.replace(find: "cat", replacement: "dog"), in: "the category is broad"),
            "a word-bounded find must not fire on a substring — inserts literally instead"
        )
        // But it matches a standalone word.
        XCTAssertEqual(
            EditCommandParser.edited(.replace(find: "cat", replacement: "dog"), in: "the cat is here"),
            "the dog is here"
        )
    }

    func testReplaceMultiWordPhrase() {
        XCTAssertEqual(
            EditCommandParser.edited(.replace(find: "the filter", replacement: "a new cartridge"),
                                     in: "please replace the filter today"),
            "please replace a new cartridge today"
        )
    }

    // MARK: - 3. The false-positive kill switch (containment)

    func testContainmentRequiresLiteralWordBoundedOccurrence() {
        XCTAssertTrue(EditCommandParser.contains("the filter", in: "swap the filter now"))
        XCTAssertTrue(EditCommandParser.contains("SARA", in: "meet Sara at nine"),
                      "case-insensitive")
        XCTAssertFalse(EditCommandParser.contains("cat", in: "the category is broad"),
                       "substring inside a word is NOT containment")
        XCTAssertFalse(EditCommandParser.contains("cartridge", in: "swap the filter now"),
                       "absent word fails the kill switch")
    }

    // MARK: - 4. Router precedence + eligibility

    /// With an eligible last dictation, "scratch that" routes to ScratchThatIntent.
    func testScratchRoutesWhenEligibleTargetExists() {
        withEmptyMacros { r in
            let intent = r.intent(for: "scratch that", lastInserted: entry("hello world"))
            XCTAssertEqual(intent?.id, "scratch-that")
            XCTAssertEqual(intent?.needsSelection, false, "the target is the last dictation, not an AX selection")
        }
    }

    /// With an eligible last dictation whose text contains X, "replace X with Y" routes
    /// to ReplaceWordIntent (the kill switch passes).
    func testReplaceRoutesWhenFindPresentInLastInserted() {
        withEmptyMacros { r in
            let intent = r.intent(for: "replace Sara with Sarah", lastInserted: entry("meet Sara at nine"))
            XCTAssertEqual(intent?.id, "replace-word")
        }
    }

    /// THE KILL SWITCH at the router boundary: "replace X with Y" where X is ABSENT
    /// from the just-dictated text must NOT route to an edit — it falls through (nil
    /// here, since no other parser claims it), so the phrase dictates literally.
    func testReplaceWithFindAbsentDoesNotRouteToEdit() {
        withEmptyMacros { r in
            let intent = r.intent(for: "replace the filter with a new cartridge",
                                  lastInserted: entry("meet Sara at nine"))
            XCTAssertNil(intent,
                         "X ('the filter') isn't in the dictated text — kill switch blocks the edit, dictates literally")
        }
    }

    /// No eligible last dictation → even a perfectly-formed edit command does not route
    /// (the dispatch site passes `lastInserted: nil` when the gate fails: wrong app,
    /// >45s, or the last insertion was left on the clipboard).
    func testNoEligibleTargetMeansNoEditRouting() {
        withEmptyMacros { r in
            XCTAssertNil(r.intent(for: "scratch that", lastInserted: nil),
                         "no fresh dictation to scratch — must not route, dictates literally")
            XCTAssertNil(r.intent(for: "replace Sara with Sarah", lastInserted: nil),
                         "no fresh dictation to edit — must not route, dictates literally")
        }
    }

    /// A near-miss that starts with the trigger word but isn't the command must NOT be
    /// treated as a scratch — "scratch that idea entirely" is prose.
    func testScratchThatIdeaEntirelyDictatesLiterally() {
        withEmptyMacros { r in
            XCTAssertNil(r.intent(for: "scratch that idea entirely", lastInserted: entry("some text")),
                         "not the whole-utterance 'scratch that' — dictates literally")
        }
    }

    // MARK: - 5. Fail-closed corpus (near-misses that must NOT route to an edit)
    //
    // Each is checked WITH an eligible target present (the strongest test: even when a
    // fresh dictation exists to edit, these must not fire). They must return nil so the
    // utterance dictates literally.

    func testEditNearMissCorpusDictatesLiterally() {
        // Give every phrase a last-inserted text that would MAKE the edit dangerous if
        // it fired (contains a word the phrase mentions), to prove the gate isn't just
        // failing on absent containment.
        let cases: [(spoken: String, lastInserted: String)] = [
            ("scratch that idea entirely", "the plan is good"),
            ("let's scratch the whole plan", "the plan is good"),
            ("I want to delete that file later", "the file is here"),
            ("delete that whole paragraph please", "a paragraph of text"),
            ("we should replace the old code with something cleaner", "the old code runs"),
            ("can you change the meeting to Thursday", "the meeting is set"),
            ("undo the last commit", "the commit landed"),
            ("replace the filter", "the filter is dirty"),            // no 'with Y'
            ("change the subject", "the subject line"),               // no 'to Y'
            ("scratching the surface of the topic", "the surface shines"),
        ]
        withEmptyMacros { r in
            for c in cases {
                XCTAssertNil(r.intent(for: c.spoken, lastInserted: entry(c.lastInserted)),
                             "near-miss must dictate literally: \u{201c}\(c.spoken)\u{201d}")
            }
        }
    }

    // MARK: - 6. End-to-end intent.run() produces the edited text

    func testReplaceIntentRunProducesEditedText() async {
        let macros = MacroStore()
        for m in macros.macros { macros.delete(m) }
        let r = CommandRouter(macros: macros, summarizer: StubLLM())
        let result = await r.run(
            spoken: "replace Sara with Sarah",
            selection: nil, target: .unknown, graph: .empty,
            lastInserted: entry("meet Sara at nine")
        )
        XCTAssertEqual(result?.replacement, "meet Sarah at nine",
                       "the intent computes the in-place edit deterministically")
        XCTAssertFalse(result?.preview ?? true,
                       "B9 edits execute immediately with an Undo pill, not a two-step preview")
    }

    func testScratchIntentRunProducesEmptyReplacement() async {
        let macros = MacroStore()
        for m in macros.macros { macros.delete(m) }
        let r = CommandRouter(macros: macros, summarizer: StubLLM())
        let result = await r.run(
            spoken: "scratch that",
            selection: nil, target: .unknown, graph: .empty,
            lastInserted: entry("hello world")
        )
        XCTAssertEqual(result?.replacement, "", "scratch deletes everything → empty replacement")
        XCTAssertEqual(result?.undoToken, "hello world", "the original is carried for Undo")
    }
}
