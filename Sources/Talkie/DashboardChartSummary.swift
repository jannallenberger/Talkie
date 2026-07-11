import Foundation

/// The spoken VoiceOver summaries for the Dashboard's two data-visualization cards.
///
/// The "Words per day" bar chart and the streak/contribution heatmap both draw
/// dense, repeating marks (up to ~14 bars and ~182 heatmap cells) whose per-day
/// counts are otherwise reachable only through mouse `.help` tooltips — invisible
/// to VoiceOver. Rather than expose every mark as its own accessibility stop
/// (an impassable wall), each chart collapses to a single accessibility element
/// via `.accessibilityElement(children: .ignore)` and speaks one of these strings
/// as its `accessibilityValue`.
///
/// The wording lives here — separate from the views — so the exact phrase a
/// VoiceOver user hears is a named, unit-tested unit rather than logic buried in a
/// private view's computed property. Both summaries are derived from the very data
/// the marks are drawn from, so they can never drift from what's on screen.
enum DashboardChartSummary {

    /// Summary for the "Words per day" bar chart.
    ///
    /// - Parameters:
    ///   - series: the same `(date, words)` sequence the bars are drawn from,
    ///     oldest → newest (so `.last` is today).
    ///   - total: the sum of `series` word counts (passed in to match the big
    ///     number the card already shows).
    static func wordsPerDay(series: [(date: Date, words: Int)], total: Int) -> String {
        let active = series.filter { $0.words > 0 }
        guard !active.isEmpty else { return "No words recorded" }

        var parts = ["\(total) words across \(active.count) active \(active.count == 1 ? "day" : "days")"]
        if let peak = active.max(by: { $0.words < $1.words }) {
            let when = peak.date.formatted(.dateTime.weekday(.abbreviated).day())
            parts.append("busiest \(when) with \(peak.words)")
        }
        if let today = series.last {
            parts.append(today.words > 0 ? "\(today.words) today" : "none today")
        }
        return parts.joined(separator: ", ")
    }

    /// Summary for the streak/contribution heatmap, computed from the same cells
    /// the grid draws. Padding and future cells (which render blank) are ignored.
    static func heatmap(_ data: HeatmapData) -> String {
        let cells = data.weeks.flatMap { $0 }.filter { $0.date != nil && !$0.isFuture }
        let active = cells.filter { $0.words > 0 }
        let weeks = data.weeks.count
        guard !active.isEmpty else {
            return "No dictation in the last \(weeks) weeks"
        }

        let words = active.reduce(0) { $0 + $1.words }
        var summary = "\(active.count) active \(active.count == 1 ? "day" : "days"), "
            + "\(words) words in the last \(weeks) weeks"
        if let peak = active.max(by: { $0.words < $1.words }), let date = peak.date {
            let when = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            summary += ". Busiest \(when), \(peak.words) words"
        }
        return summary
    }
}
