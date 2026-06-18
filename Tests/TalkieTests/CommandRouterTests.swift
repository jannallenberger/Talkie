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
}
