import XCTest
@testable import Talkie

/// Configurable history count cap. `HistoryStore.maxCount` used to be a hardcoded
/// `let cap = 2000`; it's now driven by `AppSettings.historyMaxCount` (`0` = no
/// limit) and changeable live via `updateMaxCount(_:)`. These pin the trimming at
/// each setting, independent of the (separately tested) time-based retention.
///
/// Every store uses forever-retention (`retentionDays: 0`) so age-pruning can't
/// interfere with the count assertions, and a fresh temp `directory` so it's
/// hermetic (see `HistoryStore.init(retentionDays:maxCount:directory:)`).
@MainActor
final class HistoryMaxCountTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-maxcount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
    }

    private func store(maxCount: Int) -> HistoryStore {
        HistoryStore(retentionDays: 0, maxCount: maxCount, directory: tmpDir)
    }

    /// Insert five entries under a cap of three: only the three most recent survive,
    /// oldest-first drops off (entries are newest-first, so the tail is the oldest).
    func testCapTrimsOldestOnAdd() throws {
        let store = store(maxCount: 3)
        for text in ["a", "b", "c", "d", "e"] {
            _ = store.add(text, wordCount: 1, durationSec: 1)
        }
        XCTAssertEqual(store.entries.map(\.text), ["e", "d", "c"],
                       "A cap of 3 must keep only the 3 most recent, dropping a and b.")
    }

    /// A cap of 0 ("no limit") retains everything.
    func testUnlimitedKeepsEverything() throws {
        let store = store(maxCount: 0)
        for i in 0..<50 {
            _ = store.add("entry \(i)", wordCount: 1, durationSec: 1)
        }
        XCTAssertEqual(store.entries.count, 50, "No-limit (0) must keep all entries.")
    }

    /// Lowering the cap re-trims immediately (no relaunch), keeping the newest.
    func testLoweringCapTrimsImmediately() throws {
        let store = store(maxCount: 10)
        for text in ["a", "b", "c", "d", "e"] {
            _ = store.add(text, wordCount: 1, durationSec: 1)
        }
        XCTAssertEqual(store.entries.count, 5, "Under a cap of 10 all 5 are kept.")

        store.updateMaxCount(2)
        XCTAssertEqual(store.entries.map(\.text), ["e", "d"],
                       "Lowering the cap to 2 must drop everything but the 2 newest at once.")
    }

    /// Raising the cap never drops anything already present.
    func testRaisingCapKeepsCurrentEntries() throws {
        let store = store(maxCount: 3)
        for text in ["a", "b", "c"] {
            _ = store.add(text, wordCount: 1, durationSec: 1)
        }
        store.updateMaxCount(0) // no limit
        XCTAssertEqual(store.entries.count, 3,
                       "Raising the cap to no-limit must not drop any current entry.")
    }
}
