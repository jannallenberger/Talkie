import XCTest
@testable import Talkie

/// L16 — the "Install my jargon" copy-prompt for Claude.
///
/// The prompt BODY is machine-directed English pasted into Claude, which then uses
/// the `talkie` MCP to read how the user talks and suggest dictionary terms via L15's
/// teach-back tools. These tests pin the contract that keeps the prompt honest and
/// consistent with docs/MCP_TEACH_BACK.md:
///   • it names the real MCP tools (so Claude calls tools that exist),
///   • it tells Claude to call `get_dictionary` FIRST to avoid duplicates,
///   • it states the confirm-with-Undo etiquette (nothing is applied silently),
///   • it makes NO auto-correct / silent-correction claim, and
///   • it contains no `https://` literal (scripts/check-no-network.sh greps Sources).
final class JargonInstallPromptTests: XCTestCase {

    private var body: String { JargonInstallPrompt.body() }

    /// Every real teach-back / read tool the prompt directs Claude to use must be
    /// named verbatim — a typo here would send Claude at a tool that doesn't exist.
    func testNamesTheRealMCPTools() {
        for tool in [
            "get_dictionary",
            "add_vocabulary_term",
            "add_replacement",
            "remove_replacement",
            "update_replacement",
            "remove_vocabulary_term",
        ] {
            XCTAssertTrue(body.contains(tool), "prompt must name the \(tool) tool")
        }
        // It must point Claude at the `talkie` MCP by name.
        XCTAssertTrue(body.contains("`talkie` MCP"), "prompt must reference the talkie MCP")
    }

    /// The dedupe step: call get_dictionary FIRST, and don't re-suggest what's there.
    func testInstructsGetDictionaryFirstForDedupe() {
        XCTAssertTrue(body.contains("First call `get_dictionary`"),
                      "prompt must tell Claude to call get_dictionary first")
        XCTAssertTrue(body.localizedCaseInsensitiveContains("already"),
                      "prompt must warn against suggesting entries already present")
    }

    /// The trust model, mirrored from MCP_TEACH_BACK.md: queued, confirm, Undo, and
    /// explicitly NOT applied until the user confirms.
    func testStatesConfirmWithUndoEtiquette() {
        XCTAssertTrue(body.localizedCaseInsensitiveContains("confirm"),
                      "prompt must say the user confirms each suggestion")
        XCTAssertTrue(body.contains("Undo"), "prompt must mention the one-tap Undo")
        XCTAssertTrue(body.localizedCaseInsensitiveContains("queue"),
                      "prompt must say each call is queued")
        XCTAssertTrue(body.localizedCaseInsensitiveContains("suggestion"),
                      "prompt must frame the calls as suggestions, not applied changes")
    }

    /// Honest-claims guard: the prompt must never promise silent/automatic correction.
    func testMakesNoAutoCorrectClaim() {
        let lowered = body.lowercased()
        for forbidden in [
            "auto-correct everything",
            "automatically correct",
            "corrects everything",
            "silently",
            "without asking",
            "no confirmation",
        ] {
            XCTAssertFalse(lowered.contains(forbidden),
                           "prompt must not imply silent/automatic correction: \(forbidden)")
        }
    }

    /// The body ships inside Sources/Talkie, which check-no-network.sh greps for
    /// `https://` on raw lines — a URL literal here would fail the network gate.
    func testContainsNoHTTPSLiteral() {
        XCTAssertFalse(body.contains("https://"), "prompt body must contain no https:// literal")
        XCTAssertFalse(body.contains("http://"), "prompt body must contain no http:// literal")
    }

    /// It must actually direct Claude to read its OWN session context (A2 note: Talkie
    /// reads ~/.claude JSONL for learning; the PROMPT asks Claude to read its own
    /// sessions), not to ask Talkie for the conversation.
    func testDirectsClaudeToReadItsOwnSessions() {
        XCTAssertTrue(body.localizedCaseInsensitiveContains("recent sessions"),
                      "prompt must have Claude look at recent sessions")
        XCTAssertTrue(body.localizedCaseInsensitiveContains("session context"),
                      "prompt must say Claude reads its own session context")
    }
}
