import XCTest
@testable import Talkie

/// Tests for the on-device search index (feature 19), exercising the PURE path —
/// `SearchEngine.makeIndex` (nonisolated, off-main) + `SemanticIndex` — not the
/// Combine wiring in `AppDelegate`. The bug these guard against: the index used to
/// be built exactly once at launch, so a dictation/meeting added afterwards was
/// never indexed and the session was unsearchable until relaunch.
final class SearchEngineTests: XCTestCase {

    private func dictation(_ text: String, at unix: Double = 1_700_000_000) -> DictationEntry {
        DictationEntry(timestampUnix: unix, text: text)
    }

    /// A record present at build time is found by a keyword from its text.
    func testIndexFindsAnExistingDictation() {
        let a = dictation("The quarterly roadmap review with the platform team alpha topic.")
        let index = SearchEngine.makeIndex(dictations: [a], meetings: [], graph: .empty)

        let hits = index.search("roadmap review platform")
        XCTAssertTrue(hits.contains { $0.id == "dictation:\(a.id.uuidString)" },
                      "Expected the existing dictation A to be found. Hits: \(hits.map(\.id))")
    }

    /// The regression guard: rebuilding the index over a record added "after launch"
    /// makes it searchable. Proves the rebuild path actually re-indexes new entries.
    func testRebuildIndexesAnEntryAddedAfterLaunch() {
        let a = dictation("The quarterly roadmap review with the platform team alpha topic.")
        let b = dictation("Standup notes about the billing migration and invoice export beta.")

        // First build: only A exists. B is not yet searchable.
        let initial = SearchEngine.makeIndex(dictations: [a], meetings: [], graph: .empty)
        XCTAssertFalse(initial.search("billing migration invoice").contains { $0.id == "dictation:\(b.id.uuidString)" },
                       "B should not be findable before it is indexed.")

        // Rebuild after B is "added after launch": now B is searchable.
        let rebuilt = SearchEngine.makeIndex(dictations: [a, b], meetings: [], graph: .empty)
        let hits = rebuilt.search("billing migration invoice")
        XCTAssertTrue(hits.contains { $0.id == "dictation:\(b.id.uuidString)" },
                      "Expected B (added after launch) to be searchable after rebuild. Hits: \(hits.map(\.id))")
    }

    /// Bounded input: a record whose text is far longer than `maxIndexedChars` still
    /// indexes and is found by a keyword that appears in the early (kept) portion.
    func testBoundedInputStillIndexesAndIsFound() {
        // Keyword sits at the very start; the rest is filler well past the bound.
        let keyword = "synchronization"
        let filler = String(repeating: "padding words here ", count: 2_000) // » maxIndexedChars
        let long = dictation("\(keyword) checkpoint at the very beginning. \(filler)")
        XCTAssertGreaterThan(long.text.count, SemanticIndex.maxIndexedChars,
                             "Test record must exceed the indexing bound to be meaningful.")

        let index = SearchEngine.makeIndex(dictations: [long], meetings: [], graph: .empty)
        let hits = index.search(keyword)
        XCTAssertTrue(hits.contains { $0.id == "dictation:\(long.id.uuidString)" },
                      "An early-text keyword should still match a record longer than the bound.")
    }

    /// Meetings flatten into searchable records too (summary + transcript), keyed by id.
    func testMeetingIsIndexedAndFound() {
        let m = Meeting(title: "Sync", startUnix: 1_700_000_500, durationSec: 600,
                        transcript: "We discussed the onboarding funnel and activation metrics.",
                        summary: "Onboarding funnel review.", fileName: "sync.md")
        let index = SearchEngine.makeIndex(dictations: [], meetings: [m], graph: .empty)

        let hits = index.search("onboarding funnel activation")
        XCTAssertTrue(hits.contains { $0.id == "meeting:\(m.id.uuidString)" },
                      "Expected the meeting to be found. Hits: \(hits.map(\.id))")
    }
}
