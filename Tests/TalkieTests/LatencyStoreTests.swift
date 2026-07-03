import XCTest
@testable import Talkie

/// L3a: `LatencyStore` keeps a rolling, numeric-only record of per-dictation
/// software latency in `latency.json` under Application Support.
///
/// The store reads/writes that fixed path, so the persistence tests snapshot
/// whatever is on disk in `setUp` and restore it in `tearDown` — a developer
/// running the suite never loses their real latency file (same discipline as
/// `WordFrequencyStoreTests` / `DictionaryStoreLoadTests`).
@MainActor
final class LatencyStoreTests: XCTestCase {
    private var fileURL: URL { AppPaths.supportDirectory().appendingPathComponent("latency.json") }
    private var saved: Data?

    override func setUp() {
        super.setUp()
        saved = try? Data(contentsOf: fileURL)
        try? FileManager.default.removeItem(at: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        if let d = saved { try? d.write(to: fileURL) }
        super.tearDown()
    }

    // MARK: Helpers

    /// Record one sample with sensible defaults; only override what a test cares about.
    private func record(
        _ store: LatencyStore,
        totalMs: Double = 100,
        finalizeMs: Double = 10,
        reTxMs: Double = 0,
        cleanupMs: Double = 80,
        insertMs: Double = 10,
        chars: Int = 42,
        streamed: Bool = false,
        optimistic: Bool = false,
        coldStart: Bool = false,
        mode: String = "paste",
        outcome: String = "inserted"
    ) {
        store.record(
            totalMs: totalMs, finalizeMs: finalizeMs, reTxMs: reTxMs,
            cleanupMs: cleanupMs, insertMs: insertMs, chars: chars,
            streamed: streamed, optimistic: optimistic, coldStart: coldStart,
            mode: mode, outcome: outcome
        )
    }

    // MARK: Rolling cap

    func testRollingCapEvictsOldest() {
        let store = LatencyStore()
        // Tag each record's total with its index so we can see which survived.
        for i in 0..<LatencyStore.maxRecords {
            record(store, totalMs: Double(i))
        }
        XCTAssertEqual(store.records.count, LatencyStore.maxRecords)
        XCTAssertEqual(store.records.first?.totalMs, 0, "before overflow the oldest (0) is still present")

        // The 51st record must drop the oldest (index 0) and keep newest-last order.
        record(store, totalMs: Double(LatencyStore.maxRecords)) // totalMs == 50
        XCTAssertEqual(store.records.count, LatencyStore.maxRecords,
                       "the store is held to the cap on save")
        XCTAssertEqual(store.records.first?.totalMs, 1,
                       "the oldest sample (0) was evicted; 1 is now the oldest")
        XCTAssertEqual(store.records.last?.totalMs, Double(LatencyStore.maxRecords),
                       "the newest sample sits at the end")
    }

    func testCapHoldsAcrossManyOverflows() {
        let store = LatencyStore()
        for i in 0..<(LatencyStore.maxRecords * 3) {
            record(store, totalMs: Double(i))
        }
        XCTAssertEqual(store.records.count, LatencyStore.maxRecords)
        // Only the most recent `maxRecords` survive; the first of those is
        // (3*cap - cap) = 2*cap.
        XCTAssertEqual(store.records.first?.totalMs, Double(LatencyStore.maxRecords * 2))
        XCTAssertEqual(store.records.last?.totalMs, Double(LatencyStore.maxRecords * 3 - 1))
    }

    // MARK: coldStart contract

    func testColdStartTrueOnlyOnFirstRecord() {
        // The store faithfully persists whatever `coldStart` the caller passes; the
        // AppDelegate flag makes exactly the first record of a launch cold. Simulate
        // that policy here: first true, all subsequent false.
        let store = LatencyStore()
        var firstRecorded = false
        for _ in 0..<5 {
            let cold = !firstRecorded
            firstRecorded = true
            record(store, coldStart: cold)
        }
        XCTAssertEqual(store.records.count, 5)
        XCTAssertTrue(store.records.first?.coldStart == true, "only the first sample is a cold start")
        XCTAssertEqual(store.records.dropFirst().filter { $0.coldStart }.count, 0,
                       "no later sample is marked cold")
    }

    // MARK: Persistence

    func testPersistsAndReloads() {
        do {
            let store = LatencyStore()
            record(store, totalMs: 123, cleanupMs: 90, chars: 7, streamed: true,
                   optimistic: true, coldStart: true, mode: "type", outcome: "leftOnClipboard")
        }
        let reloaded = LatencyStore()
        XCTAssertEqual(reloaded.records.count, 1)
        let r = reloaded.records[0]
        XCTAssertEqual(r.totalMs, 123)
        XCTAssertEqual(r.cleanupMs, 90)
        XCTAssertEqual(r.chars, 7)
        XCTAssertTrue(r.streamed)
        XCTAssertTrue(r.optimistic)
        XCTAssertTrue(r.coldStart)
        XCTAssertEqual(r.mode, "type")
        XCTAssertEqual(r.outcome, "leftOnClipboard")
    }

    func testCorruptFileLoadsEmpty() {
        try? Data("}{ not json at all".utf8).write(to: fileURL, options: .atomic)
        let store = LatencyStore()
        XCTAssertTrue(store.records.isEmpty, "a corrupt file must decode to an empty store")
        // And it's still usable afterward.
        record(store)
        XCTAssertEqual(store.records.count, 1)
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let store = LatencyStore()
        XCTAssertTrue(store.records.isEmpty)
    }

    func testMissingPerStageValuesDefaultToZero() {
        // A minimal older payload with only the two required keys must decode, with
        // every per-stage value defaulting to 0 (forward/back compatibility).
        let json = "[{\"unix\":1.0,\"totalMs\":200.0}]"
        try? Data(json.utf8).write(to: fileURL, options: .atomic)
        let store = LatencyStore()
        XCTAssertEqual(store.records.count, 1)
        let r = store.records[0]
        XCTAssertEqual(r.totalMs, 200)
        XCTAssertEqual(r.finalizeMs, 0)
        XCTAssertEqual(r.reTxMs, 0)
        XCTAssertEqual(r.cleanupMs, 0)
        XCTAssertEqual(r.insertMs, 0)
        XCTAssertEqual(r.chars, 0)
        XCTAssertFalse(r.streamed)
        XCTAssertEqual(r.mode, "")
        XCTAssertEqual(r.outcome, "")
    }

    // MARK: reset

    func testResetClearsAndPersists() {
        let store = LatencyStore()
        record(store)
        record(store)
        XCTAssertEqual(store.records.count, 2)
        store.reset()
        XCTAssertTrue(store.records.isEmpty)
        // The empty state persists — a fresh instance sees nothing.
        let reloaded = LatencyStore()
        XCTAssertTrue(reloaded.records.isEmpty)
    }

    // MARK: Stage-sum sanity

    func testStageSumApproximatesTotal() {
        // On a synthesized record the four stage durations should sum to ~the total
        // (the pipeline total is the wall-clock span the four stages tile). We allow
        // a small slack for any un-attributed time between marks.
        let store = LatencyStore()
        record(store, totalMs: 360, finalizeMs: 12, reTxMs: 6, cleanupMs: 330, insertMs: 12)
        let r = store.records[0]
        let stageSum = r.finalizeMs + r.reTxMs + r.cleanupMs + r.insertMs
        XCTAssertEqual(stageSum, r.totalMs, accuracy: 1.0,
                       "the four stage durations should tile the total")
    }
}
