import XCTest
@testable import Talkie

/// The Memory page's inline "Keep history" picker: shortening the window asks first
/// (with the exact count that would be pruned), lengthening or a no-loss change
/// applies directly. The count must match `HistoryStore.prune`.
final class RetentionChangeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ d: Double) -> Double { now.timeIntervalSince1970 - d * 86_400 }

    func testShorterOrdering() {
        XCTAssertTrue(RetentionChange.isShorter(from: 0, to: 90))   // forever → 90
        XCTAssertTrue(RetentionChange.isShorter(from: 30, to: 7))
        XCTAssertFalse(RetentionChange.isShorter(from: 7, to: 30))
        XCTAssertFalse(RetentionChange.isShorter(from: 7, to: 0))   // → forever
        XCTAssertFalse(RetentionChange.isShorter(from: 30, to: 30))
        XCTAssertFalse(RetentionChange.isShorter(from: 0, to: 0))
    }

    func testEntriesDeletedCountsOnlyOlderThanCutoff() {
        let ts = [daysAgo(1), daysAgo(6.9), daysAgo(8), daysAgo(40), daysAgo(100)]
        XCTAssertEqual(RetentionChange.entriesDeleted(timestamps: ts, newDays: 7, now: now), 3)
        XCTAssertEqual(RetentionChange.entriesDeleted(timestamps: ts, newDays: 30, now: now), 2)
        XCTAssertEqual(RetentionChange.entriesDeleted(timestamps: ts, newDays: 90, now: now), 1)
        XCTAssertEqual(RetentionChange.entriesDeleted(timestamps: ts, newDays: 0, now: now), 0)
        XCTAssertEqual(RetentionChange.entriesDeleted(timestamps: [], newDays: 7, now: now), 0)
        // Exactly at the cutoff is kept (prune drops strictly older).
        XCTAssertEqual(RetentionChange.entriesDeleted(timestamps: [daysAgo(7)], newDays: 7, now: now), 0)
    }

    func testConfirmationOnlyWhenShorterAndSomethingIsLost() {
        let ts = [daysAgo(2), daysAgo(45)]
        XCTAssertEqual(RetentionChange.confirmationCount(from: 0, to: 30, timestamps: ts, now: now), 1)
        XCTAssertEqual(RetentionChange.confirmationCount(from: 90, to: 7, timestamps: ts, now: now), 1)
        // Shorter but nothing that old: apply directly.
        XCTAssertNil(RetentionChange.confirmationCount(from: 0, to: 90, timestamps: ts, now: now))
        // Longer / same: never asks.
        XCTAssertNil(RetentionChange.confirmationCount(from: 7, to: 0, timestamps: ts, now: now))
        XCTAssertNil(RetentionChange.confirmationCount(from: 7, to: 7, timestamps: ts, now: now))
    }

    func testMessageStatesTheCount() {
        XCTAssertTrue(RetentionChange.confirmationMessage(count: 1).hasPrefix("1 older dictation will"))
        XCTAssertTrue(RetentionChange.confirmationMessage(count: 12).hasPrefix("12 older dictations will"))
    }

    func testQuickOptionsKeepTheCurrentValueVisible() {
        XCTAssertEqual(RetentionChange.quickOptions(current: .sevenDays),
                       [.sevenDays, .thirtyDays, .ninetyDays, .forever])
        XCTAssertEqual(RetentionChange.quickOptions(current: .oneDay),
                       [.oneDay, .sevenDays, .thirtyDays, .ninetyDays, .forever])
    }

    /// Cross-check against the real store's prune, in a temp directory.
    @MainActor
    func testCountMatchesHistoryStorePrune() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-change-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(retentionDays: 0, maxCount: 0, directory: dir)
        let real = Date()
        for d in [0.5, 3, 10, 20, 60] {
            store.add("entry \(d)", wordCount: 2, durationSec: 1,
                      at: real.addingTimeInterval(-d * 86_400))
        }
        let predicted = RetentionChange.entriesDeleted(
            timestamps: store.entries.map(\.timestampUnix), newDays: 7, now: Date())
        let before = store.entries.count
        store.updateRetention(days: 7)
        XCTAssertEqual(before - store.entries.count, predicted)
        XCTAssertEqual(predicted, 3)
    }
}
