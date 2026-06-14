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

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("activity.json")
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
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: DayStat].self, from: data) else { return }
        days = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
