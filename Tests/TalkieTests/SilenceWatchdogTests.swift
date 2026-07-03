import XCTest
@testable import Talkie

/// Pure-logic tests for the hands-free auto-stop watchdog (B5) — `SilenceWatchdog`
/// exercised as a two-phase state machine with supplied `(timestamp, level)` samples
/// and `transcriptChanged` events, no Core Audio, no timer. Mirrors
/// `FarEndWatchdogTests` / `MeetingDetectorTests`: replay a synthetic sequence and
/// assert the emitted `Event`s, every assertion carrying the expected behavior.
///
/// The load-bearing case is the **quiet speaker**: a level that never clears the
/// silence floor but a volatile transcript that keeps changing must count as activity
/// (words are arriving), so the countdown never fires. That test is called out below.
final class SilenceWatchdogTests: XCTestCase {
    private var thresholds: SilenceWatchdog.Thresholds { .default }

    /// A level comfortably above the silence floor — unambiguous speech.
    private var speech: Float { thresholds.silenceFloor + 0.5 }
    /// A level at the floor — counts as silent (the mapping's practical quiet).
    private var quiet: Float { thresholds.silenceFloor }

    // MARK: - Happy path: silence → countdown → stop

    func testSilenceArmsThenStops() {
        // Speak once (activity), then go silent and let the clock run: at `armAfter`
        // the countdown starts, and at `armAfter + countdownDuration` it stops.
        var wd = SilenceWatchdog()

        XCTAssertNil(wd.observe(level: speech, at: 0),
                     "initial speech is activity, not an event")
        // Still silent but before the arm threshold — nothing yet.
        XCTAssertNil(wd.tick(now: thresholds.armAfter - 0.5),
                     "silence shorter than armAfter must not start the countdown")
        // Exactly at the arm threshold — the visible countdown begins.
        XCTAssertEqual(wd.tick(now: thresholds.armAfter),
                       .countdownStarted(remaining: thresholds.countdownDuration),
                       "silence reaching armAfter should start the visible countdown")
        XCTAssertTrue(wd.isCountingDown, "the watchdog should report it is counting down")
        // Mid-countdown — still nothing.
        XCTAssertNil(wd.tick(now: thresholds.armAfter + thresholds.countdownDuration - 0.5),
                     "mid-countdown silence must not stop yet")
        // Countdown elapsed with unbroken silence — stop.
        XCTAssertEqual(wd.tick(now: thresholds.armAfter + thresholds.countdownDuration),
                       .stop,
                       "silence surviving the whole countdown should stop the session")
    }

    func testTotalSilenceToStopIsAboutSevenSeconds() {
        // Guardrail on the killer risk: the total true-silence-to-stop is armAfter +
        // countdownDuration and it must stay generous (≥ 6 s) so a thinking pause is
        // never eaten. Locks the constants against an accidental tightening.
        let total = thresholds.armAfter + thresholds.countdownDuration
        XCTAssertGreaterThanOrEqual(total, 6,
            "auto-stop must need a generous (~7 s) true silence; do not tighten below 6 s")
        XCTAssertEqual(thresholds.armAfter, 4, "arm window should be the spec's 4 s")
        XCTAssertEqual(thresholds.countdownDuration, 3, "countdown should be the spec's 3 s")
    }

    // MARK: - Speaking during the countdown cancels it

    func testSpeechDuringCountdownCancels() {
        // Arm the countdown, then a level spike arrives before it elapses → cancelled,
        // and the session must NOT stop afterwards (the clock is reset).
        var wd = SilenceWatchdog()
        _ = wd.observe(level: speech, at: 0)
        XCTAssertEqual(wd.tick(now: thresholds.armAfter),
                       .countdownStarted(remaining: thresholds.countdownDuration),
                       "precondition: countdown started")

        // A loud buffer partway through the countdown cancels it.
        XCTAssertEqual(wd.observe(level: speech, at: thresholds.armAfter + 1),
                       .cancelled,
                       "a level spike during the countdown should cancel it")
        XCTAssertFalse(wd.isCountingDown, "after cancel the watchdog is no longer counting down")

        // Continuing at the moment the old countdown WOULD have fired: nothing stops,
        // because the silence clock restarted from the cancel.
        XCTAssertNil(wd.tick(now: thresholds.armAfter + thresholds.countdownDuration),
                     "after a cancel the old countdown deadline must not still fire a stop")
        // And a fresh full silence from the cancel re-arms rather than stopping late.
        XCTAssertEqual(wd.tick(now: thresholds.armAfter + 1 + thresholds.armAfter),
                       .countdownStarted(remaining: thresholds.countdownDuration),
                       "a fresh armAfter of silence after the cancel should re-arm the countdown")
    }

    func testVolatileTextDuringCountdownCancels() {
        // A quiet speaker whose LEVEL stays down can still cancel the countdown just by
        // producing new partial words — the volatile-text activity signal.
        var wd = SilenceWatchdog()
        _ = wd.observe(level: speech, at: 0)
        XCTAssertEqual(wd.tick(now: thresholds.armAfter),
                       .countdownStarted(remaining: thresholds.countdownDuration),
                       "precondition: countdown started")

        XCTAssertEqual(wd.transcriptChanged(at: thresholds.armAfter + 1),
                       .cancelled,
                       "a volatile-transcript change during the countdown should cancel it")
    }

    // MARK: - Level noise below the floor does NOT count as activity

    func testSubFloorNoiseDoesNotCancelOrReset() {
        // Room tone / fan noise that stays at or below the floor is silence: it must
        // neither reset the silence clock nor prevent the eventual stop. We feed a
        // stream of quiet samples straight through the arm+countdown window.
        var wd = SilenceWatchdog()
        _ = wd.observe(level: speech, at: 0)

        // A dense run of sub-floor samples across the whole window.
        var t = 0.5
        while t < thresholds.armAfter {
            XCTAssertNil(wd.observe(level: quiet, at: t),
                         "sub-floor noise before arming must not emit anything")
            t += 0.5
        }
        XCTAssertEqual(wd.observe(level: quiet, at: thresholds.armAfter),
                       .countdownStarted(remaining: thresholds.countdownDuration),
                       "sub-floor noise never resets the clock, so the countdown still arms on time")

        // Keep feeding quiet through the countdown — it must still stop.
        t = thresholds.armAfter + 0.5
        while t < thresholds.armAfter + thresholds.countdownDuration {
            XCTAssertNil(wd.observe(level: quiet, at: t),
                         "sub-floor noise during the countdown must not cancel it")
            t += 0.5
        }
        XCTAssertEqual(wd.observe(level: quiet, at: thresholds.armAfter + thresholds.countdownDuration),
                       .stop,
                       "unbroken sub-floor noise should still let the countdown complete and stop")
    }

    func testExactlyFloorIsSilentJustAboveIsActivity() {
        // Boundary: a sample exactly at the floor is silent; one just above it is
        // activity. Proves the comparison is `> floor`, matching the doc.
        var wd = SilenceWatchdog()
        // At the floor → silent → after armAfter it arms.
        _ = wd.observe(level: quiet, at: 0)
        XCTAssertEqual(wd.tick(now: thresholds.armAfter),
                       .countdownStarted(remaining: thresholds.countdownDuration),
                       "a level exactly at the floor counts as silence")

        // Just above the floor mid-countdown → activity → cancel.
        XCTAssertEqual(wd.observe(level: thresholds.silenceFloor + 0.001, at: thresholds.armAfter + 0.5),
                       .cancelled,
                       "a level just above the floor counts as speech and cancels")
    }

    // MARK: - The load-bearing quiet-speaker case (volatile text alone counts)

    func testQuietSpeakerVolatileTextKeepsSessionAlive() {
        // LOAD-BEARING: a speaker whose voice never clears the level floor, but whose
        // recognizer keeps emitting new partial words, is clearly talking. Volatile-text
        // changes alone (level always sub-floor) must keep resetting the silence clock,
        // so the countdown NEVER fires across a long stretch. Eating this person's words
        // is exactly the failure this rule prevents.
        var wd = SilenceWatchdog()

        // Simulate ~30 s of quiet-but-continuous speech: every second a sub-floor level
        // sample AND a fresh volatile-text change (words firming up), interleaved with
        // ticks. The transcript change resets the clock each time.
        var t = 0.0
        while t < 30 {
            // Level is always below the floor for this speaker.
            XCTAssertNil(wd.observe(level: quiet, at: t),
                         "sub-floor level alone must not fire anything for the quiet speaker")
            // But a new partial word arrived — activity, resets the silence clock.
            XCTAssertNil(wd.transcriptChanged(at: t + 0.1),
                         "an ongoing volatile-text change must keep the session alive (never arm)")
            // A poll in between finds < armAfter of silence since the last change.
            XCTAssertNil(wd.tick(now: t + 0.9),
                         "less than armAfter since the last partial — must not arm")
            t += 1
        }

        // The instant the quiet speaker actually stops (no more partials), a full
        // armAfter of silence from the last change arms the countdown — proving the
        // machine wasn't wedged, just correctly held off while words were arriving.
        let lastChange = 29.1
        XCTAssertNil(wd.tick(now: lastChange + thresholds.armAfter - 0.5),
                     "still within armAfter of the last partial — no countdown yet")
        XCTAssertEqual(wd.tick(now: lastChange + thresholds.armAfter),
                       .countdownStarted(remaining: thresholds.countdownDuration),
                       "once the quiet speaker truly stops, silence from the last partial arms normally")
    }

    // MARK: - Interleaving / robustness

    func testActivityBeforeAnySilenceIsInert() {
        // Speech-only, never a quiet moment: nothing should ever be emitted.
        var wd = SilenceWatchdog()
        for i in 0..<10 {
            XCTAssertNil(wd.observe(level: speech, at: Double(i)),
                         "continuous speech must never emit an event")
        }
        XCTAssertFalse(wd.isCountingDown, "continuous speech never enters the countdown")
    }

    func testCountdownStartsExactlyOncePerSilence() {
        // Once armed, further silent ticks inside the countdown window must NOT re-emit
        // `.countdownStarted` (which would restart the pill ring every poll).
        var wd = SilenceWatchdog()
        _ = wd.observe(level: speech, at: 0)
        XCTAssertEqual(wd.tick(now: thresholds.armAfter),
                       .countdownStarted(remaining: thresholds.countdownDuration),
                       "countdown starts once")
        XCTAssertNil(wd.tick(now: thresholds.armAfter + 0.4),
                     "a second silent tick inside the countdown must not re-fire countdownStarted")
        XCTAssertNil(wd.tick(now: thresholds.armAfter + 0.8),
                     "nor a third — the ring is not restarted every poll")
    }

    func testNonMonotonicClockDoesNotStopEarly() {
        // Defensive: if a supplied timestamp goes backwards, elapsed is clamped to 0 so
        // the watchdog never stops early on a rewound clock.
        var wd = SilenceWatchdog()
        _ = wd.observe(level: speech, at: 100)
        XCTAssertNil(wd.tick(now: 50),
                     "a rewound clock must not be read as a huge elapsed silence")
        // Forward progress from the (reset) baseline still works.
        XCTAssertNil(wd.tick(now: 100),
                     "back at the original time, still under armAfter of real silence")
    }

    func testStopHappensOnlyOnceThenInert() {
        // After a stop the machine resets to waiting; a further silent tick must not
        // emit a second stop (the driver tears down, but the core should be inert too).
        var wd = SilenceWatchdog()
        _ = wd.observe(level: speech, at: 0)
        _ = wd.tick(now: thresholds.armAfter)
        XCTAssertEqual(wd.tick(now: thresholds.armAfter + thresholds.countdownDuration), .stop,
                       "precondition: it stops once")
        XCTAssertNil(wd.tick(now: thresholds.armAfter + thresholds.countdownDuration + 5),
                     "after a stop the core is inert — no duplicate stop")
    }
}
