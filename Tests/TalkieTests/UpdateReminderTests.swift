import XCTest
@testable import Talkie

final class UpdateReminderTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let build = Date(timeIntervalSince1970: 1_700_000_000)

    func testFreshBuildHidden() {
        XCTAssertEqual(UpdateReminder.decide(buildDate: build, now: build + 44 * day, lastDismissed: nil), .hidden)
    }
    func testShowsAtFortyFiveDays() {
        XCTAssertEqual(UpdateReminder.decide(buildDate: build, now: build + 45 * day, lastDismissed: nil), .show(days: 45))
        XCTAssertEqual(UpdateReminder.decide(buildDate: build, now: build + 100 * day + 5, lastDismissed: nil), .show(days: 100))
    }
    func testDismissHidesForFourteenDays() {
        let now = build + 60 * day
        XCTAssertEqual(UpdateReminder.decide(buildDate: build, now: now, lastDismissed: now - 13 * day), .hidden)
        XCTAssertEqual(UpdateReminder.decide(buildDate: build, now: now, lastDismissed: now - 14 * day), .show(days: 60))
    }
    func testMissingBuildDateHidden() {
        XCTAssertEqual(UpdateReminder.decide(buildDate: nil, now: build + 90 * day, lastDismissed: nil), .hidden)
    }
    func testClockBeforeBuildHidden() {
        XCTAssertEqual(UpdateReminder.decide(buildDate: build, now: build - day, lastDismissed: nil), .hidden)
    }
    func testFutureDismissalDoesNotSuppress() {
        let now = build + 60 * day
        XCTAssertEqual(UpdateReminder.decide(buildDate: build, now: now, lastDismissed: now + 30 * day), .show(days: 60))
    }
    func testParse() {
        XCTAssertNotNil(UpdateReminder.parseBuildDate("2026-09-22T10:00:00Z"))
        XCTAssertNil(UpdateReminder.parseBuildDate("garbage"))
        XCTAssertNil(UpdateReminder.parseBuildDate(nil))
        XCTAssertNil(UpdateReminder.parseBuildDate(""))
    }
}
