import XCTest
@testable import Talkie

/// Multi-language meetings feed the live summary digest from the language lanes'
/// merged windows (one per rotation) instead of summarizing everything at stop.
final class MeetingLaneDigestTests: XCTestCase {
    private func span(_ text: String, _ start: Double, _ locale: String = "de-DE") -> StreamLanguageVoter.Span {
        StreamLanguageVoter.Span(localeID: locale, text: text, start: start, end: start + 2)
    }

    func testWindowTurnsInterleaveSpeakersByAudioTime() {
        let turns = MeetingRecorder.laneWindowTurns(
            me: [span("Hallo zusammen", 0), span("Genau, so machen wir das", 20)],
            them: [span("Sounds good, let's ship it", 10, "en-US")])
        XCTAssertEqual(turns.map(\.text), ["Hallo zusammen", "Sounds good, let's ship it", "Genau, so machen wir das"])
        XCTAssertEqual(turns.map(\.speaker), [.me, .them, .me])
    }

    func testEmptySpansAreDroppedAndTiesKeepMeFirst() {
        let turns = MeetingRecorder.laneWindowTurns(me: [span("A", 5), span("  ", 6)], them: [span("B", 5)])
        XCTAssertEqual(turns.map(\.text), ["A", "B"])
    }

    func testEmptyWindowFeedsNothing() {
        XCTAssertTrue(MeetingRecorder.laneWindowTurns(me: [], them: []).isEmpty)
    }
}
