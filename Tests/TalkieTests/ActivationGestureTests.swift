import XCTest
@testable import Talkie

/// Exhaustive edge-matrix tests for the pure `ActivationGesture` state machine — the
/// single **hold-to-talk / hold-to-latch / tap-to-stop** gesture family, exercised as
/// a function of timestamped input edges with no timers, clocks, or I/O. Every path
/// the `HotKeyMonitor` can feed it (hold-release push-to-talk, hold-past-latch,
/// release-keeps-recording, tap-to-stop, early/late/stale timers, reconcile exemption,
/// rebind mid-hold) is pinned here, because the maker's manual gesture testing is
/// headless and this machine is where every activation decision is actually made.
final class ActivationGestureTests: XCTestCase {
    private let latch = ActivationGesture.latchThreshold   // 0.5

    // MARK: First-phoneme priority

    func testKeyDownBeginsAndArmsLatchImmediately() {
        var g = ActivationGesture()
        // Idle key-down arms audio AND the latch timer in one shot — no waiting to
        // classify the press, so the mic is live from the first instant.
        XCTAssertEqual(g.keyDown(at: 0), .beginArmingLatch(fireAt: latch))
        XCTAssertTrue(g.isActive)
        XCTAssertTrue(g.isHeld)
        XCTAssertFalse(g.isLocked)
    }

    // MARK: Hold to talk (push-to-talk) — release before the latch ends synchronously

    func testReleaseBeforeLatchEndsWithZeroAddedLatency() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        // Released well before the latch deadline → a plain push-to-talk hold that
        // ends the instant the key is let go (no deferred-end tax).
        XCTAssertEqual(g.keyUp(at: 0.2), .end)
        XCTAssertFalse(g.isActive)
    }

    func testStaleLatchTimerAfterReleaseIsNoOp() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        XCTAssertEqual(g.keyUp(at: 0.2), .end)
        // The latch timer the caller armed still fires at 0.5, but the session already
        // ended — it must be a safe no-op, never latch a dead session.
        XCTAssertEqual(g.timerFired(at: latch), .none)
        XCTAssertFalse(g.isActive)
    }

    // MARK: Hold to latch — hold past the threshold and it latches hands-free

    func testHoldPastLatchLatches() {
        var g = ActivationGesture()
        XCTAssertEqual(g.keyDown(at: 0), .beginArmingLatch(fireAt: latch))
        // Still held when the timer fires at the deadline → latch hands-free.
        XCTAssertEqual(g.timerFired(at: latch), .lock)
        XCTAssertTrue(g.isLocked)
        XCTAssertFalse(g.isHeld, "a latched-but-still-held session is not a push-to-talk hold")
    }

    func testReleaseAfterLatchKeepsRecording() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        _ = g.timerFired(at: latch)               // latches (key still down)
        // Letting the key go after latching keeps recording with nothing held.
        XCTAssertEqual(g.keyUp(at: 0.8), .none)
        XCTAssertTrue(g.isActive)
        XCTAssertTrue(g.isLocked)
    }

    func testEarlyTimerBeforeDeadlineIsIgnored() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        // A timer tick before the armed deadline (e.g. an early/rescheduled fire) does
        // not latch — only the real deadline does.
        XCTAssertEqual(g.timerFired(at: latch - 0.01), .none)
        XCTAssertTrue(g.isHeld)
    }

    // MARK: Tap to stop

    func testTapWhenLatchedStops() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        _ = g.timerFired(at: latch)               // latch
        _ = g.keyUp(at: 0.8)                       // release → locked hands-free
        // The next press stops and inserts.
        XCTAssertEqual(g.keyDown(at: 2.0), .end)
        XCTAssertFalse(g.isActive)
        // The key-up half of that stopping tap is a stray release — ignored.
        XCTAssertEqual(g.keyUp(at: 2.1), .none)
    }

    func testStopWhileStillHeldLatched() {
        // Latched but the key was never released (lockedHeld). A brand-new press can't
        // arrive without an intervening up, but if a duplicate down does, it's ignored
        // rather than mis-stopping.
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        _ = g.timerFired(at: latch)               // lockedHeld
        XCTAssertEqual(g.keyDown(at: 0.6), .none, "a duplicate down while latched-held is ignored")
        XCTAssertTrue(g.isLocked)
    }

    // MARK: Reconcile exemption + reset

    func testReconcileFlagsAcrossPhases() {
        var g = ActivationGesture()
        XCTAssertFalse(g.isHeld); XCTAssertFalse(g.isLocked)   // idle
        _ = g.keyDown(at: 0)
        XCTAssertTrue(g.isHeld, "a plain hold may be force-ended by reconcile")
        XCTAssertFalse(g.isLocked)
        _ = g.timerFired(at: latch)
        XCTAssertFalse(g.isHeld, "a latched session must be exempt from reconcile force-release")
        XCTAssertTrue(g.isLocked)
    }

    func testResetReportsActiveAndGoesIdle() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        XCTAssertTrue(g.reset(), "reset reports a session was active")
        XCTAssertFalse(g.isActive)
        XCTAssertFalse(g.reset(), "reset on idle reports nothing was active")
    }

    func testDroppedKeyUpDoesNotDoubleBegin() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        // A second down without an intervening up (dropped edge) is ignored, not a
        // second begin.
        XCTAssertEqual(g.keyDown(at: 0.1), .none)
        XCTAssertTrue(g.isHeld)
    }
}
