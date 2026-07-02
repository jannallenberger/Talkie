import XCTest
@testable import Talkie

/// A2 — learning corrections from Claude Code prompts (the AX-blind coding/terminal
/// surface). The scan is pure and exhaustively fixture-tested here: given the text
/// Talkie inserted and a Claude Code transcript, decide whether the submitted prompt
/// is a respelling of that text and, if so, what single correction to learn.
///
/// The guards that keep it safe mirror the live AX watcher's (`CorrectionExtractor`):
/// a candidate must LOOSELY CONTAIN the inserted text (≥70% of its tokens) before it's
/// even considered "the same utterance, edited", and the diff itself must be a clean
/// single-region respelling — never an unrelated prompt, never array/tool content,
/// never a change to the user's own surrounding prose.
final class ClaudeTranscriptLearnerTests: XCTestCase {

    // A fixed base instant so window math is exact and reproducible (not wall-clock).
    private let base: Double = 1_760_000_000   // 2025-10-09T…Z, arbitrary but stable

    /// Render a Unix time as the ISO-8601-with-fractional-seconds stamp Claude Code
    /// writes, so the parser is exercised on the real format.
    private func iso(_ unix: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: unix))
    }

    /// One `type:"user"` JSONL line with string content at time `unix`.
    private func userLine(_ content: String, at unix: Double) -> String {
        let payload: [String: Any] = [
            "type": "user",
            "timestamp": iso(unix),
            "message": ["role": "user", "content": content],
            "cwd": "/Users/jann/Talkie",
            "gitBranch": "main",
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }

    /// A `type:"user"` line whose content is an ARRAY (a tool_result echo) — must be
    /// ignored as not-human-typed.
    private func toolResultLine(at unix: Double) -> String {
        let payload: [String: Any] = [
            "type": "user",
            "timestamp": iso(unix),
            "message": ["role": "user", "content": [["type": "tool_result", "content": "claude.md exists"]]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }

    private func assistantLine(_ content: String, at unix: Double) -> String {
        let payload: [String: Any] = [
            "type": "assistant",
            "timestamp": iso(unix),
            "message": ["role": "assistant", "content": content],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }

    // MARK: Pure extraction — the headline acceptance case

    /// Dictate "update the cloud MD file", edit to "claude.md" before submitting →
    /// we learn `cloud md` → `claude.md` (or whatever contiguous respelling the
    /// shared extractor isolates), exactly as if the field had been watched.
    func testLearnsClaudeMdRespelling() {
        let inserted = "update the cloud MD file"
        let submitted = "update the claude.md file"
        let hit = ClaudeTranscriptScan.extractLearnableCorrection(
            inserted: inserted, candidates: [submitted]
        )
        XCTAssertNotNil(hit, "a close respelling in the submitted prompt should be learned")
        XCTAssertEqual(hit?.to.lowercased(), "claude.md",
                       "the learned target is the spelling the user actually submitted")
    }

    /// A single-word respelling of a jargon term Talkie mangled.
    func testLearnsSingleWordRespelling() {
        let hit = ClaudeTranscriptScan.extractLearnableCorrection(
            inserted: "run the correlate migration",
            candidates: ["run the Coralate migration"]
        )
        XCTAssertEqual(hit?.from.lowercased(), "correlate")
        XCTAssertEqual(hit?.to.lowercased(), "coralate")
    }

    // MARK: The "merely mentions the words" false-positive guard

    /// A prompt that repeats the inserted text UNCHANGED is not a correction —
    /// nothing to learn (acceptance criterion: mentions produce no rule).
    func testUnchangedPromptLearnsNothing() {
        let text = "update the cloud MD file"
        XCTAssertNil(ClaudeTranscriptScan.extractLearnableCorrection(inserted: text, candidates: [text]),
                     "an identical prompt is not a correction")
    }

    /// A prompt that shares only a couple of words with the insertion (below the 70%
    /// overlap bar) never even reaches the diff — it's a different utterance.
    func testUnrelatedPromptBelowOverlapLearnsNothing() {
        let inserted = "update the cloud MD file with the new endpoints"
        let unrelated = "please also update the README"   // shares ~2 tokens of 8
        XCTAssertFalse(
            ClaudeTranscriptScan.looseContains(
                unrelated, insertedTokens: ClaudeTranscriptScan.normalizedTokens(inserted)),
            "a prompt sharing a couple of words is under the overlap bar")
        XCTAssertNil(ClaudeTranscriptScan.extractLearnableCorrection(inserted: inserted, candidates: [unrelated]))
    }

    /// A word SWAP (not a respelling) is rejected by the shared plausibility floor,
    /// even when the rest of the sentence lines up.
    func testWordSwapRejected() {
        let hit = ClaudeTranscriptScan.extractLearnableCorrection(
            inserted: "deploy the staging server now",
            candidates: ["deploy the production server now"]   // staging→production: a swap
        )
        XCTAssertNil(hit, "a swap to a different word isn't a plausible respelling")
    }

    // MARK: looseContains threshold

    func testLooseContainsBagOverlapPath() {
        let tokens = ClaudeTranscriptScan.normalizedTokens("one two three four five")   // 5 tokens
        // 4 of 5 present, scrambled = 0.8 ≥ 0.70 → contained via the bag-overlap path
        // (order/punctuation-insensitive), and NO contiguous anchor (fully reordered).
        XCTAssertTrue(ClaudeTranscriptScan.looseContains("Two, one! four three.", insertedTokens: tokens))
        // Only 2 shared words, scattered, no aligned prefix/suffix → neither path fires.
        XCTAssertFalse(ClaudeTranscriptScan.looseContains("three alpha five beta gamma delta", insertedTokens: tokens))
    }

    /// The contiguous-anchor path: a single localized respelling keeps an aligned
    /// prefix + suffix even when the changed words drop bag overlap below 70%.
    func testLooseContainsAnchorPath() {
        let tokens = ClaudeTranscriptScan.normalizedTokens("update the cloud MD file")   // 5 tokens
        // "update the" + "file" = 3/5 aligned = 0.60 anchor, though only 3/5 bag overlap.
        XCTAssertTrue(ClaudeTranscriptScan.looseContains("update the claude.md file", insertedTokens: tokens))
        // Same words, but no aligned prefix/suffix (the shared words are jumbled) →
        // the anchor path does NOT fire, and bag overlap (3/5) is under the bar.
        XCTAssertFalse(ClaudeTranscriptScan.looseContains("file the update", insertedTokens: tokens))
    }

    func testNormalizationFoldsCaseDiacriticsPunctuation() {
        XCTAssertEqual(ClaudeTranscriptScan.normalizeForMatch("Café,"), "cafe")
        XCTAssertEqual(ClaudeTranscriptScan.normalizeForMatch("`claude.md`"), "claude.md")
        XCTAssertEqual(ClaudeTranscriptScan.normalizedTokens("  Hello,   WORLD!  "), ["hello", "world"])
    }

    // MARK: JSONL parsing — schema, content shape, time window

    /// The parser keeps only string-content user prompts inside the window; it drops
    /// array (tool_result) content, assistant lines, and out-of-window prompts.
    func testJSONLKeepsOnlyInWindowUserStringPrompts() {
        let jsonl = [
            userLine("in window prompt one", at: base + 10),
            toolResultLine(at: base + 11),                    // array content → skip
            assistantLine("assistant reply", at: base + 12),  // not a user line → skip
            userLine("way after the window", at: base + 9_999),
            userLine("before the window", at: base - 9_999),
            userLine("in window prompt two", at: base + 20),
        ].joined(separator: "\n")

        let prompts = ClaudeTranscriptScan.userPrompts(fromJSONL: jsonl, within: base...(base + 100))
        XCTAssertEqual(prompts.map(\.text), ["in window prompt one", "in window prompt two"],
                       "only string-content user lines within the window survive")
    }

    /// Malformed / partial lines are swallowed, never thrown — the schema is
    /// Anthropic-internal and may drift, so a bad line is a no-op.
    func testMalformedLinesAreSkipped() {
        let jsonl = [
            "{not valid json",
            "",
            "   ",
            #"{"type":"user"}"#,                                   // no message/timestamp
            #"{"type":"user","timestamp":"nonsense","message":{"content":"x"}}"#,  // bad stamp
            userLine("the good one", at: base + 5),
        ].joined(separator: "\n")
        let prompts = ClaudeTranscriptScan.userPrompts(fromJSONL: jsonl, within: base...(base + 100))
        XCTAssertEqual(prompts.map(\.text), ["the good one"])
    }

    func testISO8601ParsingBothFormats() {
        XCTAssertNotNil(ClaudeTranscriptScan.parseISO8601("2026-07-02T18:32:26.839Z"),
                        "fractional-seconds stamps (the observed format) parse")
        XCTAssertNotNil(ClaudeTranscriptScan.parseISO8601("2026-07-02T18:32:26Z"),
                        "second-resolution stamps parse via the fallback")
        XCTAssertNil(ClaudeTranscriptScan.parseISO8601("not a date"))
    }

    // MARK: File collection over a fixture ~/.claude/projects tree

    /// Build a temp `projects/<session>/…jsonl` tree, then confirm collection reads
    /// across MULTIPLE sessions, honors the window, and skips files whose mtime is
    /// older than the insertion (the cheap stale-session prefilter).
    func testCollectPromptsAcrossSessionsAndMtime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-scan-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let sessionA = projects.appendingPathComponent("proj-a", isDirectory: true)
        let sessionB = projects.appendingPathComponent("proj-b", isDirectory: true)
        for d in [sessionA, sessionB] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let insertion = base + 1000
        let window = (insertion - 5)...(insertion + 150)

        // Fresh session A: an in-window prompt. Written now, so its mtime is current.
        let fileA = sessionA.appendingPathComponent("a.jsonl")
        try userLine("prompt from session A in window", at: insertion + 30)
            .write(to: fileA, atomically: true, encoding: .utf8)

        // Fresh session B: a different in-window prompt.
        let fileB = sessionB.appendingPathComponent("b.jsonl")
        try userLine("prompt from session B in window", at: insertion + 40)
            .write(to: fileB, atomically: true, encoding: .utf8)

        // A stale file whose mtime predates the insertion — must be skipped even
        // though its (impossible) in-window line would otherwise match.
        let stale = sessionA.appendingPathComponent("stale.jsonl")
        try userLine("should never be read", at: insertion + 35)
            .write(to: stale, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: insertion - 10_000)], ofItemAtPath: stale.path)

        let prompts = ClaudeTranscriptLearner.collectPrompts(
            under: projects, within: window, notBefore: insertion - 5)
        let texts = Set(prompts.map(\.text))
        XCTAssertTrue(texts.contains("prompt from session A in window"))
        XCTAssertTrue(texts.contains("prompt from session B in window"))
        XCTAssertFalse(texts.contains("should never be read"),
                       "a file older than the insertion is skipped by the mtime prefilter")
    }

    /// Collection over a directory that doesn't exist is an empty result, not a crash
    /// — the common case where the user has never run Claude Code.
    func testCollectPromptsMissingDirectoryIsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)/projects")
        XCTAssertTrue(ClaudeTranscriptLearner.collectPrompts(
            under: missing, within: base...(base + 100), notBefore: base).isEmpty)
    }

    // MARK: Consent gate (tri-state, one-time)

    /// Declined consent is permanent and silent: no scan is ever scheduled, no offer
    /// is re-shown, no callback fires.
    @MainActor
    func testDeniedConsentNeverScansOrOffers() {
        var offered = false
        let learner = ClaudeTranscriptLearner(
            projectsDirectory: FileManager.default.temporaryDirectory,
            readConsent: { .denied },
            writeConsent: { _ in XCTFail("a denied user is never written to again") }
        )
        learner.scheduleScan(
            inserted: "x", insertionUnix: base, alreadyLearned: { false },
            offerConsent: { offered = true },
            onLearned: { _, _ in XCTFail("denied consent must not learn") }
        )
        XCTAssertFalse(offered, "a denied user is never re-offered")
    }

    /// An unset user is offered exactly once and no scan runs on that insertion (the
    /// offer IS the interaction); accepting persists `.granted`.
    @MainActor
    func testUnsetConsentOffersOnceAndDoesNotScan() {
        var written: ClaudeTranscriptLearner.Consent?
        var offerCount = 0
        let learner = ClaudeTranscriptLearner(
            projectsDirectory: FileManager.default.temporaryDirectory,
            readConsent: { .unset },
            writeConsent: { written = $0 }
        )
        learner.scheduleScan(
            inserted: "x", insertionUnix: base, alreadyLearned: { false },
            offerConsent: { offerCount += 1 },
            onLearned: { _, _ in XCTFail("no scan should run while consent is unset") }
        )
        XCTAssertEqual(offerCount, 1, "the offer is shown exactly once for an unset user")
        learner.resolveConsent(granted: true)
        XCTAssertEqual(written, .granted, "accepting persists granted consent")
    }

    @MainActor
    func testResolveConsentDeclinePersistsDenied() {
        var written: ClaudeTranscriptLearner.Consent?
        let learner = ClaudeTranscriptLearner(
            projectsDirectory: FileManager.default.temporaryDirectory,
            readConsent: { .unset }, writeConsent: { written = $0 })
        learner.resolveConsent(granted: false)
        XCTAssertEqual(written, .denied, "declining persists denied consent permanently")
    }
}
