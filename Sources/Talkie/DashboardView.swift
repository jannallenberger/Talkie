import SwiftUI
import AppKit

/// Real-world typing benchmarks the speed gauge compares you against. Honest:
/// Talkie is offline, so there's no percentile of other users — we anchor to
/// public references instead.
enum SpeedBenchmark {
    /// Sustained pace of an experienced office worker (~20 yrs at a keyboard).
    static let officeWorker = 40.0
    /// Barbara Blackburn — the fastest sustained typist on record.
    static let worldRecord = 212.0
}

// MARK: - Dashboard

struct DashboardView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var stats: StatsStore
    @ObservedObject var history: HistoryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var appUsage: AppUsageStore
    @ObservedObject var router: SettingsRouter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                HStack(alignment: .firstTextBaseline) {
                    PageHeader(title: "Dashboard",
                               subtitle: greeting)
                    Spacer()
                    StreakPill(days: activity.currentStreak)
                }

                // Row 1 — speed gauge · fixes · words.
                HStack(alignment: .top, spacing: Theme.Space.gridGap) {
                    GaugeCard(stats: stats)
                        .frame(width: 300)
                    FixesCard(stats: stats)
                    WordsCard(stats: stats, history: history)
                }
                .fixedSize(horizontal: false, vertical: true)

                // Row 2 — where your words went · contribution heatmap.
                // The streak card sizes to its (intrinsic-width) heatmap so the
                // grid is never clipped; the usage card flexes into the rest.
                HStack(alignment: .top, spacing: Theme.Space.gridGap) {
                    UsageCard(appUsage: appUsage)
                    StreakCard(activity: activity)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var greeting: String {
        let total = stats.totalWords
        if total == 0 { return "Hold your dictation key and speak — your stats will fill in here." }
        return "\(total.formatted()) words dictated, all on-device."
    }
}

// MARK: - Streak pill (header)

private struct StreakPill: View {
    let days: Int
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(days > 0 ? Theme.coral : Theme.inkTertiary)
            Text(days > 0 ? "\(days)-day streak" : "No streak yet")
                .font(.talkieHeading(12.5, weight: .semibold))
                .foregroundStyle(days > 0 ? Theme.ink : Theme.inkSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }
}

// MARK: - Speed gauge card

private struct GaugeCard: View {
    @ObservedObject var stats: StatsStore

    private var avg: Double { stats.averageWPM }
    private var hasData: Bool { avg > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Words per minute")
            ZStack {
                Gauge(fraction: min(1, avg / SpeedBenchmark.worldRecord))
                    .frame(height: 116)
                VStack(spacing: 0) {
                    Text(hasData ? "\(Int(avg.rounded()))" : "—")
                        .font(.talkieMetric(46))
                        .foregroundStyle(Theme.ink)
                    Text(hasData ? "avg wpm" : "no data yet")
                        .font(.talkieHeading(11, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                }
                .offset(y: 18)
            }
            .frame(maxWidth: .infinity)

            Divider().overlay(Theme.hairline)

            VStack(alignment: .leading, spacing: 5) {
                ComparisonLine(symbol: "person.fill", text: officeComparison)
                ComparisonLine(symbol: "trophy.fill", text: recordComparison)
            }
        }
        .talkieCard()
    }

    private var officeComparison: String {
        guard hasData else { return "An office typist holds ~40 wpm" }
        let mult = avg / SpeedBenchmark.officeWorker
        if mult >= 1 {
            return String(format: "%.1f× an office typist's pace", mult)
        }
        return "\(Int((mult * 100).rounded()))% of an office typist's pace"
    }

    private var recordComparison: String {
        guard hasData else { return "World record is 212 wpm (B. Blackburn)" }
        let pct = avg / SpeedBenchmark.worldRecord * 100
        return "\(Int(pct.rounded()))% of the world record (212 wpm)"
    }
}

private struct ComparisonLine: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.coral)
                .frame(width: 14)
            Text(text)
                .font(.talkieHeading(12, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}

/// A top-half speedometer arc: muted track with a coral value sweep.
private struct Gauge: View {
    let fraction: Double

    var body: some View {
        ZStack {
            arc(0, 1).stroke(Theme.surfaceSunken, style: stroke)
            arc(0, max(0.0001, fraction))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [Theme.coralDeep, Theme.coral, Theme.featherGold]),
                        center: .center,
                        startAngle: .degrees(180),
                        endAngle: .degrees(360)
                    ),
                    style: stroke
                )
        }
    }

    private var stroke: StrokeStyle { StrokeStyle(lineWidth: 16, lineCap: .round) }

    /// A path tracing the top semicircle from `from`…`to` (0…1 of the half).
    private func arc(_ from: Double, _ to: Double) -> Path {
        Path { p in
            let rect = CGRect(x: 8, y: 8, width: 284, height: 284)
            // Map 0…1 onto 180°→360° (the upper half, left to right).
            let start = Angle.degrees(180 + 180 * from)
            let end = Angle.degrees(180 + 180 * to)
            p.addArc(center: CGPoint(x: rect.midX, y: rect.maxY),
                     radius: rect.width / 2,
                     startAngle: start, endAngle: end, clockwise: false)
        }
    }
}

// MARK: - Fixes card

private struct FixesCard: View {
    @ObservedObject var stats: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Fixes by Talkie")
            Text(stats.totalFixes.formatted())
                .font(.talkieMetric(46))
                .foregroundStyle(Theme.ink)

            Divider().overlay(Theme.hairline).padding(.vertical, 2)

            FixRow(label: "words polished", value: stats.wordsCorrected, color: Theme.coral)
            FixRow(label: "dictionary fixes", value: stats.dictionaryFixes, color: Theme.featherBlue)
            FixRow(label: "fillers removed", value: stats.fillersRemoved, color: Theme.featherGold)
        }
        .talkieCard()
    }
}

private struct FixRow: View {
    let label: String
    let value: Int
    let color: Color
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(value.formatted())
                .font(.talkieHeading(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
            Text(label)
                .font(.talkieHeading(13, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
            Spacer()
        }
    }
}

// MARK: - Words card

private struct WordsCard: View {
    @ObservedObject var stats: StatsStore
    @ObservedObject var history: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Total words dictated")
            Text(stats.totalWords.formatted())
                .font(.talkieMetric(46))
                .foregroundStyle(Theme.ink)

            Divider().overlay(Theme.hairline).padding(.vertical, 2)

            MiniStat(icon: "calendar", label: "Last 7 days",
                     value: history.wordsLast7Days.formatted() + " words")
            MiniStat(icon: "mic.fill", label: "Dictations",
                     value: stats.totalDictations.formatted())
            MiniStat(icon: "clock.fill", label: "Time spoken",
                     value: formatDuration(stats.totalDurationSec))
        }
        .talkieCard()
    }
}

private struct MiniStat: View {
    let icon: String
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 16)
            Text(label)
                .font(.talkieHeading(13, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
            Spacer()
            Text(value)
                .font(.talkieHeading(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
        }
    }
}

// MARK: - Usage breakdown card

private struct UsageCard: View {
    @ObservedObject var appUsage: AppUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "Where your words go")
                Spacer()
                if appUsage.distinctApps > 0 {
                    Text("\(appUsage.distinctApps) app\(appUsage.distinctApps == 1 ? "" : "s")")
                        .font(.talkieEyebrow)
                        .foregroundStyle(Theme.inkTertiary)
                }
            }

            let slices = appUsage.topApps(limit: 6)
            if slices.isEmpty {
                EmptyHint(icon: "app.dashed",
                          text: "Dictate into your apps and they'll show up here.")
            } else {
                VStack(spacing: 11) {
                    ForEach(Array(slices.enumerated()), id: \.element.id) { idx, slice in
                        UsageRow(slice: slice, color: Theme.categorical[idx % Theme.categorical.count])
                    }
                }
            }
        }
        .talkieCard()
    }
}

private struct UsageRow: View {
    let slice: UsageSlice
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: slice.category.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(slice.name)
                    .font(.talkieHeading(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer()
                Text("\(Int((slice.fraction * 100).rounded()))%")
                    .font(.talkieHeading(12, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceSunken)
                    Capsule().fill(color)
                        .frame(width: max(6, geo.size.width * slice.fraction))
                }
            }
            .frame(height: 7)
        }
    }
}

// MARK: - Streak / heatmap card

private struct StreakCard: View {
    @ObservedObject var activity: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "\(activity.currentStreak)-day streak")
                Spacer()
                Text("Longest \(activity.longestStreak)")
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkTertiary)
            }

            Heatmap(data: activity.heatmap(weeks: 18))

            HStack(spacing: 6) {
                Text("Less").font(.system(size: 10)).foregroundStyle(Theme.inkTertiary)
                ForEach(0..<5) { lvl in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Theme.heat(lvl))
                        .frame(width: 11, height: 11)
                }
                Text("More").font(.system(size: 10)).foregroundStyle(Theme.inkTertiary)
                Spacer()
            }
        }
        .talkieCard()
    }
}

private struct Heatmap: View {
    let data: HeatmapData
    private let cell: CGFloat = 11
    private let gap: CGFloat = 3
    private let dayLabels = ["", "Mon", "", "Wed", "", "Fri", ""]

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Weekday labels (Sun-first; show Mon/Wed/Fri to avoid clutter).
            VStack(alignment: .trailing, spacing: gap) {
                Spacer().frame(height: 13) // align under the month row
                ForEach(0..<7, id: \.self) { row in
                    Text(dayLabels[row])
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(height: cell, alignment: .center)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                // Month labels.
                HStack(spacing: gap) {
                    ForEach(Array(data.monthLabels.enumerated()), id: \.offset) { _, label in
                        Text(label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary)
                            .frame(width: cell, alignment: .leading)
                            .fixedSize()
                            .frame(width: cell, alignment: .leading)
                    }
                }
                .frame(height: 10, alignment: .leading)

                // Week columns.
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(data.weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: gap) {
                            ForEach(week) { cellData in
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(cellData.isFuture ? Color.clear : Theme.heat(cellData.level))
                                    .frame(width: cell, height: cell)
                                    .help(cellData.date != nil && cellData.words > 0
                                          ? "\(cellData.words) words" : "")
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shared bits

private struct EmptyHint: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Theme.inkTertiary)
            Text(text)
                .font(.talkieHeading(13, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m \(s)s" }
    return "\(s)s"
}
