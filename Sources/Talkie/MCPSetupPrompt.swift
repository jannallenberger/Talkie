import Foundation

/// L9 — the "Copy setup prompt" for the Connect-to-Claude card (`MCPConnectorCard`).
///
/// A sibling of L16's "Install my jargon" prompt: instead of the JSON config and the
/// `claude mcp add` one-liner (which a human runs), this hands the user a ready-made
/// *prompt* they paste into a fresh Claude conversation. Claude then wires the Talkie
/// MCP up itself — it runs the add command (or writes the config), learns which tools
/// the connector exposes and how to use them honestly, and verifies the hookup by
/// calling `search` once.
///
/// The prompt BODY is machine-directed English and is deliberately NOT localized (same
/// class as the card's `mcpServersJSON`/`claudeAddCommand` and L16's body) — it is read
/// by Claude, not the user. The surrounding UI chrome (the button label) IS localized
/// via `.loc`. The body must contain no URL literal — scripts/check-no-network.sh greps
/// Sources for the http/https scheme even inside comments — and, read as one author with
/// L16, it must stay honest: the reads run on demand, every WRITE is QUEUED and the user
/// confirms it in Talkie with a one-tap Undo. It never claims Talkie "understands
/// everything you say" or that Claude changes the dictionary silently.
enum MCPSetupPrompt {

    /// The resolved connect recipe — the single source both L9 surfaces use (the card's
    /// "Copy command" button delegates here), so they never disagree. It's an
    /// *idempotent replace at user scope*, not a bare add, because the real-world case
    /// is a returning user who already has a (now-stale) `talkie` registered: a plain
    /// `claude mcp add` would error "already exists" and silently keep the old one.
    /// Dropping any user-scope copy first (`2>/dev/null; ` so the add always runs) and
    /// adding at `-s user` — resolvable from every directory, not just the cwd — is
    /// exactly what removes the stale-registration + wrong-scope trap.
    static func addCommand(binaryPath: String) -> String {
        "claude mcp remove talkie -s user 2>/dev/null; claude mcp add talkie -s user -- \"\(binaryPath)\""
    }

    /// The `.mcp.json` fallback block, matching the card's `mcpServersJSON` shape, for
    /// a Claude that can't run shell commands. Two JSON-significant characters escaped
    /// defensively (macOS paths don't contain them in practice).
    static func mcpServersJSON(binaryPath: String) -> String {
        let escaped = binaryPath.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "mcpServers": {
            "talkie": {
              "command": "\(escaped)"
            }
          }
        }
        """
    }

    /// The English, machine-directed prompt the user copies and pastes into Claude.
    ///
    /// It tells Claude (a) what Talkie's MCP is — a tiny local, 100%-on-device server,
    /// zero network; (b) exactly how to connect it: run the resolved `claude mcp add`
    /// line, or write the JSON block if it can't run commands; (c) the tool surface,
    /// one line each — the reads it can call on demand, and the five dictionary WRITES,
    /// each marked "queued — you confirm in Talkie with an Undo"; (d) the teach-back
    /// etiquette from docs/MCP_TEACH_BACK.md (suggest, don't ask-then-wait; one call per
    /// genuinely new/wrong term; nothing takes effect until the user confirms); and
    /// (e) how to verify — call `search` once. Kept compact — well under 2K characters
    /// with a full install path; the prose is trimmed hard so the 17-tool list, the add
    /// command, and the JSON fallback all fit a single comfortable paste.
    static func setupPrompt(binaryPath: String) -> String {
        """
        Set up Talkie's MCP for yourself. Talkie is my local dictation app; its `talkie` \
        MCP is a tiny bundled binary that runs 100% on-device with zero network — nothing \
        it exposes leaves my Mac.

        First run `claude mcp list`. If a `talkie` is already there (stale after an app \
        update), remove it in whatever scope it shows, then add the current one and \
        reconnect your MCP servers:
        \(addCommand(binaryPath: binaryPath))
        Or, if you can't run commands, add this to my `.mcp.json`:
        \(mcpServersJSON(binaryPath: binaryPath))

        You'll then have these `talkie` tools. Reads only touch my local stores:
        - search — semantic + keyword search over meetings, dictations, entities
        - get_recent_context — what I dictated / met about / mentioned lately
        - graph_query — what's known about one person/project/term, with provenance
        - get_stats — lifetime dictation stats (words, WPM, streak)
        - get_dictionary — my vocabulary terms and spoken→written rules
        - list_dictations — recent dictations, newest first
        - read_scratchpad — my notes and checkbox tasks (read-only)
        - list_meetings / get_meeting — recent meetings; one full meeting
        - list_commitments — action items from meetings
        - get_brief — today's on-device brief
        - lookup_entity — resolve a person/project/term by name

        Writes only SUGGEST: each is queued and I confirm it in Talkie with a one-tap \
        Undo — it does NOT take effect until I do, so just call it and tell me what you \
        queued.
        - add_vocabulary_term — teach a name/product/acronym its spelling
        - add_replacement — map a misheard form to what I meant (get hub → GitHub)
        - remove_replacement / update_replacement — remove or retarget a rule
        - remove_vocabulary_term — remove a term

        Call get_dictionary before suggesting so you don't duplicate what I have; keep \
        it high-signal — one call per genuinely new or wrong term, no common words.

        Verify: confirm `get_dictionary` is in your tools (if missing, you're on an old \
        build — tell me to update Talkie.app), then call `search` once and tell me it \
        came back.
        """
    }
}
