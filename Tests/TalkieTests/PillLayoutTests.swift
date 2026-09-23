import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// The capture pill hugs its content: compact with no words, as wide as the words
/// need (wrapping at the cap), and the waveform centred whenever there's room.
@MainActor
final class PillLayoutTests: XCTestCase {
    private func fitting<V: View>(_ view: V) -> CGSize {
        NSHostingView(rootView: view.fixedSize()).fittingSize
    }

    private var row: some View { Color.red.frame(width: 120, height: 20) }

    /// No words: the pill is exactly the status row — not the old fixed 260 pt.
    func testRowOnlyIsCompact() {
        let size = fitting(PillColumnLayout(spacing: 5, maxTailWidth: 260) { row })
        XCTAssertEqual(size.width, 120, accuracy: 0.5)
    }

    /// A few words narrower than the row don't widen the pill.
    func testShortTextKeepsRowWidth() {
        let size = fitting(PillColumnLayout(spacing: 5, maxTailWidth: 260) {
            row
            Text("Hi").font(.system(size: 11))
        })
        XCTAssertEqual(size.width, 120, accuracy: 0.5)
    }

    /// Long text grows the pill sideways only up to the cap, then wraps downward.
    func testLongTextCapsWidthAndWraps() {
        let long = String(repeating: "pressable buttons and a compact pill ", count: 4)
        let one = fitting(PillColumnLayout(spacing: 5, maxTailWidth: 260) {
            row
            Text("x").font(.system(size: 11))
        })
        let size = fitting(PillColumnLayout(spacing: 5, maxTailWidth: 260) {
            row
            Text(long).font(.system(size: 11)).lineLimit(5)
        })
        XCTAssertLessThanOrEqual(size.width, 260.5)
        XCTAssertGreaterThan(size.width, 200)
        XCTAssertGreaterThan(size.height, one.height + 20, "wrapped onto several lines")
    }

    // MARK: - CenteredRowLayout.centreX

    /// Plenty of room: dead centre.
    func testCentreWhenRoom() {
        let x = CenteredRowLayout.centreX(in: 0...300, leading: 10, centre: 80, trailing: 90, gap: 8)
        XCTAssertEqual(x, 110) // 150 - 40
    }

    /// Tight: never overlaps the trailing chips (the old ZStack ran into the lock).
    func testClampedClearOfTrailing() {
        let x = CenteredRowLayout.centreX(in: 0...200, leading: 10, centre: 80, trailing: 90, gap: 8)
        XCTAssertEqual(x + 80, 200 - 90 - 8, accuracy: 0.001)
    }

    /// Packed (natural width): sits right after the leading view.
    func testPackedSitsAfterLeading() {
        let packed: CGFloat = 10 + 8 + 80 + 8 + 90
        let x = CenteredRowLayout.centreX(in: 0...packed, leading: 10, centre: 80, trailing: 90, gap: 8)
        XCTAssertEqual(x, 18)
    }

    /// No trailing content: no trailing gap reserved.
    func testNoTrailingNoGap() {
        let x = CenteredRowLayout.centreX(in: 0...98, leading: 10, centre: 80, trailing: 0, gap: 8)
        XCTAssertEqual(x, 18)
    }
}
