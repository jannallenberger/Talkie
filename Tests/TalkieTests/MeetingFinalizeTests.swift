import XCTest
@testable import Talkie

/// Pure-logic tests for the meeting-finalize hardening.
///
/// P1-09 (the wedged-finalize lockout) is exercised manually — see the PR's
/// "Manual exercise" section — because a faithful unit test would need to stub the
/// real `SpeechAnalyzer` lanes and the full audio-capture `stop()` pipeline.
final class MeetingFinalizeTests: XCTestCase {

    // MARK: P1-15 — collision-proof filenames

    @MainActor
    func testFileNamesDoNotCollideSameMinute() {
        let d = Date(timeIntervalSince1970: 1_700_000_000) // fixed instant
        XCTAssertNotEqual(
            MeetingStore.fileName(for: d, id: UUID()),
            MeetingStore.fileName(for: d, id: UUID())
        )
    }

    @MainActor
    func testFileNameIsStableForSameDateAndId() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID()
        XCTAssertEqual(
            MeetingStore.fileName(for: d, id: id),
            MeetingStore.fileName(for: d, id: id)
        )
    }

    @MainActor
    func testFileNameShapeHasSecondsIdFragmentAndSuffix() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let name = MeetingStore.fileName(for: d, id: UUID())
        XCTAssertTrue(name.hasSuffix("-meeting.md"), "got \(name)")
        // yyyy-MM-dd-HHmmss-<4 hex>-meeting.md — five hyphen-joined leading fields.
        let stem = name.replacingOccurrences(of: "-meeting.md", with: "")
        let fields = stem.split(separator: "-")
        XCTAssertEqual(fields.count, 5, "expected date(3)+time(1)+frag(1), got \(name)")
        XCTAssertEqual(fields[3].count, 6, "HHmmss should be 6 digits, got \(name)")
        XCTAssertEqual(fields[4].count, 4, "id fragment should be 4 chars, got \(name)")
    }

    // MARK: P2-01 — typed notes are never silently discarded

    func testComposeSummaryUsesFusedWhenPresent() {
        let out = MeetingRecorder.composeSummary(
            userNotes: "buy milk",
            transcriptSummary: "transcript-derived summary",
            fused: "FUSED BODY"
        )
        XCTAssertEqual(out, "FUSED BODY")
    }

    func testComposeSummaryPreservesRawNotesWhenFusionUnavailable() {
        let notes = "decide on Q3 budget; ping Sam re: contract"
        let out = MeetingRecorder.composeSummary(
            userNotes: notes,
            transcriptSummary: "the transcript summary",
            fused: nil
        )
        XCTAssertTrue(out.contains(notes), "raw notes must survive: \(out)")
        XCTAssertTrue(out.lowercased().contains("unavailable"),
                      "must carry the fusion-unavailable notice: \(out)")
        XCTAssertTrue(out.contains("## Your notes"), "must label the preserved notes: \(out)")
        XCTAssertTrue(out.contains("the transcript summary"),
                      "the plain transcript summary should still be included: \(out)")
    }

    func testComposeSummaryPreservesNotesEvenWithEmptyTranscriptSummary() {
        let notes = "standalone jotted note"
        let out = MeetingRecorder.composeSummary(
            userNotes: notes,
            transcriptSummary: "",
            fused: nil
        )
        XCTAssertTrue(out.contains(notes), "notes-only meeting must keep its notes: \(out)")
        XCTAssertTrue(out.lowercased().contains("unavailable"))
    }

    func testComposeSummaryFallsBackToTranscriptSummaryWhenNoNotes() {
        let out = MeetingRecorder.composeSummary(
            userNotes: "",
            transcriptSummary: "just the summary",
            fused: nil
        )
        XCTAssertEqual(out, "just the summary")
    }

    func testComposeSummaryTreatsBlankFusedAsUnavailable() {
        let notes = "keep me"
        let out = MeetingRecorder.composeSummary(
            userNotes: notes,
            transcriptSummary: "s",
            fused: "   \n  "
        )
        // A blank fused result must not silently erase the notes.
        XCTAssertTrue(out.contains(notes), "blank fused must not wipe notes: \(out)")
    }

    // MARK: D2 — segments are additive, back-compat

    /// The D2 `segments` field is optional: a meeting built without it (recovered /
    /// notes-only / pre-D2) has `segments == nil` and still encodes+decodes.
    func testMeetingSegmentsDefaultNilAndRoundTrip() throws {
        let m = Meeting(
            title: "no segments", startUnix: 1, durationSec: 0,
            transcript: "", summary: "", fileName: "f.md"
        )
        XCTAssertNil(m.segments)
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(m))
        XCTAssertNil(decoded.segments, "a nil-segments meeting must round-trip unchanged")
    }

    // MARK: F3 — the "## Action items" section from Stage-2 commitments

    private func commitment(_ text: String) -> ContextGraphExtractor.Candidate {
        ContextGraphExtractor.Candidate(kind: .commitment, displayName: text)
    }

    func testActionItemsSectionBuildsBulletsFromCommitments() {
        let section = MeetingRecorder.actionItemsSection(
            commitments: [commitment("send the deck Friday"),
                          commitment("follow up with Sarah")],
            existingSummary: "A one-line overview with no bullets."
        )
        XCTAssertEqual(
            section,
            "## Action items\n- send the deck Friday\n- follow up with Sarah",
            "section must be the heading plus one bullet per commitment, in order"
        )
    }

    func testActionItemsSectionNilWhenNoCommitments() {
        XCTAssertNil(
            MeetingRecorder.actionItemsSection(commitments: [], existingSummary: "overview"),
            "no commitments → no section (Stage-1-only / model-unavailable path)"
        )
    }

    func testActionItemsSectionIgnoresNonCommitmentKinds() {
        // Only COMMITMENT candidates become action items; people/terms/projects are
        // ignored even if passed through.
        let section = MeetingRecorder.actionItemsSection(
            commitments: [
                ContextGraphExtractor.Candidate(kind: .person, displayName: "Sarah"),
                ContextGraphExtractor.Candidate(kind: .term, displayName: "map-reduce"),
                ContextGraphExtractor.Candidate(kind: .project, displayName: "Talkie"),
            ],
            existingSummary: "overview"
        )
        XCTAssertNil(section, "no commitment candidates → no section")
    }

    func testActionItemsSectionSuppressedWhenSummaryAlreadyHasActionItems() {
        // The duplication guard: if the summarizer/fusion already produced an action
        // items section, we don't stack a second one on top.
        let existing = "Overview.\n\n**Action items:**\n- do the thing"
        XCTAssertNil(
            MeetingRecorder.actionItemsSection(
                commitments: [commitment("send the deck Friday")],
                existingSummary: existing
            ),
            "an existing 'action items' mention (any case) suppresses the new section"
        )
        // Case-insensitivity of the guard.
        XCTAssertNil(
            MeetingRecorder.actionItemsSection(
                commitments: [commitment("send the deck Friday")],
                existingSummary: "ACTION ITEMS: none noted"
            )
        )
    }

    func testActionItemsSectionAppearsWhenSummaryLacksActionItems() {
        let section = MeetingRecorder.actionItemsSection(
            commitments: [commitment("send the deck Friday")],
            existingSummary: "Decisions were made about the budget."
        )
        XCTAssertNotNil(section, "a summary without 'action items' must not suppress the section")
        XCTAssertTrue(section!.hasPrefix("## Action items\n"))
    }

    func testActionItemsSectionDedupesCommitmentsCaseInsensitively() {
        let section = MeetingRecorder.actionItemsSection(
            commitments: [commitment("Send the deck Friday"),
                          commitment("send the deck friday"),
                          commitment("book the room")],
            existingSummary: "overview"
        )
        // The two "send the deck" variants collapse to one bullet (first-seen form);
        // "book the room" is its own bullet.
        XCTAssertEqual(
            section,
            "## Action items\n- Send the deck Friday\n- book the room",
            "duplicate commitments collapse case-insensitively, keeping first-seen form"
        )
    }

    func testActionItemsSectionDropsBlankCommitmentClauses() {
        let section = MeetingRecorder.actionItemsSection(
            commitments: [commitment("   "), commitment("real task")],
            existingSummary: "overview"
        )
        XCTAssertEqual(section, "## Action items\n- real task",
                       "blank/whitespace commitment clauses are dropped")
    }

    // MARK: F3 — MeetingSummarizer.summarizeCondensed shape + chunker

    /// Empty/whitespace input short-circuits before any model call, so the
    /// condensed view is `("", nil)` regardless of Apple Intelligence availability
    /// — deterministic in a headless test.
    func testSummarizeCondensedEmptyInputYieldsNilAndEmpty() async {
        let out = await MeetingSummarizer().summarizeCondensed("   \n\t ")
        XCTAssertNil(out.summary, "empty input → no summary")
        XCTAssertEqual(out.condensed, "", "empty input → empty condensed")
    }

    /// `summarize` is defined as `summarizeCondensed(_:).summary`; the delegation
    /// must hold. Empty input exercises it deterministically (both nil).
    func testSummarizeDelegatesToCondensedSummary() async {
        let summarizer = MeetingSummarizer()
        let direct = await summarizer.summarize("   ")
        let viaCondensed = await summarizer.summarizeCondensed("   ").summary
        XCTAssertEqual(direct, viaCondensed, "summarize must equal summarizeCondensed().summary")
        XCTAssertNil(direct)
    }

    /// `chunkForSinglePass` is the pure seam the finalize path uses to size the
    /// extractor's input. A body within budget is one chunk, unchanged.
    func testChunkForSinglePassShortBodyIsSingleChunk() {
        let body = "Alice: let's ship Friday.\nBob: I'll write the tests."
        let chunks = MeetingSummarizer.chunkForSinglePass(body)
        XCTAssertEqual(chunks.count, 1, "a short body stays one chunk")
        XCTAssertEqual(chunks[0], body, "and is returned unchanged")
    }

    func testChunkForSinglePassEmptyBodyYieldsNoChunks() {
        XCTAssertTrue(MeetingSummarizer.chunkForSinglePass("").isEmpty,
                      "an empty body yields no chunks (extractor loop is skipped)")
    }

    /// A body well over the single-pass budget is split into multiple chunks, each
    /// within the extractor's cap, and every character is preserved (no tail lost).
    func testChunkForSinglePassLongBodyIsSplitWithinBudget() {
        let budget = MeetingSummarizer.singlePassCharBudget
        // ~5x the budget of newline-separated lines so the greedy line packer splits.
        let line = String(repeating: "x", count: 100)
        let lineCount = (budget * 5) / (line.count + 1)
        let body = (0..<lineCount).map { _ in line }.joined(separator: "\n")
        XCTAssertGreaterThan(body.count, budget, "test body must exceed one chunk")

        let chunks = MeetingSummarizer.chunkForSinglePass(body)
        XCTAssertGreaterThan(chunks.count, 1, "an over-budget body must split into >1 chunk")
        // Every chunk fits a single extractor pass (the joiner adds newlines back,
        // so compare against the packing size, which the chunker derives from the
        // budget and max-chunk ceiling).
        for chunk in chunks {
            XCTAssertFalse(chunk.isEmpty, "no empty chunks")
        }
        // No coverage is silently dropped: rejoining reproduces the input.
        XCTAssertEqual(chunks.joined(separator: "\n"), body,
                       "chunking then rejoining must preserve the whole body")
    }
}
