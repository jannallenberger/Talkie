import XCTest
@testable import Talkie

/// L3b — the pure math behind the Dictation Speed card and its "why it might be
/// slow" detail page: the grade thresholds, the median-with-exclusions reads over
/// `LatencyStore`, and the waterfall's proportion math. All three are presentation
/// logic over measured numbers, so they're pinned here without touching any view.
///
/// The store reads/writes a fixed `latency.json`, so (like `LatencyStoreTests`)
/// the store-backed cases snapshot the real file in `setUp` and restore it in
/// `tearDown` — a developer running the suite never loses their latency history.
@MainActor
final class SpeedDiagnosticsTests: XCTestCase {
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

    private func record(
        _ store: LatencyStore,
        totalMs: Double = 1000,
        finalizeMs: Double = 100,
        reTxMs: Double = 0,
        cleanupMs: Double = 800,
        insertMs: Double = 100,
        chars: Int = 42,
        optimistic: Bool = false,
        coldStart: Bool = false
    ) {
        store.record(
            totalMs: totalMs, finalizeMs: finalizeMs, reTxMs: reTxMs,
            cleanupMs: cleanupMs, insertMs: insertMs, chars: chars,
            streamed: false, optimistic: optimistic, coldStart: coldStart,
            mode: "paste", outcome: "inserted"
        )
    }

    // MARK: - Grade threshold boundaries

    /// The buckets are exclusive on the low side: each threshold value belongs to
    /// the SLOWER bucket it opens (800 → Fast, 1500 → OK, 3000 → Slow).
    func testGradeBoundaries() {
        // Instant: strictly under 800 ms.
        XCTAssertEqual(SpeedGrade.grade(medianMs: 0), .instant)
        XCTAssertEqual(SpeedGrade.grade(medianMs: 799.9), .instant)
        // 800 is the first Fast value (boundary belongs to the slower bucket).
        XCTAssertEqual(SpeedGrade.grade(medianMs: 800), .fast)
        XCTAssertEqual(SpeedGrade.grade(medianMs: 1499.9), .fast)
        // 1500 is the first OK value.
        XCTAssertEqual(SpeedGrade.grade(medianMs: 1500), .ok)
        XCTAssertEqual(SpeedGrade.grade(medianMs: 2999.9), .ok)
        // 3000 and up is Slow.
        XCTAssertEqual(SpeedGrade.grade(medianMs: 3000), .slow)
        XCTAssertEqual(SpeedGrade.grade(medianMs: 10_000), .slow)
    }

    // MARK: - Median-with-exclusions math

    func testMedianOddCount() {
        XCTAssertEqual(LatencyStore.median([3, 1, 2]), 2)
    }

    func testMedianEvenCountAveragesMiddleTwo() {
        // Sorted [10, 20, 30, 40] → (20 + 30) / 2 = 25.
        XCTAssertEqual(LatencyStore.median([40, 10, 30, 20]), 25)
    }

    func testMedianEmptyIsNil() {
        XCTAssertNil(LatencyStore.median([]))
    }

    func testMedianTotalExcludesColdStartAndOptimistic() {
        let store = LatencyStore()
        // Three steady-state samples (100/200/300) plus a cold start and an
        // optimistic sample whose totals would skew a naive median.
        record(store, totalMs: 100)
        record(store, totalMs: 200)
        record(store, totalMs: 300)
        record(store, totalMs: 9000, coldStart: true)
        record(store, totalMs: 8000, optimistic: true)

        // Excluding both, the median of {100, 200, 300} is 200.
        XCTAssertEqual(store.medianTotalMs(excludingColdStart: true, excludingOptimistic: true), 200)
        // The steady-state count reflects only the three kept samples.
        XCTAssertEqual(store.steadyStateSampleCount, 3)
        // Without exclusions, all five are medianed: sorted
        // [100, 200, 300, 8000, 9000] → 300.
        XCTAssertEqual(store.medianTotalMs(), 300)
    }

    func testMedianTotalNilWhenEverySampleExcluded() {
        let store = LatencyStore()
        record(store, totalMs: 5000, coldStart: true)
        record(store, totalMs: 6000, optimistic: true)
        // Both samples are excluded → no representative sample → nil (so the UI
        // shows an honest empty state instead of a fabricated 0).
        XCTAssertNil(store.medianTotalMs(excludingColdStart: true, excludingOptimistic: true))
        XCTAssertEqual(store.steadyStateSampleCount, 0)
    }

    func testColdStartSampleSurfacedSeparately() {
        let store = LatencyStore()
        record(store, totalMs: 7000, coldStart: true)
        record(store, totalMs: 100)
        record(store, totalMs: 200)
        // The cold start is retrievable on its own, and never in the steady median.
        XCTAssertEqual(store.coldStartSample?.totalMs, 7000)
        XCTAssertEqual(store.medianTotalMs(excludingColdStart: true, excludingOptimistic: true), 150)
    }

    func testStageMediansAreIndependentPerStage() {
        let store = LatencyStore()
        // reTx is 0 on two of three; its median must be 0 without dragging the
        // other stages, which are medianed independently.
        record(store, finalizeMs: 10, reTxMs: 0,   cleanupMs: 100, insertMs: 10)
        record(store, finalizeMs: 20, reTxMs: 0,   cleanupMs: 200, insertMs: 20)
        record(store, finalizeMs: 30, reTxMs: 600, cleanupMs: 300, insertMs: 30)
        let s = store.stageMedians(excludingColdStart: true, excludingOptimistic: true)
        XCTAssertEqual(s.finalizeMs, 20)
        XCTAssertEqual(s.reTxMs, 0)       // median of {0, 0, 600}
        XCTAssertEqual(s.cleanupMs, 200)
        XCTAssertEqual(s.insertMs, 20)
        XCTAssertEqual(s.sumMs, 240)
    }

    func testStageMediansZeroWhenNoSamples() {
        let store = LatencyStore()
        XCTAssertEqual(store.stageMedians(), .zero)
    }

    func testRecentSamplesNewestFirst() {
        let store = LatencyStore()
        record(store, totalMs: 1)
        record(store, totalMs: 2)
        record(store, totalMs: 3)
        let recent = store.recentSamples(2)
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.first?.totalMs, 3, "newest sample comes first")
        XCTAssertEqual(recent.last?.totalMs, 2)
    }

    // MARK: - Waterfall proportion math

    func testWaterfallProportionsAreShareOfTotal() {
        let total = 1000.0
        XCTAssertEqual(LatencyStore.StageMedians.proportion(ms: 250, total: total), 0.25, accuracy: 1e-9)
        XCTAssertEqual(LatencyStore.StageMedians.proportion(ms: 1000, total: total), 1.0, accuracy: 1e-9)
        XCTAssertEqual(LatencyStore.StageMedians.proportion(ms: 0, total: total), 0.0, accuracy: 1e-9)
    }

    func testWaterfallProportionZeroTotalIsZero() {
        // A zero total (no data) must not divide by zero — every stage is 0.
        XCTAssertEqual(LatencyStore.StageMedians.proportion(ms: 5, total: 0), 0)
    }

    func testWaterfallProportionClampedToOne() {
        // Defensive: a stage larger than the passed total still clamps at 1 (bars
        // can't overflow the row).
        XCTAssertEqual(LatencyStore.StageMedians.proportion(ms: 1500, total: 1000), 1.0)
    }

    func testWaterfallProportionsSumToOneWhenStagesTileTotal() {
        // When the sum is used as the total (the real case), the four shares sum to 1.
        let s = LatencyStore.StageMedians(finalizeMs: 100, reTxMs: 50, cleanupMs: 800, insertMs: 50)
        let total = s.sumMs
        let sum = LatencyStore.StageMedians.proportion(ms: s.finalizeMs, total: total)
                + LatencyStore.StageMedians.proportion(ms: s.reTxMs, total: total)
                + LatencyStore.StageMedians.proportion(ms: s.cleanupMs, total: total)
                + LatencyStore.StageMedians.proportion(ms: s.insertMs, total: total)
        XCTAssertEqual(sum, 1.0, accuracy: 1e-9)
    }

    // MARK: - Memory-pressure "only-when-detected" contract

    func testSystemPressureStartsNormalAndClimbsOnlyUp() {
        let p = SystemPressure()
        // A fresh session has seen nothing → the row never shows.
        XCTAssertEqual(p.worstSeen, .normal)
        XCTAssertNil(p.lastEventUnix)

        // A normal "event" is a no-op (there is no such row on a healthy Mac).
        p.observe(.normal)
        XCTAssertEqual(p.worstSeen, .normal)
        XCTAssertNil(p.lastEventUnix)

        // A warning is recorded and stamped.
        p.observe(.warning)
        XCTAssertEqual(p.worstSeen, .warning)
        XCTAssertNotNil(p.lastEventUnix)

        // Critical climbs the worst-seen.
        p.observe(.critical)
        XCTAssertEqual(p.worstSeen, .critical)

        // A later dip back to warning does NOT lower the worst-seen (the row, once
        // earned this session, doesn't flicker away).
        p.observe(.warning)
        XCTAssertEqual(p.worstSeen, .critical)
    }
}
