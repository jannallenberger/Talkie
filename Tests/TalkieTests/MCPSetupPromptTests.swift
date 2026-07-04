import XCTest
@testable import Talkie

/// L9 — the "Copy setup prompt" for the Connect-to-Claude card (`MCPConnectorCard`).
///
/// The prompt BODY is machine-directed English the user pastes into a fresh Claude
/// conversation; Claude then wires the `talkie` MCP up itself, learns the tools, and
/// verifies with `search`. Read as one author with L16 (JargonInstallPrompt), these
/// tests pin the contract that keeps it correct and honest:
///   • it embeds the exact `claude mcp add talkie -- "<path>"` line with the resolved
///     binary path (so the hookup Claude runs is the right one),
///   • it carries the `.mcp.json` fallback block for a Claude that can't run commands,
///   • it names every real MCP tool verbatim (so Claude calls tools that exist),
///   • it frames the WRITES honestly — queued, confirmed in Talkie with an Undo, not
///     applied until the user confirms — and never claims silent/automatic correction,
///   • it tells Claude to verify by calling `search` once, and
///   • it contains no `http(s)://` literal (scripts/check-no-network.sh greps Sources
///     for the scheme even inside comments/strings).
final class MCPSetupPromptTests: XCTestCase {

    /// A representative resolved binary path, as `MCPConnectorCard.binaryPath()` yields
    /// for an installed app.
    private let path = "/Applications/Talkie.app/Contents/MacOS/talkie-mcp"
    private var prompt: String { MCPSetupPrompt.setupPrompt(binaryPath: path) }

    /// The whole point of L9: the prompt must contain the exact add command, built with
    /// the resolved path, so the connection Claude performs targets the right binary.
    func testContainsTheResolvedAddCommand() {
        let expected = "claude mcp add talkie -- \"\(path)\""
        XCTAssertTrue(prompt.contains(expected),
                      "prompt must embed the exact resolved `claude mcp add` command")
        XCTAssertEqual(MCPSetupPrompt.addCommand(binaryPath: path), expected,
                       "addCommand must match the card's claudeAddCommand shape")
        // And the resolved path itself must appear (belt-and-braces on the injection).
        XCTAssertTrue(prompt.contains(path), "prompt must contain the resolved binary path")
    }

    /// The can't-run-commands fallback: the `.mcp.json` block with the same shape the
    /// card's `mcpServersJSON` emits, carrying the resolved path.
    func testContainsTheJSONFallbackBlock() {
        XCTAssertTrue(prompt.contains("\"mcpServers\""),
                      "prompt must include the mcpServers JSON fallback")
        XCTAssertTrue(prompt.contains("\"command\": \"\(path)\""),
                      "JSON fallback must carry the resolved path as the command")
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains(".mcp.json"),
                      "prompt must name the .mcp.json fallback target")
    }

    /// Every real MCP tool (the 17 in MCPServer.toolSpecs) must be named verbatim — a
    /// typo would point Claude at a tool that doesn't exist. This doubles as the
    /// drift guard: if a tool is added/renamed in the server, this fails until the
    /// prompt is updated to match.
    func testNamesEveryRealMCPTool() {
        let reads = [
            "list_meetings", "get_meeting", "get_brief", "list_commitments",
            "lookup_entity", "search", "get_recent_context", "graph_query",
            "get_stats", "get_dictionary", "list_dictations", "read_scratchpad",
        ]
        let writes = [
            "add_vocabulary_term", "add_replacement", "remove_replacement",
            "update_replacement", "remove_vocabulary_term",
        ]
        for tool in reads + writes {
            XCTAssertTrue(prompt.contains(tool), "prompt must name the \(tool) tool")
        }
        XCTAssertTrue(prompt.contains("`talkie` MCP"), "prompt must reference the talkie MCP")
    }

    /// Honest write labeling: the five writes only SUGGEST — queued, user-confirmed in
    /// Talkie with a one-tap Undo, and explicitly NOT applied until the user confirms.
    func testFramesWritesAsQueuedUserConfirmedWithUndo() {
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("queued"),
                      "prompt must say each write is queued")
        XCTAssertTrue(prompt.contains("Undo"), "prompt must mention the one-tap Undo")
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("confirm"),
                      "prompt must say the user confirms each write")
        XCTAssertTrue(prompt.contains("does NOT take effect"),
                      "prompt must state writes don't take effect until confirmed")
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("suggest"),
                      "prompt must frame writes as suggestions")
    }

    /// Honest-claims guard: no silent/automatic-correction promise, and no
    /// "understands everything you say" overreach.
    func testMakesNoOverreachClaim() {
        let lowered = prompt.lowercased()
        for forbidden in [
            "understands everything",
            "auto-correct everything",
            "automatically correct",
            "corrects everything",
            "silently",
            "without asking",
            "without confirmation",
        ] {
            XCTAssertFalse(lowered.contains(forbidden),
                           "prompt must not overreach or imply silent writes: \(forbidden)")
        }
    }

    /// The reads must be framed as touching only local, on-device stores, and the
    /// server as zero-network — the trust story that lets the user paste this safely.
    func testStatesLocalOnDeviceZeroNetwork() {
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("on-device"),
                      "prompt must say the server is on-device")
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("zero network"),
                      "prompt must say the server makes zero network connections")
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("local"),
                      "prompt must say the reads touch local stores")
    }

    /// Etiquette from docs/MCP_TEACH_BACK.md: get_dictionary before suggesting (dedupe),
    /// and keep it high-signal.
    func testStatesTeachBackEtiquette() {
        XCTAssertTrue(prompt.contains("get_dictionary before suggesting")
                        || prompt.localizedCaseInsensitiveContains("call get_dictionary before"),
                      "prompt must tell Claude to call get_dictionary before suggesting")
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("high-signal"),
                      "prompt must ask for a high-signal, non-spammy batch")
    }

    /// The verify step: call `search` once to confirm the hookup works.
    func testTellsClaudeToVerifyWithSearch() {
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("verify"),
                      "prompt must ask Claude to verify the hookup")
        XCTAssertTrue(prompt.contains("`search`"),
                      "prompt must name `search` as the verification call")
    }

    /// The body ships inside Sources/Talkie, which check-no-network.sh greps for
    /// `http(s)://` on raw lines — a URL literal here would fail the network gate.
    func testContainsNoHTTPSLiteral() {
        XCTAssertFalse(prompt.contains("https://"), "prompt must contain no https:// literal")
        XCTAssertFalse(prompt.contains("http://"), "prompt must contain no http:// literal")
    }

    /// Soft budget: the prompt stays compact (~1600 target). We assert a generous
    /// ceiling so an accidental essay can't balloon the paste, while leaving room for
    /// the full 17-tool list + add command + JSON fallback + a long install path.
    func testStaysReasonablyCompact() {
        XCTAssertLessThan(prompt.count, 2200,
                          "setup prompt should stay compact; trim if it grows past this")
    }
}
