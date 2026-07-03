import XCTest
@testable import Talkie

/// Exhaustive edge-matrix tests for the pure `ActivationGesture` state machine —
/// the single hold/tap-tap/tap gesture family, exercised as a function of
/// timestamped input edges with no timers, clocks, or I/O. Every path the
/// `HotKeyMonitor` can feed it (hold-release, lone tap + timeout, tap-tap lock,
/// lock-then-tap stop, tap-tap-tap, reconcile-during-lock, rebind mid-hold) is
/// pinned here, because the maker's manual gesture testing is headless and this
/// machine is where every activation decision is actually made.
final class ActivationGestureTests: XCTestCase {
    private let tap = ActivationGesture.tapThreshold      // 0.35
    private let dbl = ActivationGesture.doubleTapWindow   // 0.35

    // MARK: Hold to talk (push-to-talk)

    func testHoldBeginsImmediatelyOnKeyDown() {
        var g = ActivationGesture()
        // First-phoneme priority: the very first key-down arms audio at once, with
        // no wait to classify the gesture.
        XCTAssertEqual(g.keyDown(at: 0), .begin, "idle key-down must begin immediately")
        XCTAssertTrue(g.isActive, "a begun session is active")
        XCTAssertTrue(g.isHeld, "an in-progress hold reports .isHeld")
        XCTAssertFalse(g.isLocked, "a hold is not locked")
    }

    func testHoldReleaseAfterThresholdEndsWithZeroAddedLatency() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        // Released well after the tap threshold → a real hold → end synchronously
        // on release (no deferEnd, so push-to-talk has zero added stop latency).
        XCTAssertEqual(g.keyUp(at: tap + 0.5), .end, "release after a hold ends immediately")
        XCTAssertFalse(g.isActive, "session is over after a hold-release")
    }

    func testHoldReleaseExactlyAtThresholdIsAHold() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        // The boundary is inclusive: held for exactly tapThreshold counts as a hold
        // (ends now), not a tap.
        XCTAssertEqual(g.keyUp(at: tap), .end, "a release at exactly the threshold is a hold")
        XCTAssertFalse(g.isActive)
    }

    // MARK: Lone quick tap → timeout end

    func testQuickTapDefersEndThenTimerEnds() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        // Released before the threshold → ambiguous → defer, keep recording, wait
        // for a possible second tap.
        let up = g.keyUp(at: 0.1)
        XCTAssertEqual(up, .deferEnd(fireAt: 0.1 + dbl), "a quick tap defers its end to the double-tap deadline")
        XCTAssertTrue(g.isActive, "a deferred tap is still recording while awaiting a second tap")
        XCTAssertFalse(g.isHeld, "awaiting-second-tap is not a held phase (key is already up)")
        XCTAssertFalse(g.isLocked, "awaiting-second-tap is not yet locked")
        // No second press arrives; the timer fires at the deadline → lone tap ends.
        XCTAssertEqual(g.timerFired(at: 0.1 + dbl), .end, "with no second tap, the timer ends the lone tap")
        XCTAssertFalse(g.isActive, "the lone tap session is over after the timer")
    }

    func testTimerBeforeDeadlineIsIgnored() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 0.1)
        // A timer that fires early (before the armed deadline) must not end the
        // session — the double-tap window is still open.
        XCTAssertEqual(g.timerFired(at: 0.1 + dbl - 0.01), .none, "an early timer tick is ignored")
        XCTAssertTrue(g.isActive, "still awaiting the second tap after an early tick")
    }

    // MARK: Tap-tap → lock

    func testTapTapLocks() {
        var g = ActivationGesture()
        XCTAssertEqual(g.keyDown(at: 0), .begin, "first tap begins")
        XCTAssertEqual(g.keyUp(at: 0.1), .deferEnd(fireAt: 0.1 + dbl), "first tap release defers")
        // Second press inside the window → lock hands-free. Nothing to begin (we've
        // been recording since the first tap); we only lock.
        XCTAssertEqual(g.keyDown(at: 0.2), .lock, "a second press within the window locks")
        XCTAssertTrue(g.isLocked, "the session is now locked hands-free")
        XCTAssertTrue(g.isActive)
        XCTAssertFalse(g.isHeld, "locked is not held")
    }

    func testSupersededTimerAfterLockIsNoOp() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 0.1)
        _ = g.keyDown(at: 0.2)                // locks
        // The deferred timer for the first tap still fires (the caller can't always
        // cancel in time) — it must be a no-op now that we're locked, or it would
        // kill the lock.
        XCTAssertEqual(g.timerFired(at: 0.1 + dbl), .none, "a superseded deferred timer must not end a locked session")
        XCTAssertTrue(g.isLocked, "lock survives the stale timer")
    }

    func testKeyUpOfSecondTapWhileLockedIsIgnored() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 0.1)
        _ = g.keyDown(at: 0.2)                // locks (we're now .locked)
        // The second tap's own key-up arrives after the lock — it must not disturb
        // the locked session.
        XCTAssertEqual(g.keyUp(at: 0.25), .none, "the second tap's release is ignored while locked")
        XCTAssertTrue(g.isLocked)
    }

    // MARK: Lock → tap → stop

    func testLockThenTapStops() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 0.1)
        _ = g.keyDown(at: 0.2)                // lock
        _ = g.keyUp(at: 0.25)                 // second tap release (ignored)
        // While locked, the next press stops and inserts.
        XCTAssertEqual(g.keyDown(at: 1.0), .end, "a press while locked stops the session")
        XCTAssertFalse(g.isActive, "locked session ends on the stop press")
        // The stop press's own release is a harmless stray.
        XCTAssertEqual(g.keyUp(at: 1.05), .none, "the stop press's release is a stray no-op")
        XCTAssertFalse(g.isActive)
    }

    // MARK: Tap-tap-tap (lock then immediately stop)

    func testTapTapTapLocksThenStops() {
        var g = ActivationGesture()
        XCTAssertEqual(g.keyDown(at: 0), .begin)
        XCTAssertEqual(g.keyUp(at: 0.1), .deferEnd(fireAt: 0.1 + dbl))
        XCTAssertEqual(g.keyDown(at: 0.2), .lock, "second press locks")
        XCTAssertEqual(g.keyUp(at: 0.25), .none)
        // A third quick press (still hands-free intent) stops the freshly-locked
        // session — tap-tap to start hands-free, tap once more to stop.
        XCTAssertEqual(g.keyDown(at: 0.3), .end, "the third press stops the locked session")
        XCTAssertFalse(g.isActive)
    }

    // MARK: A tap after a lone-tap session has fully ended

    func testSecondTapAfterTimeoutIsANewSession() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 0.1)
        XCTAssertEqual(g.timerFired(at: 0.1 + dbl), .end, "lone tap ends")
        // A press that arrives only AFTER the window closed is a brand-new gesture,
        // not a lock — it begins a fresh session.
        XCTAssertEqual(g.keyDown(at: 1.0), .begin, "a press after the window is a new session, not a lock")
        XCTAssertTrue(g.isHeld)
    }

    func testSecondPressExactlyAtDeadlineStillLocksIfTimerHasntFired() {
        // Ordering matters: if the second press is delivered before the timer tick,
        // it locks even at the deadline instant. (The machine is edge-ordered; the
        // caller delivers whichever event happened first.)
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 0.1)
        XCTAssertEqual(g.keyDown(at: 0.1 + dbl), .lock, "a second press at the deadline still locks if it arrives before the timer")
        XCTAssertTrue(g.isLocked)
    }

    // MARK: Reconcile during lock (isLocked/isHeld exemption contract)

    func testLockedSessionIsExemptFromReconcile() {
        // The reconcile tick in HotKeyMonitor force-ends only when `isHeld`. A locked
        // session has no key held, so it must report isHeld == false (and isLocked
        // == true) — otherwise a "modifier is physically up" reconcile would kill the
        // lock. This test pins that contract.
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 0.1)
        _ = g.keyDown(at: 0.2)                // locked
        XCTAssertFalse(g.isHeld, "a locked session must NOT read as held (reconcile exemption)")
        XCTAssertTrue(g.isLocked)
        XCTAssertTrue(g.isActive)
    }

    func testAwaitingSecondTapIsExemptFromReconcile() {
        // While awaiting the second tap the key is already up (that's what started
        // the wait). A reconcile firing on "key is up" must not pre-empt the tap-tap
        // window, so this phase must also report isHeld == false.
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 0.1)
        XCTAssertFalse(g.isHeld, "awaiting-second-tap must NOT read as held")
        XCTAssertTrue(g.isActive, "but it is still an active (recording) session")
    }

    func testHeldSessionReportsHeldForReconcile() {
        // The one phase reconcile IS allowed to force-end: a plain hold in progress.
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        XCTAssertTrue(g.isHeld, "a hold in progress reports .isHeld so reconcile can rescue a dropped key-up")
    }

    // MARK: Key rebind mid-hold (reset semantics)

    func testResetDuringHoldReportsActiveAndClears() {
        // On a binding change mid-hold, HotKeyMonitor resets the machine and
        // synthesizes its own deactivate; the machine must go idle and report that a
        // session was active (so the monitor knows to fire the end) WITHOUT emitting
        // a second .end of its own.
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        XCTAssertTrue(g.reset(), "reset during a hold reports the session was active")
        XCTAssertFalse(g.isActive, "reset clears the machine to idle")
        // After a reset the next key-down is a clean new session.
        XCTAssertEqual(g.keyDown(at: 5), .begin, "post-reset, a key-down begins fresh")
    }

    func testResetDuringLockReportsActive() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 0.1)
        _ = g.keyDown(at: 0.2)                // locked
        XCTAssertTrue(g.reset(), "reset during a lock reports the session was active")
        XCTAssertFalse(g.isActive)
        XCTAssertFalse(g.isLocked)
    }

    func testResetWhenIdleReportsInactive() {
        var g = ActivationGesture()
        XCTAssertFalse(g.reset(), "reset with no session reports inactive so the monitor fires no spurious end")
        XCTAssertFalse(g.isActive)
    }

    // MARK: Dropped-edge resilience

    func testDoubleKeyDownWithoutUpDoesNotDoubleBegin() {
        // A clean edge source can't press an already-pressed key, but if a key-up is
        // dropped we're conservatively still recording — a second down must not emit
        // a second .begin (which would try to start an overlapping session).
        var g = ActivationGesture()
        XCTAssertEqual(g.keyDown(at: 0), .begin)
        XCTAssertEqual(g.keyDown(at: 0.05), .none, "a duplicate key-down while held does not re-begin")
        XCTAssertTrue(g.isHeld)
    }

    func testStrayKeyUpWhenIdleIsNoOp() {
        var g = ActivationGesture()
        XCTAssertEqual(g.keyUp(at: 0), .none, "a key-up with no session is a harmless no-op")
        XCTAssertFalse(g.isActive)
    }

    func testTimerFiredWhenIdleIsNoOp() {
        var g = ActivationGesture()
        XCTAssertEqual(g.timerFired(at: 1), .none, "a timer tick with no pending defer is a no-op")
    }

    func testTimerFiredWhenHeldIsNoOp() {
        // A stale defer timer from a previous session must not end an unrelated hold
        // now in progress.
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        XCTAssertEqual(g.timerFired(at: 10), .none, "a stray timer must not end a live hold")
        XCTAssertTrue(g.isHeld)
    }

    // MARK: Full round-trips

    func testTwoConsecutiveHoldsAreIndependent() {
        var g = ActivationGesture()
        XCTAssertEqual(g.keyDown(at: 0), .begin)
        XCTAssertEqual(g.keyUp(at: 1), .end)
        XCTAssertEqual(g.keyDown(at: 2), .begin, "a second hold begins cleanly")
        XCTAssertEqual(g.keyUp(at: 3), .end, "and ends cleanly")
        XCTAssertFalse(g.isActive)
    }

    func testLockCycleThenHoldCycle() {
        var g = ActivationGesture()
        // Lock cycle.
        XCTAssertEqual(g.keyDown(at: 0), .begin)
        XCTAssertEqual(g.keyUp(at: 0.1), .deferEnd(fireAt: 0.1 + dbl))
        XCTAssertEqual(g.keyDown(at: 0.2), .lock)
        XCTAssertEqual(g.keyDown(at: 1.0), .end)      // stop the lock
        // Immediately a normal hold cycle works.
        XCTAssertEqual(g.keyDown(at: 2.0), .begin, "a hold after a lock cycle begins cleanly")
        XCTAssertEqual(g.keyUp(at: 3.0), .end)
        XCTAssertFalse(g.isActive)
    }
}
