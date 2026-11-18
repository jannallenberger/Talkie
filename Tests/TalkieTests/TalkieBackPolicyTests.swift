import XCTest
@testable import Talkie

/// One back control per pushed page: the in-page chevron, never also the system one.
final class TalkieBackPolicyTests: XCTestCase {
    func testPushedPageHasExactlyOneBackControl() {
        let c = TalkieBackPolicy.controls(pushed: true)
        XCTAssertTrue(c.inPageChevron)
        XCTAssertFalse(c.systemBackButton)
        XCTAssertEqual([c.inPageChevron, c.systemBackButton].filter { $0 }.count, 1)
    }

    func testRootPageHasNoBackControl() {
        let c = TalkieBackPolicy.controls(pushed: false)
        XCTAssertFalse(c.inPageChevron)
        XCTAssertFalse(c.systemBackButton)
    }
}
