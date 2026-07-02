import XCTest
@testable import Talkie

/// Guards the F2 contract: note-takers' fused summaries must fuse against the WHOLE
/// meeting, not just its first 8000 characters, WITHOUT regressing short-meeting
/// behavior or the "never lose a note" fallback. `MeetingNotesFusion.fuse` feeds the
/// transcript to the injected `Summarizer`; for an over-long transcript it first
/// runs a map-only `digest` (chunk → terse facts → join) so material past the old
/// cap reaches the fusion prompt. When the digest is unavailable it must degrade to
/// exactly today's `prefix(8000)` truncation — a truncated note, never a lost one.
final class MeetingNotesFusionTests: XCTestCase {

    // MARK: - Stub summarizer

    /// A recording stand-in for the on-device LLM. `generate` returns `reply` (or a
    /// per-call reply from `replies`, consumed in order) and logs every call so a
    /// test can assert HOW MANY model calls happened and WHAT input each one saw.
    /// `reply == nil` (and an exhausted `replies` queue) simulates the model being
    /// unavailable — the exact case `OnDeviceLLM.generate` collapses to nil.
    private actor StubSummarizer: Summarizer {
        static var isAvailable: Bool { true }
        nonisolated let requiresNetwork = false

        struct Call: Sendable { let instructions: String; let input: String }

        private let reply: String?
        private var replies: [String?]
        private(set) var calls: [Call] = []

        init(reply: String?) { self.reply = reply; self.replies = [] }
        init(replies: [String?]) { self.reply = nil; self.replies = replies }

        func generate(instructions: String, input: String) async -> String? {
            calls.append(Call(instructions: instructions, input: input))
            if !replies.isEmpty { return replies.removeFirst() }
            return reply
        }

        var callCount: Int { calls.count }
        var recordedCalls: [Call] { calls }
    }

    private let fusion = MeetingNotesFusion()

    /// A transcript comfortably under the 4000-char chunk boundary.
    private func shortTranscript() -> String {
        "Alice: let's ship Friday.\nBob: I'll own the release notes."
    }

    /// A transcript well over the 4000-char boundary whose LAST line carries a unique
    /// marker, so a test can prove the tail (past the old 8000-char cap) was reached.
    private func longTranscript(marker: String) -> String {
        // ~120 chars/line * 120 lines ≈ 14k chars, safely over both 4000 and 8000.
        let filler = (1...120).map { "Line \($0): the team discussed the roadmap, budget, and hiring plans at length here." }
        return (filler + ["FINAL LINE decision: \(marker)"]).joined(separator: "\n")
    }

    // MARK: - Short transcript: behavior-identical, no digest

    func testShortTranscriptMakesExactlyOneModelCall() async {
        let stub = StubSummarizer(reply: "- fused overview")
        let result = await fusion.fuse(notes: "ship it", transcript: shortTranscript(), using: stub)

        XCTAssertEqual(result?.bodyMarkdown, "- fused overview",
                       "A short transcript should fuse to the summarizer's output unchanged.")
        let count = await stub.callCount
        XCTAssertEqual(count, 1,
                       "A transcript within the chunk boundary must make exactly one (fusion) model call — zero digest calls.")
    }

    func testShortTranscriptFramingIsUnchanged() async {
        let stub = StubSummarizer(reply: "ok")
        _ = await fusion.fuse(notes: "ship it", transcript: shortTranscript(), using: stub)

        let calls = await stub.recordedCalls
        XCTAssertEqual(calls.count, 1, "Exactly one call expected for a short transcript.")
        let input = calls[0].input
        XCTAssertTrue(input.contains("ROUGH NOTES:\nship it"),
                      "The fusion input must still frame the user's notes verbatim.")
        XCTAssertTrue(input.contains("TRANSCRIPT:\n\(shortTranscript())"),
                      "A short transcript must be placed in the prompt byte-identically to before F2 (no digest, no truncation).")
    }

    func testShortTranscriptAtBoundaryIsNotDigested() async {
        // Exactly 4000 chars: the boundary is inclusive (`> chunkChars` triggers the
        // digest), so this must still be the single-call verbatim path.
        let boundary = String(repeating: "x", count: 4000)
        let stub = StubSummarizer(reply: "ok")
        _ = await fusion.fuse(notes: "", transcript: boundary, using: stub)
        let count = await stub.callCount
        XCTAssertEqual(count, 1, "A transcript exactly at the chunk boundary must not trigger the digest.")
    }

    // MARK: - Long transcript: digest carries material past the old cap

    func testLongTranscriptDigestsBeyondTheOldCap() async {
        let marker = "MOVE-LAUNCH-TO-Q3"
        // A faithful map-only stub: each map call returns a SHORT fact bullet that
        // preserves the load-bearing marker if the excerpt contained it. This mirrors
        // what a real digest does (compress each chunk while keeping names/decisions),
        // so the joined digest converges under the chunk budget AND the tail marker
        // survives into the fusion prompt — which a raw prefix(8000) cap would drop.
        let stub = MarkerPreservingSummarizer(marker: marker)
        let result = await fusion.fuse(notes: "roadmap", transcript: longTranscript(marker: marker), using: stub)

        XCTAssertNotNil(result, "A long transcript with an available model should still fuse.")
        let calls = await stub.recordedCalls
        XCTAssertGreaterThanOrEqual(calls.count, 2,
                                    "A long transcript must make at least one digest call plus the fusion call.")
        // Sanity: the marker must genuinely sit beyond the old 8000-char cap, or this
        // test proves nothing about un-capping.
        let rawPrefix = String(longTranscript(marker: marker).prefix(8000))
        XCTAssertFalse(rawPrefix.contains(marker),
                       "Sanity: the marker must be beyond the old cap, or this test proves nothing.")
        // The final (fusion) call's input is the digested transcript, and it must carry
        // the tail marker — proving the digest, not a raw prefix, fed the fusion.
        let fusionCall = calls.last!
        XCTAssertTrue(fusionCall.input.contains(marker),
                      "The fusion prompt must include material from the meeting's tail (past the old 8000-char cap), proving the digest — not a raw prefix — fed the fusion.")
    }

    // MARK: - Digest failure degrades to today's prefix truncation (never a lost note)

    func testDigestFailureFallsBackToPrefixCap() async {
        let marker = "TAIL-SHOULD-BE-DROPPED"
        // First call is the digest map (returns nil → model unavailable mid-digest);
        // the second call is the fusion, which must then receive the prefix(8000)
        // fallback. Reply queue: [nil (digest fails), "fused"] — fusion still succeeds
        // on the truncated input, so the note is preserved, just truncated as before.
        let stub = StubSummarizer(replies: [nil, "fused from prefix"])
        let result = await fusion.fuse(notes: "roadmap", transcript: longTranscript(marker: marker), using: stub)

        XCTAssertEqual(result?.bodyMarkdown, "fused from prefix",
                       "When the digest fails, fusion must still run on the truncated fallback and preserve the note.")
        let calls = await stub.recordedCalls
        XCTAssertEqual(calls.count, 2,
                       "One failed digest map call, then the fusion call on the prefix fallback.")
        let fusionInput = calls[1].input
        XCTAssertFalse(fusionInput.contains(marker),
                       "The fallback is exactly today's prefix(8000) truncation, so the tail marker is (acceptably) dropped — a truncated note, never a lost one.")
        XCTAssertTrue(fusionInput.contains("Line 1:"),
                      "The fallback must still be the transcript's own leading content.")
    }

    // MARK: - Empty transcript

    func testEmptyTranscriptReturnsNilWithoutModelCall() async {
        let stub = StubSummarizer(reply: "should not be used")
        let result = await fusion.fuse(notes: "some notes", transcript: "   \n  ", using: stub)
        XCTAssertNil(result, "An empty transcript yields nil so the caller falls back to the plain summary path.")
        let count = await stub.callCount
        XCTAssertEqual(count, 0, "An empty transcript must not call the model at all.")
    }

    // MARK: - digest() unit contract

    func testDigestReturnsInputUnchangedWhenItAlreadyFits() async {
        let stub = StubSummarizer(reply: "SHOULD NOT BE CALLED")
        let short = shortTranscript()
        let out = await MeetingNotesFusion.digest(short, using: stub)
        XCTAssertEqual(out, short, "A transcript within the chunk budget is returned unchanged.")
        let count = await stub.callCount
        XCTAssertEqual(count, 0, "The no-op digest path must make zero model calls.")
    }
}

/// A faithful map-only `Summarizer` stub: each `generate` call returns a SHORT fact
/// bullet, echoing the `marker` only when the input excerpt contained it. This lets a
/// test prove the digest (a) converges under the chunk budget (short outputs join to
/// well under 4000 chars, so no final truncation drops the tail) and (b) preserves the
/// load-bearing marker from the meeting's tail into the fusion prompt.
private actor MarkerPreservingSummarizer: Summarizer {
    static var isAvailable: Bool { true }
    nonisolated let requiresNetwork = false

    struct Call: Sendable { let instructions: String; let input: String }
    private let marker: String
    private(set) var calls: [Call] = []

    init(marker: String) { self.marker = marker }

    func generate(instructions: String, input: String) async -> String? {
        calls.append(Call(instructions: instructions, input: input))
        // A terse "digest" of this excerpt: one bullet, carrying the marker iff present.
        return input.contains(marker) ? "- decision: \(marker)" : "- discussed roadmap"
    }

    var recordedCalls: [Call] { calls }
}
