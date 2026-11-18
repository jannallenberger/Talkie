import XCTest
@testable import Talkie

/// The two-pane Meetings page's pure rules: which meeting is selected after the list
/// changes, how the list is grouped by date, and the new strings in all ten catalogs.
final class MeetingsPageModelTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    // MARK: Selection

    func testFirstLoadSelectsNewest() {
        XCTAssertEqual(MeetingSelection.resolve(current: nil, old: [], new: [a, b, c]), a)
    }

    func testFirstLoadKeepsARequestedSelection() {
        XCTAssertEqual(MeetingSelection.resolve(current: b, old: [], new: [a, b, c]), b)
    }

    func testEmptyListSelectsNothing() {
        XCTAssertNil(MeetingSelection.resolve(current: a, old: [a], new: []))
    }

    func testNewlyAddedMeetingBecomesSelected() {
        // A recording stopped / an import finished: the store inserts at the top.
        XCTAssertEqual(MeetingSelection.resolve(current: c, old: [a, b, c], new: [d, a, b, c]), d)
    }

    func testUpdateInPlaceKeepsSelection() {
        XCTAssertEqual(MeetingSelection.resolve(current: b, old: [a, b, c], new: [a, b, c]), b)
    }

    func testDeleteSelectsNextOlderNeighbour() {
        XCTAssertEqual(MeetingSelection.resolve(current: b, old: [a, b, c], new: [a, c]), c)
    }

    func testDeletingOldestSelectsNextNewer() {
        XCTAssertEqual(MeetingSelection.resolve(current: c, old: [a, b, c], new: [a, b]), b)
    }

    func testDeletingAnotherMeetingKeepsSelection() {
        XCTAssertEqual(MeetingSelection.resolve(current: a, old: [a, b, c], new: [a, c]), a)
    }

    func testDeletingLastMeetingSelectsNothing() {
        XCTAssertNil(MeetingSelection.resolve(current: a, old: [a], new: []))
    }

    func testArrowStepClampsAtEnds() {
        let ids = [a, b, c]
        XCTAssertEqual(MeetingSelection.step(from: b, in: ids, by: 1), c)
        XCTAssertEqual(MeetingSelection.step(from: c, in: ids, by: 1), c)
        XCTAssertEqual(MeetingSelection.step(from: a, in: ids, by: -1), a)
        XCTAssertEqual(MeetingSelection.step(from: nil, in: ids, by: 1), a)
        XCTAssertNil(MeetingSelection.step(from: a, in: [], by: 1))
    }

    // MARK: Date grouping

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2 // Monday
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testBuckets() {
        let now = date(2026, 11, 20, 15) // a Friday
        let cal = calendar
        XCTAssertEqual(MeetingDateBucket.bucket(for: date(2026, 11, 20, 9), now: now, calendar: cal), .today)
        XCTAssertEqual(MeetingDateBucket.bucket(for: date(2026, 11, 20, 18), now: now, calendar: cal), .today)
        XCTAssertEqual(MeetingDateBucket.bucket(for: date(2026, 11, 19), now: now, calendar: cal), .yesterday)
        XCTAssertEqual(MeetingDateBucket.bucket(for: date(2026, 11, 17), now: now, calendar: cal), .earlierThisWeek)
        XCTAssertEqual(MeetingDateBucket.bucket(for: date(2026, 11, 15), now: now, calendar: cal),
                       .month(year: 2026, month: 11))
        XCTAssertEqual(MeetingDateBucket.bucket(for: date(2026, 10, 2), now: now, calendar: cal),
                       .month(year: 2026, month: 10))
        XCTAssertEqual(MeetingDateBucket.bucket(for: date(2025, 11, 20), now: now, calendar: cal),
                       .month(year: 2025, month: 11))
    }

    func testYesterdayWinsOverThisWeekOnMonday() {
        let now = date(2026, 11, 16, 10) // Monday; yesterday is last week's Sunday
        XCTAssertEqual(MeetingDateBucket.bucket(for: date(2026, 11, 15), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(MeetingDateBucket.bucket(for: date(2026, 11, 14), now: now, calendar: calendar),
                       .month(year: 2026, month: 11))
    }

    func testGroupingKeepsOrderAndMergesRuns() {
        let now = date(2026, 11, 20, 15)
        let dates = [date(2026, 11, 20, 14), date(2026, 11, 20, 9), date(2026, 11, 19),
                     date(2026, 11, 18), date(2026, 10, 30), date(2026, 10, 2), date(2026, 9, 1)]
        let groups = MeetingDateBucket.group(dates, date: { $0 }, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.bucket), [.today, .yesterday, .earlierThisWeek,
                                              .month(year: 2026, month: 10), .month(year: 2026, month: 9)])
        XCTAssertEqual(groups.map(\.items.count), [2, 1, 1, 2, 1])
    }

    func testMonthTitleNamesMonthAndYear() {
        let title = MeetingDateBucket.month(year: 2026, month: 10).title(calendar: calendar)
        XCTAssertTrue(title.contains("2026"), title)
    }

    // MARK: Meta strings

    func testMeta() {
        XCTAssertEqual(MeetingMeta.speakers(nil), nil)
        XCTAssertEqual(MeetingMeta.speakers(0), nil)
        XCTAssertNotNil(MeetingMeta.speakers(3))
        XCTAssertNotNil(MeetingMeta.source("talkie (mic + system audio)"))
        XCTAssertNil(MeetingMeta.source("something else"))
        XCTAssertTrue(MeetingMeta.source("talkie (imported: interview.m4a)")?.contains("interview.m4a") ?? false)
    }

    // MARK: Catalogs

    func testNewStringsPresentInAllTenCatalogs() throws {
        let keys = ["Record", "Today", "Yesterday", "Earlier this week", "%d min", "1 speaker", "%d speakers",
                    "Imported", "Imported from %@", "Mic + call audio", "Mic only", "Notes only", "Recovered",
                    "Show in Finder", "Summary", "Transcript", "%d words", "Click a line to hear that moment",
                    "Press Record before your next call, or drop audio or video here to transcribe it."]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for l in ["en", "de", "es", "fr", "it", "ja", "ko", "nl", "pt-BR", "zh-Hans"] {
            let url = root.appendingPathComponent("Resources/Localizations/\(l).lproj/Localizable.strings")
            let dict = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], l)
            for k in keys {
                let v = dict[k] ?? ""
                XCTAssertFalse(v.isEmpty, "\(l): \(k)")
                XCTAssertEqual(k.contains("%d"), v.contains("%d"), "\(l): \(k)")
                XCTAssertEqual(k.contains("%@"), v.contains("%@"), "\(l): \(k)")
            }
        }
    }
}
