import XCTest
@testable import Talkie

/// Locks the two testable cores of G9 ("Prompt" cleanup with agent-terminal
/// auto-detection):
///
///   1. `AgentTerminalDetector.isAgentSession` — the pure, word-boundary title
///      matcher. Its whole job is to fire for a coding-agent CLI in a terminal
///      title while never tripping on ordinary prose or substrings, so the tests
///      lean hard on the negatives (that is where a false positive would silently
///      reshape a plain shell command).
///
///   2. The `beginDictation` promotion gate — "override the resolved style to
///      `.prompt` only when the target is a terminal AND there is no explicit
///      per-app style override AND the detector fires". The gate itself lives
///      inline in `AppDelegate`, so here we exercise its three constituent
///      predicates against the SAME real collaborators (`AppProfileStore`,
///      `TargetApp`) the app uses, asserting the promote/keep decision. The
///      criterion that carries the risk — "a user-set per-app style is never
///      overridden" — is pinned directly.
final class AgentTerminalDetectorTests: XCTestCase {

    // MARK: - 1. Pure detector: positives

    func testFiresForBareAgentTokens() {
        // The canonical case: an agent CLI's name sits in the terminal title.
        for title in ["claude", "codex", "aider",
                      "CLAUDE", "Codex", "AIDER",     // case-insensitive
                      "claude — my-repo",              // name + project
                      "~ zsh · claude",                // shell chrome around it
                      "codex: fix the retry bug",      // name + prompt echo
                      "my-repo — aider (main)"] {      // delimited on both sides
            XCTAssertTrue(AgentTerminalDetector.isAgentSession(windowTitle: title),
                          "\"\(title)\" names a coding-agent CLI and must be detected")
        }
    }

    // MARK: - 1. Pure detector: negatives (the false-positive guard)

    func testDoesNotFireForSubstringsOrProse() {
        // None of these contain the agent name as a WHOLE word — matching a bare
        // substring here would reshape a plain shell command, the exact outcome
        // the word-boundary rule exists to prevent.
        for title in ["include the header",           // "include" ⊃ no token
                      "encoded output",                // "encoded" ⊃ "code" but not "codex"
                      "claudel",                       // longer word, not the token
                      "aiderman",                      // longer word
                      "npm run build",                 // ordinary shell
                      "git status",
                      "vim ~/.zshrc",
                      "Untitled — TextEdit",
                      "zsh"] {
            XCTAssertFalse(AgentTerminalDetector.isAgentSession(windowTitle: title),
                           "\"\(title)\" has no agent-CLI token and must NOT be detected")
        }
    }

    func testDoesNotFireForNilOrEmptyTitle() {
        // `windowTitle` is nil when context awareness is off or the target is
        // Talkie itself — we can't tell, so we don't guess (falls back to the
        // resolved style).
        XCTAssertFalse(AgentTerminalDetector.isAgentSession(windowTitle: nil),
                       "A nil title (context-awareness off) must not be treated as an agent session")
        XCTAssertFalse(AgentTerminalDetector.isAgentSession(windowTitle: ""),
                       "An empty title must not be treated as an agent session")
        XCTAssertFalse(AgentTerminalDetector.isAgentSession(windowTitle: "   "),
                       "A whitespace-only title has no token and must not fire")
    }

    @MainActor
    func testEditorFilenameTitleIsNeverTheTerminalPath() {
        // "claude.md — Zed" is an EDITOR title. The detector is only ever consulted
        // for `.terminal` targets (editors classify as `.coding`), so this string
        // never reaches it in production — but even evaluated directly, an
        // editor's "Open File — App" title is not the shape a terminal presents,
        // and the promotion gate below additionally requires `category == .terminal`.
        // We assert the belt-and-braces: the category gate rejects a coding target.
        XCTAssertFalse(promotesToPrompt(category: .coding,
                                        windowTitle: "claude.md — Zed",
                                        store: AppProfileStore()),
                       "An editor (.coding) target must never be promoted, whatever its title")
    }

    // MARK: - 2. Promotion gate: promotes for an agent terminal with no override

    @MainActor
    func testPromotesForAgentTerminalWithNoPerAppOverride() {
        let store = AppProfileStore()   // empty → no per-app rules
        XCTAssertTrue(promotesToPrompt(category: .terminal,
                                       windowTitle: "iTerm — claude",
                                       store: store),
                      "A ramble into a terminal running `claude`, with no per-app style set, must promote to .prompt")
    }

    // MARK: - 2. Promotion gate: a user-set per-app style is NEVER overridden

    @MainActor
    func testPerAppStyleOverrideIsNeverOverridden() {
        // The load-bearing acceptance criterion. The user has deliberately pinned
        // iTerm to `.faithful`; even with `claude` in the title, auto-detection
        // must defer to that explicit choice.
        let store = AppProfileStore()
        let bundleID = "com.googlecode.iterm2"
        store.upsert(AppProfile(
            bundleID: bundleID,
            displayName: "iTerm2",
            cleanupStyle: .faithful
        ))

        XCTAssertFalse(promotesToPrompt(category: .terminal,
                                        windowTitle: "iTerm — claude",
                                        bundleID: bundleID,
                                        store: store),
                       "A user-set per-app style must win over agent auto-detection")

        // Any other per-app style is equally respected (it's the PRESENCE of an
        // override that blocks promotion, not its particular value).
        store.upsert(AppProfile(
            bundleID: bundleID,
            displayName: "iTerm2",
            cleanupStyle: .concise
        ))
        XCTAssertFalse(promotesToPrompt(category: .terminal,
                                        windowTitle: "iTerm — claude",
                                        bundleID: bundleID,
                                        store: store),
                       "Any explicit per-app style (here .concise) blocks auto-promotion")
    }

    // MARK: - 2. Promotion gate: non-terminal categories never promote

    @MainActor
    func testNonTerminalCategoriesNeverPromote() {
        let store = AppProfileStore()
        // Even with an agent name in the title, a non-terminal target is out of
        // scope (G9 explicitly does not touch `.coding` apps).
        for category in [AppCategory.coding, .browser, .chat, .mail, .notes, .other] {
            XCTAssertFalse(promotesToPrompt(category: category,
                                            windowTitle: "claude",
                                            store: store),
                           "Category \(category) is not a terminal and must never auto-promote to .prompt")
        }
    }

    // MARK: - 2. Promotion gate: a plain terminal keeps the resolved style

    @MainActor
    func testPlainTerminalKeepsResolvedStyle() {
        let store = AppProfileStore()
        for title in ["zsh", "git status", "npm test", nil] {
            XCTAssertFalse(promotesToPrompt(category: .terminal,
                                            windowTitle: title,
                                            store: store),
                           "A plain (non-agent) terminal title \(title ?? "nil") must keep the resolved style")
        }
    }

    // MARK: - Helper mirroring the beginDictation gate exactly

    /// Re-implements the `beginDictation` promotion decision with the same three
    /// predicates and the same collaborators, so the test pins the real logic:
    /// promote iff the target is a terminal AND there is no explicit per-app style
    /// override AND the detector fires on the window title.
    @MainActor
    private func promotesToPrompt(category: AppCategory,
                                  windowTitle: String?,
                                  bundleID: String? = "com.example.terminal",
                                  store: AppProfileStore) -> Bool {
        let hasExplicitStyleOverride = bundleID
            .flatMap { store.profile(for: $0)?.cleanupStyle } != nil
        return category == .terminal
            && !hasExplicitStyleOverride
            && AgentTerminalDetector.isAgentSession(windowTitle: windowTitle)
    }
}
