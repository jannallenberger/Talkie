import XCTest
@testable import Talkie

/// The VoiceOver spoken summaries for the Dashboard's two chart cards.
///
/// Both charts collapse their dense marks (up to ~14 bars / ~182 heatmap cells)
/// into a single accessibility element whose `accessibilityValue` is one of these
/// strings — so this logic is *all* a VoiceOver user hears about the data. Pinned
/// here: the fallible parts — active-day counting, singular/plural agreement, the
/// busiest-day pick, the today vs. "none today" branch, the empty-state wording,
/// and exclusion of padding/future cells that render blank.
///
/// Assertions deliberately avoid the locale/timezone-formatted date substring
/// ("Mon 3"), which varies by machine; they check the numbers and structural
/// phrases the summary is built from.
final class DashboardChartSummaryTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private func day(_ d: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 3, day: d))!
    }

    // MARK: - Words-per-day bar chart

    func testWordsPerDay_allZero_readsEmpty() {
        let series = (1...14).map { (date: day($0), words: 0) }
        XCTAssertEqual(DashboardChartSummary.wordsPerDay(series: series, total: 0),
                       "No words recorded")
    }

    func testWordsPerDay_singleActiveDay_isSingularAndCountsToday() {
        // One active day, and it's the most recent element → spoken as "today".
        let series = [(date: day(1), words: 0), (date: day(2), words: 5)]
        let s = DashboardChartSummary.wordsPerDay(series: series, total: 5)
        XCTAssertTrue(s.contains("5 words across 1 active day"), s) // singular "day"
        XCTAssertFalse(s.contains("active days"), s)
        XCTAssertTrue(s.contains("with 5"), s)                      // busiest = the one day
        XCTAssertTrue(s.contains("5 today"), s)
    }

    func testWordsPerDay_picksBusiestAndHandlesQuietToday() {
        // Peak is the middle day; the most recent day is quiet → "none today".
        let series = [(date: day(1), words: 10),
                      (date: day(2), words: 30),
                      (date: day(3), words: 0)]
        let s = DashboardChartSummary.wordsPerDay(series: series, total: 40)
        XCTAssertTrue(s.contains("40 words across 2 active days"), s) // plural
        XCTAssertTrue(s.contains("with 30"), s)                       // busiest is 30, not 10
        XCTAssertTrue(s.contains("none today"), s)
        XCTAssertTrue(s.contains("busiest"), s)                       // has a busiest clause
    }

    // MARK: - Streak / contribution heatmap

    func testHeatmap_allZero_readsEmptyWithWindowLength() {
        let weeks = Array(repeating: (0..<7).map { _ in HeatCell(date: day(1), level: 0, words: 0) },
                          count: 6)
        let data = HeatmapData(weeks: weeks, monthLabels: [])
        XCTAssertEqual(DashboardChartSummary.heatmap(data),
                       "No dictation in the last 6 weeks")
    }

    func testHeatmap_summarizesActiveDaysTotalWindowAndPeak() {
        // Week 0: two active days (12, 40). Week 1: one active day (7). Peak = 40.
        let week0: [HeatCell] = [
            HeatCell(date: day(2), level: 2, words: 12),
            HeatCell(date: day(3), level: 4, words: 40),
        ] + (0..<5).map { HeatCell(date: day(4 + $0), level: 0, words: 0) }
        let week1: [HeatCell] = [HeatCell(date: day(9), level: 1, words: 7)]
            + (0..<6).map { HeatCell(date: day(10 + $0), level: 0, words: 0) }
        let data = HeatmapData(weeks: [week0, week1], monthLabels: [])

        let s = DashboardChartSummary.heatmap(data)
        XCTAssertTrue(s.contains("3 active days"), s)          // 12, 40, 7
        XCTAssertTrue(s.contains("59 words"), s)               // 12 + 40 + 7
        XCTAssertTrue(s.contains("in the last 2 weeks"), s)
        XCTAssertTrue(s.contains("Busiest"), s)
        XCTAssertTrue(s.contains("40 words"), s)               // the peak day
    }

    func testHeatmap_ignoresPaddingAndFutureCells() {
        // A nil-date padding cell and a future cell must not count toward the
        // active tally or the word total, even if they carry a (bogus) count.
        let week: [HeatCell] = [
            HeatCell(date: nil, level: 0, words: 99),               // padding — excluded
            HeatCell(date: day(2), level: 0, words: 0, isFuture: true), // future — excluded
            HeatCell(date: day(3), level: 3, words: 25),            // the only real active day
        ] + (0..<4).map { HeatCell(date: day(4 + $0), level: 0, words: 0) }
        let data = HeatmapData(weeks: [week], monthLabels: [])

        let s = DashboardChartSummary.heatmap(data)
        XCTAssertTrue(s.contains("1 active day"), s)  // singular; the 99 padding cell excluded
        XCTAssertTrue(s.contains("25 words"), s)
        XCTAssertFalse(s.contains("99"), s)           // bogus padding count never surfaces
    }
}
