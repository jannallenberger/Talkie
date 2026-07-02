import XCTest
@testable import Talkie

/// Pure-logic tests for the zero-PCM far-end tap watchdog (C6 / plan 01 §4.2a) —
/// `FarEndWatchdog.decide` exercised as a state machine with supplied times, no Core
/// Audio. Mirrors `MeetingDetectorTests`: replay synthetic `Input`s, assert the
/// `.ok`/`.rebuild`/`.giveUp` action, every assertion carrying the expected behavior.
final class FarEndWatchdogTests: XCTestCase {
    private let wd = FarEndWatchdog()          // default thresholds (10 / 90 / 3 / 20 / 5)
    private var t: FarEndWatchdog.Thresholds { wd.thresholds }

    /// Convenience builder so each test only names the fields it cares about.
    private func input(
        now: TimeInterval,
        startedAt: TimeInterval = 0,
        lastNonSilentAt: TimeInterval? = nil,
        everReceived: Bool = false,
        rebuildCount: Int = 0,
        lastRebuildAt: TimeInterval? = nil,
        micAlive: Bool
    ) -> FarEndWatchdog.Input {
        FarEndWatchdog.Input(
            now: now, startedAt: startedAt, lastNonSilentAt: lastNonSilentAt,
            everReceivedNonSilent: everReceived, rebuildCount: rebuildCount,
            lastRebuildAt: lastRebuildAt, micAliveRecently: micAlive
        )
    }

    // MARK: Startup grace (never-received)

    func testWithinGraceNeverRebuilds() {
        // Mic alive, but still inside the never-received grace window → wait.
        let a = wd.decide(input(now: t.neverReceivedGrace - 1, micAlive: true))
        XCTAssertEqual(a, .ok, "before the grace elapses a born-dead tap must not be rebuilt yet")
    }

    func testNeverReceivedWithMicAliveRebuildsAfterGrace() {
        // Grace elapsed, mic proving the app is alive, far end never delivered a
        // single non-silent buffer → the tap was born dead; rebuild once.
        let a = wd.decide(input(now: t.neverReceivedGrace + 1, micAlive: true))
        XCTAssertEqual(a, .rebuild, "a never-delivering tap with a live mic should rebuild after the grace")
    }

    // MARK: The CRITICAL early-join case — never-received AND mic quiet

    func testEarlyJoinQuietCallNeverDowngrades() {
        // Joined the call early; nobody has spoken on EITHER side. Far end never
        // received audio AND the mic is also quiet. This must NOT trip a rebuild or a
        // give-up no matter how long we wait — a silent early join is normal, not a
        // dead tap. (The spec's CRITICAL note: the never-received branch is mic-alive-
        // gated too, so a quiet start can't falsely downgrade a real call.)
        let short = wd.decide(input(now: t.neverReceivedGrace + 1, micAlive: false))
        XCTAssertEqual(short, .ok, "quiet early join just past grace must hold, not rebuild")

        let veryLong = wd.decide(input(now: 3600, micAlive: false))
        XCTAssertEqual(veryLong, .ok, "an hour of a genuinely silent call (mic quiet) must never downgrade")

        // And even at the rebuild cap, a mic-quiet never-received state gives up on
        // NOTHING — it can't reach the cap because it never rebuilds.
        let atCap = wd.decide(input(now: 3600, rebuildCount: t.maxRebuilds, micAlive: false))
        XCTAssertEqual(atCap, .ok, "mic-quiet never-received must never give up (it never rebuilt)")
    }

    // MARK: Mid-meeting death

    func testMidMeetingDeathWithMicAliveRebuilds() {
        // Real far-end audio was seen at t=100; now it's been silent for > 90 s while
        // the mic is still delivering buffers → the tap died; rebuild.
        let a = wd.decide(input(
            now: 100 + t.silenceRebuild + 1, lastNonSilentAt: 100, everReceived: true, micAlive: true
        ))
        XCTAssertEqual(a, .rebuild, "far-end silent past the window while the mic is alive means a dead tap")
    }

    func testMidMeetingShortSilenceHolds() {
        // A brief far-end silence (< 90 s) on a live call is normal (a pause) → hold.
        let a = wd.decide(input(
            now: 100 + t.silenceRebuild - 5, lastNonSilentAt: 100, everReceived: true, micAlive: true
        ))
        XCTAssertEqual(a, .ok, "a short far-end pause must not trigger a rebuild")
    }

    func testGenuineLongSilenceWithMicAlsoQuietDoesNotRebuild() {
        // The whole call is quiet: far end silent for a long time AND the mic is also
        // quiet (nobody speaking, on hold, waiting room). This is the false-positive
        // the mic-alive gate exists to prevent — no rebuild.
        let a = wd.decide(input(
            now: 100 + t.silenceRebuild + 30, lastNonSilentAt: 100, everReceived: true, micAlive: false
        ))
        XCTAssertEqual(a, .ok, "a genuinely quiet call (mic also silent) must NOT be treated as a dead tap")
    }

    // MARK: Rebuild cap → giveUp

    func testRebuildCapGivesUp() {
        // Mid-meeting death conditions, but the per-meeting rebuild cap is already
        // reached → give up (degrade to mic-only) instead of rebuilding forever.
        let a = wd.decide(input(
            now: 100 + t.silenceRebuild + 1, lastNonSilentAt: 100, everReceived: true,
            rebuildCount: t.maxRebuilds, micAlive: true
        ))
        XCTAssertEqual(a, .giveUp, "past the rebuild cap the watchdog gives up rather than rebuilding again")
    }

    func testJustUnderCapStillRebuilds() {
        let a = wd.decide(input(
            now: 100 + t.silenceRebuild + 1, lastNonSilentAt: 100, everReceived: true,
            rebuildCount: t.maxRebuilds - 1, micAlive: true
        ))
        XCTAssertEqual(a, .rebuild, "one rebuild below the cap should still rebuild")
    }

    // MARK: Backoff between rebuilds

    func testBackoffSpacesConsecutiveRebuilds() {
        // A tap that dies again immediately after a rebuild must wait out the backoff
        // before the next rebuild, so a few seconds can't burn the whole cap.
        let justRebuilt = wd.decide(input(
            now: 100 + t.silenceRebuild + 1, lastNonSilentAt: 100, everReceived: true,
            rebuildCount: 1, lastRebuildAt: 100 + t.silenceRebuild, micAlive: true
        ))
        XCTAssertEqual(justRebuilt, .ok, "within the backoff window after a rebuild, hold before rebuilding again")

        // Once the backoff has elapsed, a still-dead tap rebuilds.
        let afterBackoff = wd.decide(input(
            now: 100 + t.silenceRebuild + t.rebuildBackoff + 1, lastNonSilentAt: 100, everReceived: true,
            rebuildCount: 1, lastRebuildAt: 100 + t.silenceRebuild, micAlive: true
        ))
        XCTAssertEqual(afterBackoff, .rebuild, "after the backoff elapses, a still-dead tap rebuilds")
    }

    func testNeverReceivedRebuildsAreSpacedByBackoff() {
        // The never-received path is spaced by the same backoff, so a tap that stays
        // born-dead can't exhaust the cap in a burst.
        let within = wd.decide(input(
            now: t.neverReceivedGrace + 5, rebuildCount: 1,
            lastRebuildAt: t.neverReceivedGrace, micAlive: true
        ))
        XCTAssertEqual(within, .ok, "never-received retries must also respect the backoff")
    }

    // MARK: Timestamp monotonicity

    func testMonotonicSilenceGrows() {
        // As `now` advances against a fixed lastNonSilentAt, the decision goes from
        // healthy (short silence) to rebuild (past the window) and stays actionable —
        // never regressing to .ok once the threshold is crossed (mic stays alive).
        let base: TimeInterval = 100
        let before = wd.decide(input(now: base + t.silenceRebuild - 1, lastNonSilentAt: base, everReceived: true, micAlive: true))
        XCTAssertEqual(before, .ok, "just under the window is still healthy")

        let at = wd.decide(input(now: base + t.silenceRebuild, lastNonSilentAt: base, everReceived: true, micAlive: true))
        XCTAssertEqual(at, .rebuild, "exactly at the window crosses into rebuild")

        let after = wd.decide(input(now: base + t.silenceRebuild + 60, lastNonSilentAt: base, everReceived: true, micAlive: true))
        XCTAssertEqual(after, .rebuild, "further past the window stays actionable, never regresses to ok")
    }

    func testFreshNonSilentResetsTheClock() {
        // A newer lastNonSilentAt (real audio just arrived) shrinks the measured
        // silence, returning the tap to healthy — the monotonic timestamp advancing is
        // exactly what proves the tap is alive again after a rebuild.
        let a = wd.decide(input(now: 200, lastNonSilentAt: 199, everReceived: true, micAlive: true))
        XCTAssertEqual(a, .ok, "a recent non-silent buffer means the tap is delivering — healthy")
    }
}
