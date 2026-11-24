import XCTest
@testable import Talkie

/// Edge tests for the pure `ActivationGesture` machine: hold to talk, let go to
/// transcribe. A release always ends the session, however long the key was held —
/// there is no hands-free latch.
final class ActivationGestureTests: XCTestCase {

    func testKeyDownBeginsImmediately() {
        var g = ActivationGesture()
        XCTAssertEqual(g.keyDown(at: 0), .begin)
        XCTAssertTrue(g.isActive)
        XCTAssertTrue(g.isHeld)
    }

    func testQuickTapEndsOnRelease() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        XCTAssertEqual(g.keyUp(at: 0.1), .end)
        XCTAssertFalse(g.isActive)
    }

    /// The bug this replaced: holding past half a second used to latch, so letting go
    /// kept recording. Now every release transcribes, even after a long hold.
    func testLongHoldStillEndsOnRelease() {
        for held in [0.6, 2.0, 45.0] {
            var g = ActivationGesture()
            _ = g.keyDown(at: 0)
            XCTAssertEqual(g.keyUp(at: held), .end, "held \(held) s")
            XCTAssertFalse(g.isActive)
        }
    }

    func testNextPressStartsAFreshSession() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 3)
        XCTAssertEqual(g.keyDown(at: 4), .begin)
        XCTAssertEqual(g.keyUp(at: 5), .end)
    }

    func testDroppedKeyUpDoesNotDoubleBegin() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        XCTAssertEqual(g.keyDown(at: 0.3), .none)
        XCTAssertEqual(g.keyUp(at: 0.4), .end)
    }

    func testStrayReleaseWhileIdleIsIgnored() {
        var g = ActivationGesture()
        XCTAssertEqual(g.keyUp(at: 0), .none)
        XCTAssertFalse(g.isActive)
    }

    func testResetReportsActiveAndGoesIdle() {
        var g = ActivationGesture()
        XCTAssertFalse(g.reset())
        _ = g.keyDown(at: 0)
        XCTAssertTrue(g.reset())
        XCTAssertFalse(g.isActive)
        XCTAssertEqual(g.keyUp(at: 1), .none, "reset already ended it; no second end")
    }
}
