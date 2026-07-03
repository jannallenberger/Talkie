import XCTest
@testable import Talkie

/// I2 — configurable history retention. `HistoryStore.retention` used to be a
/// hardcoded 7-day `let`; it's now driven by `AppSettings.historyRetentionDays`
/// (`0` = forever). These pin the pruning behaviour at each setting and the
/// honesty of the dashboard's "last 7 days" stat, which must stay a fixed 7-day
/// window regardless of how long history is retained.
///
/// Every store is built with a fresh temp `directory` so it neither reads the
/// developer's real `history.json` nor lets the debounced `save()` clobber it —
/// construction is hermetic (see `HistoryStore.init(retentionDays:directory:)`).
@MainActor
final class HistoryRetentionTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
    }

    private func store(retentionDays: Int) -> HistoryStore {
        HistoryStore(retentionDays: retentionDays, directory: tmpDir)
    }

    private func daysAgo(_ days: Double) -> Date {
        Date().addingTimeInterval(-days * 24 * 60 * 60)
    }

    /// Prune at 1-day retention drops yesterday's entry but keeps a fresh one.
    func testOneDayRetentionDropsYesterday() throws {
        let store = store(retentionDays: 1)
        // `add` prunes on insert, so a 2-day-old entry never survives at 1-day
        // retention, while a just-now entry does. (`add` returns the entry it
        // built regardless of pruning, so we assert on the stored set, not the
        // return value.)
        _ = store.add("stale", wordCount: 1, durationSec: 1, at: daysAgo(2))
        _ = store.add("fresh", wordCount: 1, durationSec: 1, at: Date())
        XCTAssertEqual(store.entries.map(\.text), ["fresh"],
                       "Only the fresh entry should remain at 1-day retention.")
    }

    /// Retention 0 (forever) keeps a 30-day-old entry — nothing is pruned by age.
    func testForeverRetentionKeepsOldEntry() throws {
        let store = store(retentionDays: 0)
        _ = store.add("month old", wordCount: 2, durationSec: 1, at: daysAgo(30))
        _ = store.add("today", wordCount: 1, durationSec: 1, at: Date())
        XCTAssertEqual(Set(store.entries.map(\.text)), ["month old", "today"],
                       "Forever retention must keep entries of any age.")
    }

    /// `wordsLast7Days` ignores an 8-day-old entry even under forever-retention:
    /// the dashboard window is a fixed 7 days, independent of how long history is
    /// retained.
    func testWordsLast7DaysIgnoresOldEntryUnderForever() throws {
        let store = store(retentionDays: 0)
        _ = store.add("eight days ago", wordCount: 100, durationSec: 1, at: daysAgo(8))
        _ = store.add("recent", wordCount: 5, durationSec: 1, at: daysAgo(1))
        // Both entries are retained (forever)…
        XCTAssertEqual(store.entries.count, 2, "Forever retention keeps both entries.")
        // …but only the last-7-days one counts toward the dashboard stat.
        XCTAssertEqual(store.wordsInLast7Days(now: Date()), 5,
                       "The 8-day-old entry must be excluded from the 7-day word count.")
    }

    /// Shrinking retention re-prunes immediately (no relaunch needed).
    func testShrinkingRetentionPrunesImmediately() throws {
        let store = store(retentionDays: 30)
        _ = store.add("three days old", wordCount: 3, durationSec: 1, at: daysAgo(3))
        _ = store.add("today", wordCount: 1, durationSec: 1, at: Date())
        XCTAssertEqual(store.entries.count, 2, "At 30-day retention both entries are kept.")

        store.updateRetention(days: 1)
        XCTAssertEqual(store.entries.map(\.text), ["today"],
                       "Shrinking to 1-day retention must drop the 3-day-old entry at once.")
    }

    /// Widening retention does not resurrect already-pruned entries (they're gone
    /// from memory) but also never prunes anything still present — a sanity guard
    /// that `updateRetention` to forever keeps the current set intact.
    func testWideningRetentionKeepsCurrentEntries() throws {
        let store = store(retentionDays: 7)
        _ = store.add("five days old", wordCount: 2, durationSec: 1, at: daysAgo(5))
        _ = store.add("today", wordCount: 1, durationSec: 1, at: Date())
        XCTAssertEqual(store.entries.count, 2)

        store.updateRetention(days: 0) // forever
        XCTAssertEqual(store.entries.count, 2,
                       "Widening to forever must not drop any currently-retained entry.")
    }
}
