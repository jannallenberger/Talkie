import Foundation

/// One day's dictation activity. Kept indefinitely (one tiny record per active
/// day) so the streak + contribution heatmap can span months — unlike
/// `HistoryStore`, which only retains the last 7 days of full transcripts.
struct DayStat: Codable {
    var words: Int = 0
    var dictations: Int = 0
}

/// A single cell in the contribution heatmap.
struct HeatCell: Identifiable {
    let id = UUID()
    /// nil for padding cells (before the window starts / future days).
    let date: Date?
    /// 0 = empty, 1…4 = increasing intensity.
    let level: Int
    let words: Int
    var isFuture = false
}

/// Everything the heatmap view needs: week-columns (Sunday-first, 7 rows each)
/// plus a month label per column (empty when the month didn't change).
struct HeatmapData {
    var weeks: [[HeatCell]]
    var monthLabels: [String]
}

/// Per-day activity log driving the streak counter and the contribution heatmap.
@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var days: [String: DayStat] = [:]

    private let fileURL: URL
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday
        return c
    }()

    /// `directory` defaults to the real support dir; tests pass a temp dir so they
    /// neither read the developer's real `activity.json` (non-deterministic) nor let
    /// `save()` clobber it. Mirrors `HistoryStore(directory:)`.
    init(directory: URL? = nil) {
        fileURL = (directory ?? AppPaths.supportDirectory()).appendingPathComponent("activity.json")
        load()
    }

    // MARK: Recording

    func record(words: Int, at date: Date = Date()) {
        guard words > 0 else { return }
        let key = Self.key(for: date, calendar: calendar)
        var stat = days[key] ?? DayStat()
        stat.words += words
        stat.dictations += 1
        days[key] = stat
        save()
    }

    /// Lifetime dictation count needed before a broken biggest-word-day earns a HUD
    /// chip (K3). Mirrors `StatsStore.recordMinLifetimeDictations` so all three
    /// records share one honesty floor — day-one use never triggers confetti.
    static let recordMinLifetimeDictations = 10

    /// Record one dictation's words for today AND report the new all-time daily word
    /// total when today's running total FIRST crosses the previous all-time max —
    /// the "biggest word day" personal record (K3). Returns nil when no record broke
    /// (the common case).
    ///
    /// HONESTY GUARD (matching `StatsStore.record`): a crossing counts only when
    /// there was already a prior non-zero daily max on some OTHER day to beat AND the
    /// user has at least `recordMinLifetimeDictations` lifetime dictations behind
    /// them. So the very first busy day, and day-one use in general, never celebrates.
    /// "First crosses" means we compare today's total AFTER this dictation against the
    /// best of all previous days: a second big dictation the same day won't re-fire
    /// unless it pushes past the old max for the first time (today already held the
    /// max on the earlier call, so the previous-days max is unchanged and the
    /// strict `>` fails).
    @discardableResult
    func recordAndCheckBiggestDay(words: Int, at date: Date = Date()) -> Int? {
        guard words > 0 else { return nil }
        let key = Self.key(for: date, calendar: calendar)
        // Best word total across every day EXCEPT today, and the lifetime dictation
        // count — both measured BEFORE this dictation lands.
        let priorOtherDaysMax = days.filter { $0.key != key }.values.map(\.words).max() ?? 0
        let priorTodayWords = days[key]?.words ?? 0
        let priorLifetimeDictations = days.values.reduce(0) { $0 + $1.dictations }

        record(words: words, at: date)

        let newTodayWords = priorTodayWords + words
        let eligible = priorLifetimeDictations >= Self.recordMinLifetimeDictations
        // Only a genuine crossing: today must NOT have already been at/above the old
        // max (else it wasn't "first crossing" — the record was already ours), and it
        // must clear a real, non-zero prior max with enough history behind it.
        guard eligible,
              priorOtherDaysMax > 0,
              priorTodayWords <= priorOtherDaysMax,
              newTodayWords > priorOtherDaysMax
        else { return nil }
        return newTodayWords
    }

    /// The most words ever dictated in a single day — the "biggest word day"
    /// personal record, surfaced on the Dashboard's Records card (K3). Zero until
    /// the first active day. A pure read over `days`; detection of a *newly broken*
    /// record lives in `recordAndCheckBiggestDay`.
    var biggestWordDay: Int {
        days.values.map(\.words).max() ?? 0
    }

    func reset() {
        days = [:]
        save()
    }

    // MARK: Streaks

    /// Consecutive days (ending today, or yesterday if today is still empty) with
    /// at least one dictation.
    var currentStreak: Int {
        var streak = 0
        var day = calendar.startOfDay(for: Date())
        // Allow today to be empty without breaking a streak that ran through
        // yesterday — you just haven't dictated *yet* today.
        if !hasActivity(on: day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        while hasActivity(on: day) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    /// The longest run of consecutive active days ever recorded.
    var longestStreak: Int {
        let activeDays = days.filter { $0.value.dictations > 0 }.keys
            .compactMap { Self.date(fromKey: $0, calendar: calendar) }
            .map { calendar.startOfDay(for: $0) }
            .sorted()
        guard !activeDays.isEmpty else { return 0 }

        var longest = 1, run = 1
        for i in 1..<activeDays.count {
            let gap = calendar.dateComponents([.day], from: activeDays[i - 1], to: activeDays[i]).day ?? 0
            if gap == 1 { run += 1; longest = max(longest, run) }
            else if gap > 1 { run = 1 }
        }
        return longest
    }

    private func hasActivity(on day: Date) -> Bool {
        (days[Self.key(for: day, calendar: calendar)]?.dictations ?? 0) > 0
    }

    // MARK: Daily series (dashboard words-per-day chart)

    /// One point per day for the trailing `count` days, oldest → newest and
    /// including today (days with no activity report `0`). Reads the same
    /// on-device `days` tally the heatmap does — nothing networked, no estimate —
    /// so the dashboard's words-per-day chart stays as honest as every other stat.
    func dailyWords(days count: Int) -> [(date: Date, words: Int)] {
        guard count > 0 else { return [] }
        let today = calendar.startOfDay(for: Date())
        var out: [(date: Date, words: Int)] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let words = days[Self.key(for: day, calendar: calendar)]?.words ?? 0
            out.append((date: day, words: words))
        }
        return out
    }

    // MARK: Heatmap

    /// Build the contribution grid for the trailing `weeks` weeks up to this week.
    func heatmap(weeks weekCount: Int = 26) -> HeatmapData {
        let today = calendar.startOfDay(for: Date())
        // Find the Monday that starts the current week.
        let weekday = calendar.component(.weekday, from: today) // 1 = Sun … 7 = Sat
        let daysFromMonday = (weekday + 5) % 7
        guard let thisWeekStart = calendar.date(byAdding: .day, value: -daysFromMonday, to: today),
              let firstColumnStart = calendar.date(byAdding: .day, value: -7 * (weekCount - 1), to: thisWeekStart)
        else { return HeatmapData(weeks: [], monthLabels: []) }

        // Adaptive thresholds: scale intensity to the user's own busiest day.
        let maxWords = max(1, days.values.map(\.words).max() ?? 1)

        var grid: [[HeatCell]] = []
        var labels: [String] = []
        var lastMonth = -1
        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "MMM"

        for w in 0..<weekCount {
            guard let columnStart = calendar.date(byAdding: .day, value: 7 * w, to: firstColumnStart) else { continue }
            var column: [HeatCell] = []
            for d in 0..<7 {
                guard let cellDate = calendar.date(byAdding: .day, value: d, to: columnStart) else { continue }
                if cellDate > today {
                    column.append(HeatCell(date: cellDate, level: 0, words: 0, isFuture: true))
                } else {
                    let words = days[Self.key(for: cellDate, calendar: calendar)]?.words ?? 0
                    column.append(HeatCell(date: cellDate, level: level(for: words, max: maxWords), words: words))
                }
            }
            grid.append(column)

            // Month label sits on the first column whose top cell is in a new month.
            let month = calendar.component(.month, from: columnStart)
            if month != lastMonth {
                labels.append(monthFmt.string(from: columnStart))
                lastMonth = month
            } else {
                labels.append("")
            }
        }
        return HeatmapData(weeks: grid, monthLabels: labels)
    }

    private func level(for words: Int, max maxWords: Int) -> Int {
        guard words > 0 else { return 0 }
        let frac = Double(words) / Double(maxWords)
        switch frac {
        case 0.75...: return 4
        case 0.5..<0.75: return 3
        case 0.25..<0.5: return 2
        default: return 1
        }
    }

    // MARK: Keys & persistence

    private static func key(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func date(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        return calendar.date(from: c)
    }

    private func load() {
        guard let decoded = StoreLoad.loadJSONWithQuarantine([String: DayStat].self, from: fileURL) else { return }
        days = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
