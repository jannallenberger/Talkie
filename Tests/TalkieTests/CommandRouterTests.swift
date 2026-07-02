import XCTest
@testable import Talkie

/// Guards the contract the voice-command call site in `AppDelegate` relies on:
/// a *matched* command whose on-device model is unavailable must surface as a
/// `nil` result, so the call site can show an error and STOP — rather than
/// falling through and typing the literal spoken command ("translate to German")
/// into the document as if it were dictation (P2-03, code-review ship-blocker).
@MainActor
final class CommandRouterTests: XCTestCase {
    /// Stand-in for the on-device LLM. `output == nil` simulates the model being
    /// unavailable or refusing — the exact case `OnDeviceLLM.generate` collapses to nil.
    private struct StubLLM: Summarizer {
        static var isAvailable: Bool { true }
        let requiresNetwork = false
        let output: String?
        func generate(instructions: String, input: String) async -> String? { output }
    }

    private func router(_ output: String?) -> CommandRouter {
        CommandRouter(macros: MacroStore(), summarizer: StubLLM(output: output))
    }

    /// The ship-blocker contract: matched rewrite + unavailable model → nil.
    func testRewriteReturnsNilWhenModelUnavailable() async {
        let result = await router(nil).run(
            spoken: "make this a list",            // leading imperative → RewriteIntent
            selection: "buy milk eggs bread",      // non-empty selection
            target: .unknown,
            graph: .empty
        )
        XCTAssertNil(result, "an unavailable model must yield nil so the call site refuses to type the command")
    }

    /// The happy path still works: matched rewrite + available model → result.
    func testRewriteReturnsResultWhenModelAvailable() async {
        let rewritten = "- buy milk\n- eggs\n- bread"
        let result = await router(rewritten).run(
            spoken: "make this a list",
            selection: "buy milk eggs bread",
            target: .unknown,
            graph: .empty
        )
        XCTAssertEqual(result?.replacement, rewritten)
        XCTAssertTrue(result?.preview ?? false, "a mutating rewrite always previews before injecting")
    }

    /// Ordinary speech is not a command, so it returns nil and flows to dictation.
    func testPlainSpeechIsNotACommand() async {
        let result = await router("ignored").run(
            spoken: "the weather is nice today",
            selection: nil,
            target: .unknown,
            graph: .empty
        )
        XCTAssertNil(result)
    }

    // MARK: Spelling command (A13) routing precedence

    /// A spelling command resolves to `SpellingIntent` and assembles the exact string —
    /// no selection, no model. The output must NOT depend on the (here-unavailable) LLM.
    func testSpellingCommandRoutesAndInsertsAssembledString() async {
        let result = await router(nil).run(          // model unavailable — must not matter
            spoken: "spell tango alpha lima kilo india echo",
            selection: nil,
            target: .unknown,
            graph: .empty
        )
        XCTAssertEqual(result?.replacement, "talkie",
                       "a spelling command assembles the letters deterministically, no model needed")
        XCTAssertFalse(result?.preview ?? true,
                       "spelling is deterministic — it inserts directly like a macro, no preview")
    }

    /// The intent is specifically `SpellingIntent`, and it needs no selection — so it can
    /// never be lost the way a `needsSelection` intent with no selection would be.
    func testSpellingIntentTypeAndNoSelectionRequired() {
        let intent = router(nil).intent(for: "spell capital tango one two three dash x-ray")
        XCTAssertEqual(intent?.id, "spell", "a well-formed spell utterance routes to SpellingIntent")
        XCTAssertEqual(intent?.needsSelection, false, "spelling inserts at the cursor, never needs a selection")
    }

    /// Prose that merely starts with the verb "spell" must fall through to dictation —
    /// the parser's ≥2-spellable-token floor is what protects this, checked via the router.
    func testProseStartingWithSpellIsNotACommand() {
        XCTAssertNil(router(nil).intent(for: "spell it out for the team in the doc"),
                     "'spell' used as an ordinary verb is not a command and must dictate normally")
    }

    /// A whole-utterance macro still wins over the spelling parser (precedence: macro >
    /// spell). If a user teaches a macro whose trigger happens to be a spellable phrase,
    /// their macro takes priority.
    func testMacroWinsOverSpelling() {
        let macros = MacroStore()
        macros.add(trigger: "spell alpha bravo", expansion: "EXPANDED")
        let r = CommandRouter(macros: macros, summarizer: StubLLM(output: nil))
        let intent = r.intent(for: "spell alpha bravo")
        XCTAssertEqual(intent?.id, "insert-macro", "a matching macro outranks the spelling parser")
    }
}
