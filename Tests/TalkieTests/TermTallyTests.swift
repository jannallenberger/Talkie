import XCTest
@testable import Talkie

/// K5 — per-term fix tally ("Words you taught me").
@MainActor
final class TermTallyTests: XCTestCase {
    private func makeStore() -> StatsStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-termtally-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return StatsStore(directory: dir)
    }

    /// One increment per term per dictation call (the caller pre-dedupes each list).
    func testOneIncrementPerDictation() {
        let s = makeStore()
        s.recordTermFixes(["claude.md", "Coralate"])
        s.recordTermFixes(["claude.md"])
        XCTAssertEqual(s.termFixCounts["claude.md"], 2)
        XCTAssertEqual(s.termFixCounts["Coralate"], 1)
    }

    func testEmptyAndBlankIgnored() {
        let s = makeStore()
        s.recordTermFixes([])
        s.recordTermFixes(["   ", ""])
        XCTAssertTrue(s.termFixCounts.isEmpty)
        XCTAssertTrue(s.termFirstFixedUnix.isEmpty)
    }

    func testTrimsWhitespace() {
        let s = makeStore()
        s.recordTermFixes(["  Higgsfield  "])
        XCTAssertEqual(s.termFixCounts["Higgsfield"], 1)
        XCTAssertNil(s.termFixCounts["  Higgsfield  "])
    }

    /// Ordered by count desc, oldest first-fixed breaking ties.
    func testTopTaughtWordsOrdering() {
        let s = makeStore()
        s.recordTermFixes(["a"])            // a first-seen earliest
        s.recordTermFixes(["b"])
        s.recordTermFixes(["a", "b", "c"])
        s.recordTermFixes(["a", "b"])       // a:3, b:3, c:1
        XCTAssertEqual(s.topTaughtWords(limit: 3).map(\.term), ["a", "b", "c"])
        XCTAssertEqual(s.topTaughtWords(limit: 1).first?.count, 3)
    }

    /// The cap evicts lowest-count terms; a heavily-used term always survives.
    func testCapEvictsLowestCount() {
        let s = makeStore()
        for _ in 0..<5 { s.recordTermFixes(["keep"]) }          // keep: count 5
        for i in 0..<(StatsStore.maxTrackedTerms + 50) {
            s.recordTermFixes(["t\(i)"])                          // each: count 1
        }
        XCTAssertLessThanOrEqual(s.termFixCounts.count, StatsStore.maxTrackedTerms)
        XCTAssertEqual(s.termFixCounts["keep"], 5, "a high-count term must survive eviction")
        XCTAssertEqual(s.termFirstFixedUnix.count, s.termFixCounts.count,
                       "first-seen map stays in lockstep with counts after eviction")
    }

    func testResetClears() {
        let s = makeStore()
        s.recordTermFixes(["x", "y"])
        s.reset()
        XCTAssertTrue(s.termFixCounts.isEmpty)
        XCTAssertTrue(s.termFirstFixedUnix.isEmpty)
    }

    func testPersistsAcrossReload() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-termtally-persist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s1 = StatsStore(directory: dir)
        s1.recordTermFixes(["claude.md"])
        s1.recordTermFixes(["claude.md"])
        XCTAssertEqual(s1.termFixCounts["claude.md"], 2)

        let s2 = StatsStore(directory: dir)
        XCTAssertEqual(s2.termFixCounts["claude.md"], 2)
        XCTAssertNotNil(s2.termFirstFixedUnix["claude.md"])
    }
}
