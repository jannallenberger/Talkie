import XCTest
@testable import Talkie

/// The stalled-recognizer safeguard. When macOS's `SpeechAnalyzer` stops finalizing on
/// a long meeting stream (~30 min in), a whole speaker turn can collapse under a single
/// frozen timecode — the "[29:52] Them: …4,872 words" bug. `MeetingTranscriptRenderer`'s
/// `decollapse` / `render(_:duration:)` must spread such a frozen run back into readable,
/// advancing-timecode lines, while leaving a healthy transcript byte-identical. (The
/// primary fix is analyzer rotation upstream; this is the backstop.)
final class MeetingDecollapseTests: XCTestCase {

    private func turn(_ t: TimeInterval, _ speaker: MeetingSpeaker, _ text: String) -> TurnLog.Turn {
        TurnLog.Turn(elapsed: t, speaker: speaker, text: text, endSec: t)
    }

    private func lines(_ s: String) -> [String] { s.split(separator: "\n").map(String.init) }

    private func render(_ t: [TurnLog.Turn], duration: TimeInterval? = nil) -> String {
        MeetingTranscriptRenderer.render(t, duration: duration)
    }

    /// 40 "Them" turns all frozen at 29:52 (~1792s): one coalesced block without the
    /// fix, several advancing-timecode lines with it.
    func testFrozenRunSpreadsIntoManyLines() {
        var turns: [TurnLog.Turn] = [turn(10, .me, "okay let us start the meeting now")]
        for _ in 0..<40 {
            turns.append(turn(1792, .them, "this is a sentence with several words in it yes"))
        }

        // Sanity: without the duration the frozen run is one giant block (the bug).
        let buggyThem = lines(render(turns)).filter { $0.contains("] Them:") }
        XCTAssertEqual(buggyThem.count, 1, "without the fix the frozen run coalesces to one block")

        // With the duration it de-collapses into several timed lines.
        let fixed = render(turns, duration: 3900)
        let themLines = lines(fixed).filter { $0.contains("] Them:") }
        XCTAssertGreaterThan(themLines.count, 3, "frozen run must spread into several lines")
        // The later lines must carry advancing timecodes past 29:52 toward the end.
        XCTAssertTrue(["[3", "[4", "[5", "[6"].contains { fixed.contains($0) },
                      "de-collapsed lines must advance toward the meeting end")
    }

    /// A lone giant turn (a single collapsed block, e.g. the single-locale volatile tail)
    /// is chunked and spread.
    func testSingleGiantTurnIsChunkedAndSpread() {
        let big = Array(repeating: "word", count: 400).joined(separator: " ")
        let turns = [turn(5, .me, "start"), turn(1000, .them, big)]
        let themLines = lines(render(turns, duration: 3000)).filter { $0.contains("] Them:") }
        XCTAssertGreaterThan(themLines.count, 2, "a 400-word frozen block must split into chunks")
    }

    /// A healthy transcript (distinct advancing times, small turns) is untouched.
    func testHealthyTranscriptIsUnchanged() {
        let turns = [
            turn(2, .me, "hi there how are you"),
            turn(6, .them, "good thanks and you"),
            turn(9, .me, "doing well lets begin"),
        ]
        XCTAssertEqual(render(turns, duration: 600), render(turns),
                       "a healthy transcript renders identically with or without the duration")
    }

    /// A short same-speaker frozen run (below the word floor) is left alone.
    func testShortFrozenRunLeftAlone() {
        let turns = [turn(3, .me, "hello"), turn(50, .them, "just a few words here")]
        let decol = MeetingTranscriptRenderer.decollapse(turns, duration: 600)
        XCTAssertEqual(decol.count, turns.count, "a short run is not re-chunked")
    }

    /// Normal continuous speech (consecutive same-speaker turns seconds apart) still
    /// coalesces into one line — the gap-break only fires on large jumps.
    func testContinuousSpeechStillCoalesces() {
        let turns = [
            turn(1, .me, "opening"),
            turn(2, .them, "first"),
            turn(4, .them, "second"),
            turn(6, .them, "third"),
        ]
        let themLines = lines(render(turns, duration: 600)).filter { $0.contains("] Them:") }
        XCTAssertEqual(themLines.count, 1, "turns seconds apart stay one block")
    }
}
