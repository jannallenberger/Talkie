import XCTest
@testable import Talkie

/// Pins the geometry fix for the pill `hitTest` double-flip bug: `NSHostingView` is
/// already flipped (`isFlipped == true`), so `convert(point, from: superview)` already
/// yields a top-left-origin point matching the frame the SwiftUI pill publishes in the
/// "talkieHUD" space. The old code flipped that point a SECOND time
/// (`bounds.height - local.y`), mirroring the probe vertically and missing the pill
/// rect entirely — so every click on Undo/vibe/keep/cleanup/copy controls was dropped.
final class PillHitProbeTests: XCTestCase {

    func testFlippedViewReturnsPointUnchanged() {
        // The real case: `PassthroughHostingView` is an `NSHostingView`, which is
        // flipped, so the converted local point IS the top-left probe — no adjustment.
        let p = CGPoint(x: 12, y: 30)
        XCTAssertEqual(pillHitProbe(convertedLocalPoint: p, boundsHeight: 104, isFlipped: true), p)
    }

    func testNonFlippedViewMirrorsAcrossHeight() {
        // A hypothetical non-flipped host still needs the mirror — this is the
        // "old formula", kept correct for the case it actually applies to.
        let p = CGPoint(x: 12, y: 30)
        let mirrored = pillHitProbe(convertedLocalPoint: p, boundsHeight: 104, isFlipped: false)
        XCTAssertEqual(mirrored, CGPoint(x: 12, y: 74))
    }

    // MARK: - Regression: the double-flip dropped every pill click

    func testRegressionTopHuggingPillHitsWithFlippedFormulaButMissedWithOld() {
        // The pill sits at y∈[8,48] in a 104-pt panel — top-hugging, per the HUD
        // layout. A click lands at a converted local y of 30 (well inside the pill).
        let panelHeight: CGFloat = 104
        let pillRect = CGRect(x: 0, y: 8, width: 100, height: 40) // y∈[8,48]
        let hitBox = pillRect.insetBy(dx: -4, dy: -4)
        let convertedLocal = CGPoint(x: 50, y: 30)

        // New behavior (isFlipped: true, matching NSHostingView) hits the pill.
        let newProbe = pillHitProbe(convertedLocalPoint: convertedLocal, boundsHeight: panelHeight, isFlipped: true)
        XCTAssertTrue(hitBox.contains(newProbe), "flipped probe should land inside the pill's hit box")

        // Old behavior mirrored the point a second time: 104 - 30 = 74, which falls
        // well below the pill (outside even the 4pt slop) — proving the bug.
        let oldProbe = pillHitProbe(convertedLocalPoint: convertedLocal, boundsHeight: panelHeight, isFlipped: false)
        XCTAssertFalse(hitBox.contains(oldProbe), "the old double-flip formula must miss the pill")
        XCTAssertEqual(oldProbe.y, 74)
    }
}
