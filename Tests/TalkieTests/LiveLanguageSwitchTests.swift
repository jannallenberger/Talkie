import AVFoundation
import Speech
import XCTest
@testable import Talkie

/// Covers the mid-dictation language switch: the pure restart rule
/// (`LanguageDetector.liveSwitchTarget`) and the lossless audio handoff
/// (`AudioFeed` / `CaptureWindow`) that replays the captured session into the new
/// analyzer and retargets the mic tap without dropping or reordering a buffer.
final class LiveLanguageSwitchTests: XCTestCase {
    typealias C = LanguageDetector.LanguageCandidate

    // MARK: - liveSwitchTarget

    /// The screenshot case: an English dictation in a German session. A clear,
    /// confident win restarts the live session in English.
    func testClearConfidentWinRestarts() {
        let scored = [
            C(localeID: "de-DE", text: "It's wer mür fasuhundes", confidence: 0.70),
            C(localeID: "en-GB", text: "It's worth a few hundred", confidence: 0.93),
        ]
        XCTAssertEqual(LanguageDetector.liveSwitchTarget(among: scored, currentCode: "de")?.localeID, "en-GB")
    }

    /// Beating the incumbent by the margin isn't enough on its own: two weak scores
    /// are noise, and a visible restart on noise would be worse than no restart.
    func testWeakWinnerDoesNotRestart() {
        let scored = [
            C(localeID: "de-DE", text: "rauschen", confidence: 0.30),
            C(localeID: "en-GB", text: "noise", confidence: 0.45),
        ]
        XCTAssertNotNil(LanguageDetector.switchTarget(among: scored, currentCode: "de"),
                        "stop-time rule would switch on the margin alone")
        XCTAssertNil(LanguageDetector.liveSwitchTarget(among: scored, currentCode: "de"))
    }

    /// A close call never restarts live (the next checkpoint gets another look).
    func testCloseCallDoesNotRestart() {
        let scored = [
            C(localeID: "de-DE", text: "etwas", confidence: 0.87),
            C(localeID: "en-GB", text: "something", confidence: 0.90),
        ]
        XCTAssertNil(LanguageDetector.liveSwitchTarget(among: scored, currentCode: "de"))
        XCTAssertTrue(LanguageDetector.probeIsInconclusive(among: scored, currentCode: "de"))
    }

    /// Already in the right language: nothing to do.
    func testCurrentLanguageWinsNoRestart() {
        let scored = [
            C(localeID: "de-DE", text: "Also mal ganz kurz schauen", confidence: 0.92),
            C(localeID: "en-GB", text: "also mal gans", confidence: 0.20),
        ]
        XCTAssertNil(LanguageDetector.liveSwitchTarget(among: scored, currentCode: "de"))
    }

    func testCheckpointsAreAscending() {
        XCTAssertEqual(LanguageDetector.liveProbeCheckpoints, LanguageDetector.liveProbeCheckpoints.sorted())
        XCTAssertFalse(LanguageDetector.liveProbeCheckpoints.isEmpty)
    }

    // MARK: - AudioFeed handoff

    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    /// A buffer identified by its frame length, so ordering is checkable.
    private func buffer(_ id: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: id)!
        b.frameLength = id
        return b
    }

    private func ids(_ stream: AsyncStream<AnalyzerInput>) async -> [AVAudioFrameCount] {
        var out: [AVAudioFrameCount] = []
        for await input in stream { out.append(input.buffer.frameLength) }
        return out
    }

    /// The new analyzer receives the WHOLE session in order: every buffer captured
    /// before the handoff (replayed), then every live buffer after it. The old
    /// analyzer receives nothing after the handoff.
    func testHandOffReplaysEverythingInOrderThenFollowsLive() async {
        let (oldStream, oldCont) = AsyncStream<AnalyzerInput>.makeStream()
        let (newStream, newCont) = AsyncStream<AnalyzerInput>.makeStream()
        let window = CaptureWindow(maxFrames: 1_000_000)
        let feed = AudioFeed(continuation: oldCont, captured: window)

        feed.push(buffer(101))
        feed.push(buffer(102))
        feed.handOff(to: newCont)
        feed.push(buffer(103))
        feed.push(buffer(104))
        oldCont.finish()
        newCont.finish()

        let old = await ids(oldStream)
        let new = await ids(newStream)
        XCTAssertEqual(old, [101, 102])
        XCTAssertEqual(new, [101, 102, 103, 104])
        XCTAssertEqual(window.snapshot().map(\.frameLength), [101, 102, 103, 104],
                       "the window keeps recording across the handoff for the stop-time check")
    }

    /// `snapshot` is non-destructive (the probe must not eat the audio the handoff
    /// and the stop-time check need); `drain` empties.
    func testSnapshotIsNonDestructiveDrainEmpties() {
        let window = CaptureWindow(maxFrames: 1_000_000)
        window.append(buffer(10))
        window.append(buffer(20))
        XCTAssertEqual(window.snapshot().count, 2)
        XCTAssertEqual(window.snapshot().count, 2)
        XCTAssertEqual(window.drain().count, 2)
        XCTAssertTrue(window.drain().isEmpty)
    }

    /// A window that rolled audio off the front reports incomplete, so neither the
    /// live handoff nor the stop-time re-decode replaces the transcript with a tail.
    func testRolledWindowIsIncomplete() {
        let window = CaptureWindow(maxFrames: 250)
        window.append(buffer(100))
        window.append(buffer(100))
        XCTAssertTrue(window.isComplete)
        window.append(buffer(100)) // 300 > 250 → oldest rolls off
        XCTAssertFalse(window.isComplete)
        _ = window.drain()
        XCTAssertTrue(window.isComplete, "drain starts a fresh session window")
    }

    func testSecondsReflectsHeldAudio() {
        let window = CaptureWindow(maxFrames: 1_000_000)
        XCTAssertEqual(window.seconds, 0)
        window.append(buffer(16_000))
        window.append(buffer(8_000))
        XCTAssertEqual(window.seconds, 1.5, accuracy: 0.001)
    }

    // MARK: - Reusing the live verdict at stop

    /// A clear stay (German speech, English far behind) is reusable.
    func testClearStayIsAcousticStay() {
        let scored = [
            C(localeID: "de-DE", text: "Also mal ganz kurz schauen", confidence: 0.88),
            C(localeID: "en-GB", text: "also mal gans", confidence: 0.22),
        ]
        XCTAssertTrue(LanguageDetector.acousticStay(among: scored, currentCode: "de"))
    }

    /// A close call is not a verdict — the stop path must look for itself.
    func testCloseCallIsNotAStay() {
        let scored = [
            C(localeID: "de-DE", text: "etwas", confidence: 0.87),
            C(localeID: "en-GB", text: "something", confidence: 0.87),
        ]
        XCTAssertFalse(LanguageDetector.acousticStay(among: scored, currentCode: "de"))
    }

    /// A switch-worthy score is not a stay — even one too weak for the stricter
    /// LIVE restart rule, which the stop-time rule would still act on.
    func testWeakButMarginWinnerIsNotAStay() {
        let scored = [
            C(localeID: "de-DE", text: "rauschen", confidence: 0.30),
            C(localeID: "en-GB", text: "noise", confidence: 0.45),
        ]
        XCTAssertNil(LanguageDetector.liveSwitchTarget(among: scored, currentCode: "de"))
        XCTAssertFalse(LanguageDetector.acousticStay(among: scored, currentCode: "de"))
    }

    /// No score for the current language: nothing to reuse.
    func testMissingIncumbentIsNotAStay() {
        let scored = [C(localeID: "en-GB", text: "something", confidence: 0.40)]
        XCTAssertFalse(LanguageDetector.acousticStay(among: scored, currentCode: "de"))
    }

    /// The 12 s live probe covers any longer dictation (the stop probe's window).
    func testTwelveSecondVerdictCoversLongDictation() {
        XCTAssertTrue(LanguageDetector.liveVerdictCovers(verdictSeconds: 12, totalSeconds: 150, probeSeconds: 12))
    }

    /// A 6 s verdict covers a short dictation (at least half of it) but not a long one.
    func testSixSecondVerdictCoversOnlyShortDictations() {
        XCTAssertTrue(LanguageDetector.liveVerdictCovers(verdictSeconds: 6, totalSeconds: 10, probeSeconds: 12))
        XCTAssertFalse(LanguageDetector.liveVerdictCovers(verdictSeconds: 6, totalSeconds: 40, probeSeconds: 12))
    }
}
