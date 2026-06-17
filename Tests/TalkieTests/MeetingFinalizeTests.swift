import XCTest
@testable import Talkie

/// Pure-logic tests for the meeting-finalize hardening.
///
/// P1-09 (the wedged-finalize lockout) is exercised manually — see the PR's
/// "Manual exercise" section — because a faithful unit test would need to stub the
/// real `SpeechAnalyzer` lanes and the full audio-capture `stop()` pipeline.
final class MeetingFinalizeTests: XCTestCase {

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
}
