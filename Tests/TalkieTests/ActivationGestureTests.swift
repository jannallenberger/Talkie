import XCTest
@testable import Talkie

/// Edge tests for the pure `ActivationGesture` machine: the key is an on/off switch.
/// The first press starts, the next press stops and inserts; releasing does nothing.
final class ActivationGestureTests: XCTestCase {

    func testFirstPressBeginsImmediately() {
        var g = ActivationGesture()
        XCTAssertEqual(g.keyDown(at: 0), .begin)
        XCTAssertTrue(g.isActive)
    }

    /// Jann's ask: nobody should have to hold the key for the whole dictation.
    func testReleaseKeepsRecording() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        XCTAssertEqual(g.keyUp(at: 0.1), .none)
        XCTAssertTrue(g.isActive, "letting go must not stop the session")
        XCTAssertEqual(g.keyUp(at: 30), .none)
        XCTAssertTrue(g.isActive)
    }

    func testSecondPressStops() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0); _ = g.keyUp(at: 0.1)
        XCTAssertEqual(g.keyDown(at: 12), .end)
        XCTAssertFalse(g.isActive)
        XCTAssertEqual(g.keyUp(at: 12.1), .none, "the release of the stopping press does nothing")
    }

    func testThirdPressStartsAgain() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0); _ = g.keyUp(at: 0.1)
        _ = g.keyDown(at: 5); _ = g.keyUp(at: 5.1)
        XCTAssertEqual(g.keyDown(at: 9), .begin)
    }

    func testHoldingThenReleasingStillLeavesItOn() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        XCTAssertEqual(g.keyUp(at: 4), .none)
        XCTAssertTrue(g.isActive)
    }

    /// A second down without an up (dropped key-up, repeat) must not switch it off.
    func testDuplicateDownIsIgnored() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)
        XCTAssertEqual(g.keyDown(at: 0.2), .none)
        XCTAssertTrue(g.isActive)
    }

    func testLostReleaseLetsTheNextPressStop() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0)          // the up for this press is lost
        g.releaseLost()
        XCTAssertFalse(g.isHeld)
        XCTAssertTrue(g.isActive, "a lost release never ends the session")
        XCTAssertEqual(g.keyDown(at: 3), .end)
    }

    /// Silence auto-stop or a failure ended the session: the next press starts anew.
    func testSessionEndedElsewhereMakesNextPressBegin() {
        var g = ActivationGesture()
        _ = g.keyDown(at: 0); _ = g.keyUp(at: 0.1)
        g.sessionEndedElsewhere()
        XCTAssertFalse(g.isActive)
        XCTAssertEqual(g.keyDown(at: 20), .begin)
    }

    func testResetReportsActiveAndGoesIdle() {
        var g = ActivationGesture()
        XCTAssertFalse(g.reset())
        _ = g.keyDown(at: 0)
        XCTAssertTrue(g.reset())
        XCTAssertFalse(g.isActive)
        XCTAssertEqual(g.keyDown(at: 1), .begin)
    }
}
