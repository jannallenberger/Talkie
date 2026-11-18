import XCTest
@testable import Talkie

final class LaunchPresentationTests: XCTestCase {
    func testNormalLaunchShowsWindowEvenWhenOnboarded() {
        XCTAssertTrue(LaunchPresentation.shouldShowWindow(hasOnboarded: true, launchedAsLoginItem: false))
        XCTAssertTrue(LaunchPresentation.shouldShowWindow(hasOnboarded: false, launchedAsLoginItem: false))
    }
    func testLoginItemLaunchIsQuietOnlyAfterOnboarding() {
        XCTAssertFalse(LaunchPresentation.shouldShowWindow(hasOnboarded: true, launchedAsLoginItem: true))
        XCTAssertTrue(LaunchPresentation.shouldShowWindow(hasOnboarded: false, launchedAsLoginItem: true))
    }
}
