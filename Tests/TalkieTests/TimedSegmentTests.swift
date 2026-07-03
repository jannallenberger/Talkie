import XCTest
@testable import Talkie

/// D2 — audioTimeRange persistence. Pure-logic coverage for the timed-segment path:
/// the `Meeting` decoder's back-compat, the `TurnLog` audio-clock ordering, and the
/// span→`MeetingSegment` mapping. The live recognizer / audio capture is out of
/// scope for unit tests (headless), exactly like the rest of `Tests/TalkieTests`.
final class TimedSegmentTests: XCTestCase {

    // MARK: - Meeting decoder back-compat

    /// A pre-D2 `meetings.json` entry (no `segments` key, and even no `participants`/
    /// `source`) must still decode, with `segments == nil`.
    func testMeetingDecodesLegacyJSONWithoutSegments() throws {
        let legacy = """
        {
          "id": "5B3F2E9A-0000-0000-0000-000000000001",
          "title": "Old note",
          "startUnix": 1700000000,
          "durationSec": 42,
          "transcript": "hello world",
          "summary": "a summary",
          "fileName": "2023-11-14-000000-5b3f-meeting.md"
        }
        """.data(using: .utf8)!
        let meeting = try JSONDecoder().decode(Meeting.self, from: legacy)
        XCTAssertNil(meeting.segments, "pre-D2 JSON must decode with no segments")
        XCTAssertEqual(meeting.transcript, "hello world")
        XCTAssertEqual(meeting.participants, ["Me"], "legacy default participants")
    }

    /// A new meeting with segments round-trips through encode→decode unchanged.
    func testMeetingWithSegmentsRoundTrips() throws {
        let segs = [
            MeetingSegment(speaker: "Me", start: 0.0, end: 1.5, text: "hi"),
            MeetingSegment(speaker: "Them", start: 1.6, end: 3.0, text: "hello"),
        ]
        let meeting = Meeting(
            title: "t", startUnix: 1, durationSec: 3, transcript: "hi hello",
            summary: "", participants: ["Me", "Them"], source: "s",
            fileName: "f.md", segments: segs
        )
        let data = try JSONEncoder().encode(meeting)
        let decoded = try JSONDecoder().decode(Meeting.self, from: data)
        XCTAssertEqual(decoded.segments, segs, "segments must survive a JSON round-trip")
    }

    /// Encoding a meeting whose `segments` is nil must NOT emit a `segments` key — an
    /// older app build then decodes it exactly as before (the synthesized encoder uses
    /// `encodeIfPresent` for optionals). This is the "old builds ignore the new key"
    /// half of the forward/back-compat contract.
    func testNilSegmentsAreOmittedFromEncodedJSON() throws {
        let meeting = Meeting(
            title: "t", startUnix: 1, durationSec: 3, transcript: "x",
            summary: "", fileName: "f.md"
        )
        let data = try JSONEncoder().encode(meeting)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("\"segments\""),
                       "nil segments must be omitted so old builds decode unchanged: \(json)")
    }

    // MARK: - TurnLog audio-clock timing

    /// The timed `add(_:_:at:end:)` overload stamps the audio-clock span (not wall
    /// clock), and `segments(from:)` yields those exact times in order.
    func testTimedAddStampsAudioClock() {
        let log = TurnLog(startedAt: Date())
        log.add(.me, "first", at: 0.0, end: 1.0)
        log.add(.me, "second", at: 2.0, end: 3.5)
        let segs = MeetingTranscriptRenderer.segments(from: log.snapshot())
        XCTAssertEqual(segs?.map(\.start), [0.0, 2.0])
        XCTAssertEqual(segs?.map(\.end), [1.0, 3.5])
        XCTAssertEqual(segs?.map(\.text), ["first", "second"])
        XCTAssertEqual(segs?.map(\.speaker), ["Me", "Me"])
    }

    /// Segments come out sorted by start and with monotonically non-decreasing,
    /// finite start/end even if turns were added out of order or two streams' clocks
    /// interleave with a hair of skew.
    func testSegmentsAreMonotonicAndFinite() {
        let log = TurnLog(startedAt: Date())
        // Added out of order, and with a tiny cross-stream skew that would otherwise
        // put the "Them" turn a hair before the "Me" turn it should follow.
        log.add(.me, "b", at: 2.0, end: 2.4)
        log.add(.them, "a", at: 1.99, end: 2.10)
        log.add(.me, "c", at: 0.5, end: 0.9)
        guard let segs = MeetingTranscriptRenderer.segments(from: log.snapshot()) else {
            return XCTFail("expected segments")
        }
        for seg in segs {
            XCTAssertTrue(seg.start.isFinite && seg.end.isFinite, "finite: \(seg)")
            XCTAssertGreaterThanOrEqual(seg.end, seg.start, "end ≥ start: \(seg)")
        }
        // Starts never decrease.
        let starts = segs.map(\.start)
        XCTAssertEqual(starts, starts.sorted(), "starts must be non-decreasing: \(starts)")
    }

    /// A wall-clock turn (no `endSec`) gets its `end` bounded by the next turn's
    /// start; the final such turn becomes a zero-length cue (no invented duration).
    func testWallClockTurnsDeriveEndFromNextStart() {
        let log = TurnLog(startedAt: Date().addingTimeInterval(-10))
        // The plain (wall-clock) add stamps `elapsed` from `startedAt`; force a known
        // shape instead by using the timed overload with endSec absent is impossible,
        // so exercise the builder directly with hand-built turns.
        let turns = [
            TurnLog.Turn(elapsed: 0.0, speaker: .me, text: "one"),      // no endSec
            TurnLog.Turn(elapsed: 5.0, speaker: .me, text: "two"),      // no endSec (last)
        ]
        let segs = MeetingTranscriptRenderer.segments(from: turns)
        XCTAssertEqual(segs?.count, 2)
        XCTAssertEqual(segs?[0].end, 5.0, "first turn's end bounded by next start")
        XCTAssertEqual(segs?[1].start, 5.0)
        XCTAssertEqual(segs?[1].end, 5.0, "last wall-clock turn is a zero-length cue")
    }

    /// An empty snapshot yields nil (not an empty array), so "no timed transcript"
    /// and "pre-D2" stay indistinguishable at the `Meeting.segments` level.
    func testEmptySnapshotYieldsNilSegments() {
        XCTAssertNil(MeetingTranscriptRenderer.segments(from: []))
    }

    // MARK: - Span → timed turn → segment mapping

    /// `TurnLog.replace(withTimedTurns:)` (the multilingual/import path) threads the
    /// span's audio-clock start AND end into the turns, and thus into the segments.
    func testReplaceWithTimedTurnsThreadsEnd() {
        let log = TurnLog(startedAt: Date())
        log.add(.me, "placeholder", at: 99, end: 100) // will be replaced
        log.replace(.me, withTimedTurns: [
            (elapsed: 0.0, text: "hallo", end: 0.8),
            (elapsed: 0.8, text: "welt", end: 1.6),
        ])
        let segs = MeetingTranscriptRenderer.segments(from: log.snapshot())
        XCTAssertEqual(segs?.map(\.start), [0.0, 0.8])
        XCTAssertEqual(segs?.map(\.end), [0.8, 1.6])
        XCTAssertEqual(segs?.map(\.text), ["hallo", "welt"])
    }

    /// The voter's coalesced `Span` carries the run's end (its last word's end), so a
    /// span → timed turn → segment keeps a real end, not just the start.
    func testMergedSpanCarriesRunEnd() {
        typealias W = StreamLanguageVoter.TimedWord
        let words: [W] = [
            W(localeID: "en-US", text: "this", start: 0.0, end: 0.3, confidence: 0.95),
            W(localeID: "en-US", text: "is", start: 0.3, end: 0.6, confidence: 0.95),
            W(localeID: "en-US", text: "english", start: 0.6, end: 1.2, confidence: 0.95),
            // A low-confidence competing lane that must not win any frame.
            W(localeID: "de-DE", text: "x", start: 0.0, end: 1.2, confidence: 0.10),
        ]
        let spans = StreamLanguageVoter.mergeWords(words, frame: 0.1, smoothingWindow: 0.1)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.start, 0.0)
        XCTAssertEqual(spans.first?.end, 1.2, "span end must reach its last word's end")
    }
}
