import XCTest
@testable import Talkie

/// K3 — honest personal records. Three invariants under test:
///
///  1. `PersonalRecord.chipPick` resolves the single HUD chip by the fixed
///     priority (biggest word day > fastest WPM > longest dictation), pure and
///     HUD-free.
///  2. `StatsStore.record` reports which records broke, but ONLY after the honesty
///     guard clears — a first-ever value and the first ten dictations never
///     celebrate, so day-one use isn't a confetti storm.
///  3. `ActivityStore.recordAndCheckBiggestDay` reports a new biggest word day
///     under the same guard, and never re-fires within a day it already leads.
///
/// Plus back-compat: an old `stats.json` written before K3 (no `longestDictation*`
/// fields) decodes cleanly with the new fields defaulting to zero.
///
/// Every store here is pointed at a fresh temp directory (the K3 `directory:` init
/// param), so the suite neither reads the developer's real `stats.json` /
/// `activity.json` nor lets `save()` clobber them. Mirrors `HistoryStore` tests.
@MainActor
final class PersonalRecordsTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("k3-records-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        tmpDir = nil
        try super.tearDownWithError()
    }

    // A comfortably-above-guards sample: 8 words in 3 s ≈ 160 WPM, inside the
    // ≥1.5 s / ≥4 words / <400 WPM sample floor `bestWPM` already enforced.
    private func recordSpeedSample(_ stats: StatsStore, words: Int = 8, seconds: Double = 3) -> [PersonalRecord] {
        stats.record(words: words, durationSec: seconds)
    }

    // MARK: - chipPick priority

    func testChipPickReturnsNilWhenNothingBroke() {
        XCTAssertNil(PersonalRecord.chipPick(from: []))
    }

    func testChipPickPrefersBiggestWordDayOverEverything() {
        let picked = PersonalRecord.chipPick(from: [
            .longestDictation(500),
            .fastestWPM(200),
            .biggestWordDay(1_000),
        ])
        XCTAssertEqual(picked, .biggestWordDay(1_000))
    }

    func testChipPickPrefersFastestWPMOverLongestDictation() {
        let picked = PersonalRecord.chipPick(from: [
            .longestDictation(500),
            .fastestWPM(180),
        ])
        XCTAssertEqual(picked, .fastestWPM(180))
    }

    func testChipPickReturnsTheLoneRecordWhenOnlyOneBroke() {
        XCTAssertEqual(PersonalRecord.chipPick(from: [.longestDictation(42)]), .longestDictation(42))
    }

    // MARK: - StatsStore first-ever & sub-threshold suppression

    func testFirstEverDictationBreaksNoRecord() {
        let stats = StatsStore(directory: tmpDir)
        let broken = recordSpeedSample(stats)
        XCTAssertTrue(broken.isEmpty, "the very first dictation is not a personal best — it's your first")
        // The underlying values are still tracked, they just don't celebrate.
        XCTAssertGreaterThan(stats.bestWPM, 0)
        XCTAssertEqual(stats.longestDictationWords, 8)
    }

    func testNoRecordChipUntilTenLifetimeDictations() {
        let stats = StatsStore(directory: tmpDir)
        // Dictations 1…10: even monotonically climbing values never chip while the
        // lifetime count is below the floor (the 10th call is the (9 prior)-th+1).
        for i in 1...10 {
            let broken = stats.record(words: 4 + i, durationSec: 3)
            XCTAssertTrue(broken.isEmpty, "dictation #\(i) is within the day-one grace window — no chip")
        }
        XCTAssertEqual(stats.totalDictations, 10)
    }

    func testFastestWPMRecordBreaksAfterGraceWindow() {
        let stats = StatsStore(directory: tmpDir)
        // Build up ten steady, identical samples (8 words / 3 s = 160 WPM) so the
        // WPM plateaus — no new record — and the lifetime floor is cleared.
        for _ in 0..<10 { _ = stats.record(words: 8, durationSec: 3) }
        let plateauWPM = stats.bestWPM
        // A genuinely faster sample (16 words / 3 s = 320 WPM, still under the <400
        // ceiling) now breaks the fastest-WPM record.
        let faster = stats.record(words: 16, durationSec: 3)
        XCTAssertGreaterThan(stats.bestWPM, plateauWPM)
        XCTAssertTrue(faster.contains(where: { if case .fastestWPM = $0 { return true }; return false }),
                      "a genuinely faster sample past the grace window breaks the WPM record")
    }

    func testLongestDictationRecordBreaksAfterGraceWindow() {
        let stats = StatsStore(directory: tmpDir)
        // Ten short-but-equal dictations clear the floor without ever growing the
        // longest (every one is 5 words).
        for _ in 0..<10 { _ = stats.record(words: 5, durationSec: 3) }
        XCTAssertEqual(stats.longestDictationWords, 5)
        // A clearly longer dictation now breaks the longest-dictation record.
        let broken = stats.record(words: 40, durationSec: 12)
        XCTAssertEqual(stats.longestDictationWords, 40)
        XCTAssertTrue(broken.contains(.longestDictation(40)),
                      "a longer dictation past the grace window breaks the longest record")
    }

    func testTieBreaksNoLongestRecord() {
        let stats = StatsStore(directory: tmpDir)
        for _ in 0..<10 { _ = stats.record(words: 5, durationSec: 3) }
        _ = stats.record(words: 40, durationSec: 12) // set the record
        let tie = stats.record(words: 40, durationSec: 12) // equal, not greater
        XCTAssertFalse(tie.contains(.longestDictation(40)), "a tie is not a new record")
    }

    func testZeroWordDictationRecordsNothing() {
        let stats = StatsStore(directory: tmpDir)
        let broken = stats.record(words: 0, durationSec: 3)
        XCTAssertTrue(broken.isEmpty)
        XCTAssertEqual(stats.totalDictations, 0, "a zero-word call is a no-op")
    }

    // MARK: - StatsStore persistence & back-compat

    func testRecordsSurviveRelaunch() {
        let dir = tmpDir!
        do {
            let stats = StatsStore(directory: dir)
            for _ in 0..<10 { _ = stats.record(words: 5, durationSec: 3) }
            _ = stats.record(words: 40, durationSec: 12)
            XCTAssertEqual(stats.longestDictationWords, 40)
        }
        // A fresh instance over the same dir reloads the persisted record.
        let reloaded = StatsStore(directory: dir)
        XCTAssertEqual(reloaded.longestDictationWords, 40)
        XCTAssertEqual(reloaded.longestDictationDurationSec, 12, accuracy: 0.001)
    }

    /// An old `stats.json` written before K3 has no `longestDictation*` keys. It
    /// must decode cleanly, keeping the fields it does carry and defaulting the new
    /// ones to zero — never crashing or wiping the pre-existing totals.
    func testBackCompatDecodeOfOldStatsJSON() throws {
        let legacy = """
        {"totalWords":1234,"totalDictations":50,"totalDurationSec":600.0,"bestWPM":150.0,\
        "dictionaryFixes":7,"fillersRemoved":3,"aiWordsChanged":2}
        """
        try Data(legacy.utf8).write(to: tmpDir.appendingPathComponent("stats.json"))

        let stats = StatsStore(directory: tmpDir)

        XCTAssertEqual(stats.totalWords, 1234)
        XCTAssertEqual(stats.totalDictations, 50)
        XCTAssertEqual(stats.bestWPM, 150, accuracy: 0.001)
        XCTAssertEqual(stats.dictionaryFixes, 7)
        // The new K3 fields are absent in the legacy file → default to zero.
        XCTAssertEqual(stats.longestDictationWords, 0)
        XCTAssertEqual(stats.longestDictationDurationSec, 0, accuracy: 0.001)
    }

    // MARK: - ActivityStore biggest-word-day detection

    func testBiggestWordDayReadsAllTimeMax() {
        let activity = ActivityStore(directory: tmpDir)
        let day1 = date(2026, 1, 1)
        let day2 = date(2026, 1, 2)
        activity.record(words: 100, at: day1)
        activity.record(words: 250, at: day2)
        XCTAssertEqual(activity.biggestWordDay, 250)
    }

    func testFirstBusyDayBreaksNoBiggestDayRecord() {
        let activity = ActivityStore(directory: tmpDir)
        // No prior history at all → the first day, however big, is not a "record."
        let broken = activity.recordAndCheckBiggestDay(words: 500, at: date(2026, 1, 1))
        XCTAssertNil(broken, "the very first day is not a biggest-word-day record")
    }

    func testBiggestWordDayNeedsTenLifetimeDictations() {
        let activity = ActivityStore(directory: tmpDir)
        // Seed a small prior max on day 1 with only a few dictations — under the
        // lifetime floor — so even beating it on day 2 doesn't chip yet.
        for _ in 0..<3 { activity.record(words: 10, at: date(2026, 1, 1)) } // day1 = 30 words, 3 dictations
        let broken = activity.recordAndCheckBiggestDay(words: 100, at: date(2026, 1, 2))
        XCTAssertNil(broken, "only 3 lifetime dictations — below the ≥10 honesty floor")
    }

    func testBiggestWordDayBreaksOnceFloorAndPriorMaxClear() {
        let activity = ActivityStore(directory: tmpDir)
        // Day 1: 10 dictations of 10 words = 100 words, clearing the lifetime floor
        // and establishing a real prior max of 100 on a DIFFERENT day.
        for _ in 0..<10 { activity.record(words: 10, at: date(2026, 1, 1)) }
        // Day 2: a single 150-word day crosses the prior 100-word max → record.
        let broken = activity.recordAndCheckBiggestDay(words: 150, at: date(2026, 1, 2))
        XCTAssertEqual(broken, 150)
        XCTAssertEqual(activity.biggestWordDay, 150)
    }

    func testBiggestWordDayDoesNotRefireSameDay() {
        let activity = ActivityStore(directory: tmpDir)
        for _ in 0..<10 { activity.record(words: 10, at: date(2026, 1, 1)) } // prior max 100
        let first = activity.recordAndCheckBiggestDay(words: 150, at: date(2026, 1, 2))
        XCTAssertEqual(first, 150, "the crossing fires once")
        // A second big dictation the SAME day already holds the lead → no re-fire,
        // even though the day's total keeps climbing.
        let second = activity.recordAndCheckBiggestDay(words: 200, at: date(2026, 1, 2))
        XCTAssertNil(second, "today already holds the record — it isn't re-broken")
        XCTAssertEqual(activity.biggestWordDay, 350) // 150 + 200
    }

    func testBiggestWordDayZeroWordIsNoOp() {
        let activity = ActivityStore(directory: tmpDir)
        for _ in 0..<10 { activity.record(words: 10, at: date(2026, 1, 1)) }
        XCTAssertNil(activity.recordAndCheckBiggestDay(words: 0, at: date(2026, 1, 2)))
    }

    // MARK: - helpers

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }
}
