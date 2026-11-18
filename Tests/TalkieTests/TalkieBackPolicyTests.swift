import XCTest
@testable import Talkie

/// One back control per pushed page: the in-page Liquid Glass button, never the
/// system toolbar back button (it would sit in the auto-hidden fullscreen bar).
/// Root pages show none.
final class TalkieBackPolicyTests: XCTestCase {
    func testPushedPageShowsOnlyTheInPageGlassButton() {
        let c = TalkieBackPolicy.controls(pushed: true)
        XCTAssertTrue(c.inPageGlassButton)
        XCTAssertFalse(c.systemBackButton)
        XCTAssertEqual([c.inPageGlassButton, c.systemBackButton].filter { $0 }.count, 1)
    }

    func testRootPageHasNoBackControl() {
        let c = TalkieBackPolicy.controls(pushed: false)
        XCTAssertFalse(c.inPageGlassButton)
        XCTAssertFalse(c.systemBackButton)
    }

    func testPushedAndRootPagesShareTheTopInset() {
        XCTAssertEqual(Theme.Space.pageTop, 36)
    }
}
