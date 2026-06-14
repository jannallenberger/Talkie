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

private enum BriefRoute: Hashable { case detail }

// MARK: - Dashboard

struct DashboardView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var stats: StatsStore
    @ObservedObject var history: HistoryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var appUsage: AppUsageStore
    @ObservedObject var contextSummary: ContextSummaryStore
    @ObservedObject var router: SettingsRouter

    // Adaptive columns reflow with the window width — no fixed widths to overflow.
    // 220 lets the three metric cards sit 3-up at the default width and fall to
    // 2-up / 1-up as the window narrows; the wide row goes 2-up → 1-up.
    private let metricCols = [GridItem(.adaptive(minimum: 220), spacing: Theme.Space.gridGap)]
    private let wideCols   = [GridItem(.adaptive(minimum: 330), spacing: Theme.Space.gridGap)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    header

                    BriefBanner(summary: contextSummary)

                    // `.frame(maxHeight: .infinity, alignment: .top)` makes the
                    // cards in each grid row equal-height and top-aligned —
                    // otherwise LazyVGrid vertically centers the shorter card,
                    // leaving an off-looking gap next to a taller neighbor.
                    LazyVGrid(columns: metricCols, alignment: .leading, spacing: Theme.Space.gridGap) {
                        GaugeCard(stats: stats).frame(maxHeight: .infinity, alignment: .top)
                        FixesCard(stats: stats).frame(maxHeight: .infinity, alignment: .top)
                        WordsCard(stats: stats, history: history).frame(maxHeight: .infinity, alignment: .top)
                    }

                    LazyVGrid(columns: wideCols, alignment: .leading, spacing: Theme.Space.gridGap) {
                        UsageCard(appUsage: appUsage).frame(maxHeight: .infinity, alignment: .top)
                        StreakCard(activity: activity).frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.canvas)
            .navigationDestination(for: BriefRoute.self) { _ in
                BriefDetailView(summary: contextSummary, history: history)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.talkieDisplay(28))
                    .foregroundStyle(Theme.ink)
                Text(greeting)
                    .font(.talkieHeading(13, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            Wordmark()
        }
    }

    private var title: String {
        let name = settings.userName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Dashboard" : "Welcome back, \(name)"
    }

    private var greeting: String {
        let total = stats.totalWords
        if total == 0 { return "Hold your dictation key and speak — your stats will fill in here." }
        return "\(total.formatted()) words dictated, all on-device."
    }
}

/// The parrot mark + serif wordmark, shown top-right of the dashboard.
private struct Wordmark: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 26, height: 26)
            Text("Talkie")
                .font(.talkieDisplay(20))
                .foregroundStyle(Theme.ink)
        }
    }
}

// MARK: - Today's Brief — stylized banner → detail subpage

private struct BriefBanner: View {
    @ObservedObject var summary: ContextSummaryStore

    var body: some View {
        NavigationLink(value: BriefRoute.detail) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                        Text("TODAY'S BRIEF").font(.talkieEyebrow).tracking(0.8)
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    Text(headline)
                        .font(.talkieDisplay(22))
                        .foregroundStyle(.white)
                    Text(subline)
                        .font(.talkieHeading(13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bannerBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.plain)
    }

    private var bannerBackground: some View {
        ZStack(alignment: .trailing) {
            LinearGradient(
                colors: [Color(nsColor: NSColor(hex: 0x16181D)), Color(nsColor: NSColor(hex: 0x0B0C0F))],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // Faint parrot motif on the right.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().scaledToFit()
                .frame(width: 150)
                .opacity(0.10)
                .offset(x: 34)
                .blur(radius: 0.5)
        }
    }

    private var headline: String {
        if !summary.isAvailable { return "Make sense of your day" }
        return summary.summary.isEmpty ? "Catch up on your day" : "Your day, briefed"
    }

    private var subline: String {
        if !summary.isAvailable { return "Turn on Apple Intelligence for an on-device brief." }
        if summary.summary.isEmpty { return "Generate a private brief of everything you dictated." }
        if let at = summary.generatedAt {
            let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
            return "Updated \(f.localizedString(for: at, relativeTo: Date())) · tap to read"
        }
        return "Tap to read your brief"
    }
}

/// Full-page brief (pushed from the banner).
private struct BriefDetailView: View {
    @ObservedObject var summary: ContextSummaryStore
    @ObservedObject var history: HistoryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Today's Brief")
                            .font(.talkieDisplay(26))
                            .foregroundStyle(Theme.ink)
                        Text(subtitle)
                            .font(.talkieHeading(13, weight: .regular))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer()
                    Button {
                        Task { await summary.refresh(from: history) }
                    } label: {
                        if summary.isGenerating {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(summary.isGenerating || !summary.isAvailable)
                }

                content
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .navigationTitle("")
    }

    private var subtitle: String {
        guard let at = summary.generatedAt, !summary.summary.isEmpty else {
            return "An on-device summary of what you worked on."
        }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return "Generated \(f.localizedString(for: at, relativeTo: Date()))."
    }

    @ViewBuilder
    private var content: some View {
        if !summary.isAvailable {
            EmptyHint(icon: "sparkles",
                      text: "Turn on Apple Intelligence (System Settings → Apple Intelligence & Siri) to get an on-device brief of your day.")
        } else if summary.summary.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                EmptyHint(icon: "text.append",
                          text: history.entries.isEmpty
                          ? "Dictate through your day, then generate a brief of what you worked on."
                          : "Generate a brief from your recent dictations.")
                Button {
                    Task { await summary.refresh(from: history) }
                } label: { Label("Generate brief", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
                    .disabled(history.entries.isEmpty || summary.isGenerating)
            }
            .talkieCard()
        } else {
            MarkdownText(markdown: summary.summary, bulletColor: Theme.coral)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .talkieCard()
        }
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
            ZStack(alignment: .bottom) {
                Gauge(fraction: min(1, avg / SpeedBenchmark.worldRecord))
                    .frame(height: 104)
                VStack(spacing: 0) {
                    Text(hasData ? "\(Int(avg.rounded()))" : "—")
                        .font(.talkieMetric(42))
                        .foregroundStyle(Theme.ink)
                    Text(hasData ? "avg wpm" : "no data yet")
                        .font(.talkieHeading(11, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                }
                .padding(.bottom, 2)
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
        if mult >= 1 { return String(format: "%.1f× an office typist's pace", mult) }
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
                .foregroundStyle(Theme.featherCoral)
                .frame(width: 14)
            Text(text)
                .font(.talkieHeading(12, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// A top-half speedometer arc, sized to its frame (no fixed geometry → can't
/// overflow the card). Track in the sunken tone, value swept deep-red → gold.
private struct Gauge: View {
    let fraction: Double
    private let lineWidth: CGFloat = 15

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let r = max(8, min((w - lineWidth) / 2, h - lineWidth / 2))
            let center = CGPoint(x: w / 2, y: h - lineWidth / 2)
            ZStack {
                arc(center: center, radius: r, to: 1)
                    .stroke(Theme.surfaceSunken, style: stroke)
                arc(center: center, radius: r, to: max(0.001, fraction))
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [Theme.heat(4), Theme.featherCoral, Theme.featherGold]),
                            center: .center,
                            startAngle: .degrees(180), endAngle: .degrees(360)
                        ),
                        style: stroke
                    )
            }
        }
    }

    private var stroke: StrokeStyle { StrokeStyle(lineWidth: lineWidth, lineCap: .round) }

    private func arc(center: CGPoint, radius: CGFloat, to: Double) -> Path {
        Path { p in
            p.addArc(center: center, radius: radius,
                     startAngle: .degrees(180),
                     endAngle: .degrees(180 + 180 * to),
                     clockwise: false)
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
                .font(.talkieMetric(42))
                .foregroundStyle(Theme.ink)

            Divider().overlay(Theme.hairline).padding(.vertical, 2)

            FixRow(label: "words polished", value: stats.wordsCorrected, color: Theme.featherCoral)
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
                .lineLimit(1)
            Spacer(minLength: 0)
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
                .font(.talkieMetric(42))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

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
            Spacer(minLength: 4)
            Text(value)
                .font(.talkieHeading(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
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

// MARK: - Streak / heatmap card (responsive — fits week count to the width)

private struct StreakCard: View {
    @ObservedObject var activity: ActivityStore
    private let cell: CGFloat = 12
    private let gap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "\(activity.currentStreak)-day streak")
                Spacer()
                Text("Longest \(activity.longestStreak)")
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkTertiary)
            }

            GeometryReader { geo in
                let labelCol: CGFloat = 28
                let weeks = max(6, min(26, Int((geo.size.width - labelCol) / (cell + gap))))
                Heatmap(data: activity.heatmap(weeks: weeks), cell: cell, gap: gap)
            }
            .frame(height: 7 * cell + 6 * gap + 16)

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
    let cell: CGFloat
    let gap: CGFloat
    private let dayLabels = ["Mon", "", "Wed", "", "Fri", "", ""]

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Weekday labels (Mon-first; Mon/Wed/Fri only, to avoid clutter).
            VStack(alignment: .trailing, spacing: gap) {
                Spacer().frame(height: 13)
                ForEach(0..<7, id: \.self) { row in
                    Text(dayLabels[row])
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(height: cell, alignment: .center)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                // Month labels — each sits over a clear column slot and overflows
                // freely to the right, so "Feb" never wraps to "Fe / b".
                HStack(spacing: gap) {
                    ForEach(Array(data.monthLabels.enumerated()), id: \.offset) { _, label in
                        Color.clear
                            .frame(width: cell, height: 10)
                            .overlay(alignment: .leading) {
                                Text(label)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Theme.inkTertiary)
                                    .fixedSize()
                            }
                    }
                }

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

struct EmptyHint: View {
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
                .fixedSize(horizontal: false, vertical: true)
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
