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
}
