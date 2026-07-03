import XCTest
@testable import Talkie

/// G6 — App Intents foundation. The two intents (`ToggleDictationIntent`,
/// `GetLastDictationIntent`) drive `AppDelegate` and `HistoryStore`, which need a
/// live app (a running `AppDelegate.shared`, real speech engine) to exercise
/// end-to-end — that's the human Shortcuts/Raycast round-trip in the package's
/// acceptance criteria. What IS pure and worth pinning here is the one data
/// contract `GetLastDictationIntent` depends on: it returns
/// `history.entries.first?.text`, and that must be the *newest* dictation (the
/// intent maps a missing entry to an empty string, so the empty-history shape
/// matters too). If `HistoryStore`'s ordering ever flipped, the intent would
/// silently return the oldest dictation — these tests fail first.
///
/// Hermetic per `HistoryRetentionTests`: each store gets a fresh temp directory,
/// so it never reads or clobbers the developer's real `history.json`.
@MainActor
final class TalkieIntentsTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-intents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
    }

    private func store() -> HistoryStore {
        // Forever retention so age never prunes the entries these tests add.
        HistoryStore(retentionDays: 0, directory: tmpDir)
    }

    /// The value `GetLastDictationIntent` returns for an empty history is the
    /// `?? ""` fallback — assert the source of that fallback (`entries.first` is
    /// nil) so the intent's "" contract is grounded.
    func testEmptyHistoryHasNoLastEntry() throws {
        let store = store()
        XCTAssertNil(store.entries.first?.text,
                     "With no dictations, the intent's `entries.first?.text` is nil (→ empty string).")
    }

    /// The core contract: the most recently added dictation is `entries.first`,
    /// which is exactly what the intent returns. Add three; the last one wins.
    func testGetLastReturnsNewestEntryText() throws {
        let store = store()
        _ = store.add("first thing I said", wordCount: 4, durationSec: 2, at: Date().addingTimeInterval(-30))
        _ = store.add("second thing I said", wordCount: 4, durationSec: 2, at: Date().addingTimeInterval(-15))
        _ = store.add("most recent thing", wordCount: 3, durationSec: 2, at: Date())

        XCTAssertEqual(store.entries.first?.text, "most recent thing",
                       "Get Last Dictation must return the newest entry's text, not the oldest.")
    }

    /// A single dictation is trivially the newest — guards the one-entry path the
    /// intent hits right after a user's first-ever dictation.
    func testGetLastWithSingleEntry() throws {
        let store = store()
        _ = store.add("only dictation", wordCount: 2, durationSec: 1, at: Date())
        XCTAssertEqual(store.entries.first?.text, "only dictation",
                       "With one dictation, that entry is what the intent returns.")
    }
}
