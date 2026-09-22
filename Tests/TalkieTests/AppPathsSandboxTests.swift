import XCTest
@testable import Talkie

/// Guards the test sandbox: a test run must never resolve the user's real
/// Talkie folders (a regression here silently wipes their dictionary).
final class AppPathsSandboxTests: XCTestCase {
    func testSupportDirectoryIsSandboxedUnderTests() {
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Talkie").standardizedFileURL.path
        XCTAssertNotNil(AppPaths.testSandboxRoot)
        XCTAssertNotEqual(AppPaths.supportDirectory().standardizedFileURL.path, real)
        XCTAssertTrue(AppPaths.supportDirectory().path.hasPrefix(AppPaths.testSandboxRoot!.path))
    }

    func testMeetingsDirectoryIsSandboxedUnderTests() {
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Talkie Meetings").standardizedFileURL.path
        XCTAssertNotEqual(AppPaths.meetingsDirectory().standardizedFileURL.path, real)
    }
}
