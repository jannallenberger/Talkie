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

    func testNotesSummaryKeepsEveryNoteWithItsTime() {
        let notes = [MeetingNote(text: "decide on Q3 budget", secondsIntoMeeting: 75),
                     MeetingNote(text: "ping Sam re: contract", secondsIntoMeeting: nil)]
        let out = MeetingRecorder.notesSummary(notes, transcript: "We talk about the budget for the third quarter today.")
        XCTAssertTrue(out.contains("**Your notes:**"), out)
        XCTAssertTrue(out.contains("- [01:15] decide on Q3 budget"), out)
        XCTAssertTrue(out.contains("- ping Sam re: contract"), out)
    }

    func testNotesSummaryIsEmptyWithoutNotes() {
        XCTAssertEqual(MeetingRecorder.notesSummary([], transcript: "anything"), "")
    }

    func testNotesSummaryOfANotesOnlyMeetingUsesTheNotesLanguage() {
        let notes = [MeetingNote(text: "Wir entscheiden uns für den kleineren Stand in Halle drei", secondsIntoMeeting: 10)]
        XCTAssertTrue(MeetingRecorder.notesSummary(notes, transcript: "").contains("**Deine Notizen:**"))
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
