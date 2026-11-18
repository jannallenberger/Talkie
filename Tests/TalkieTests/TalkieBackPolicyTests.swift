import XCTest
@testable import Talkie

/// One back control per pushed page: the system toolbar back button, never also
/// an in-page chevron. Root pages show none.
final class TalkieBackPolicyTests: XCTestCase {
    func testPushedPageShowsOnlyTheSystemBackButton() {
        let c = TalkieBackPolicy.controls(pushed: true)
        XCTAssertTrue(c.systemBackButton)
        XCTAssertFalse(c.inPageChevron)
        XCTAssertEqual([c.inPageChevron, c.systemBackButton].filter { $0 }.count, 1)
    }

    func testRootPageHasNoBackControl() {
        let c = TalkieBackPolicy.controls(pushed: false)
        XCTAssertFalse(c.inPageChevron)
        XCTAssertFalse(c.systemBackButton)
    }

    func testPushedPagesStartBelowTheToolbar() {
        XCTAssertEqual(Theme.Space.pageTop, 36)
        XCTAssertGreaterThanOrEqual(Theme.Space.pageTopPushed, 52)
    }
}
