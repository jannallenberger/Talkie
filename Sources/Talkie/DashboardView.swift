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

/// A Dashboard navigation route. Currently just the milestones ("Plumage")
/// subpage — a `navigationDestination` value so Plumage is a pushed subpage of
/// the Dashboard, not an eighth sidebar tab.
enum MilestoneRoute: Hashable {
    case plumage
}

struct DashboardView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var stats: StatsStore
    @ObservedObject var history: HistoryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var appUsage: AppUsageStore
    @ObservedObject var scratchpad: ScratchpadStore
    /// L5-a: lifetime word/phrase frequency, threaded through to the Plumage
    /// subpage's "words you say most" card.
    @ObservedObject var wordFreq: WordFrequencyStore
    @ObservedObject var router: SettingsRouter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The highest milestone tier the user has already been congratulated for.
    /// Persisted so the crossing banner fires ONCE per tier, never on relaunch.
    /// A raw threshold value (0 = none celebrated yet); we compare tiers by index.
    @AppStorage("milestoneCelebratedThreshold") private var celebratedThreshold = 0

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

                    if let banner = pendingCelebration {
                        MilestoneCelebrationBanner(
                            tierIndex: banner,
                            reduceMotion: reduceMotion,
                            onDismiss: { celebratedThreshold = MilestoneLadder.thresholds[banner] }
                        )
                    }

                    ScratchpadCard(scratchpad: scratchpad)

                    // Equal-height cards take two cooperating pieces: the outer
                    // `.frame(maxHeight: .infinity, alignment: .top)` top-aligns
                    // each LazyVGrid cell wrapper (so a short card sits at the top
                    // of its row rather than vertically centered), while the inner
                    // `talkieCard(fill: true)` stretches the *painted* surface to
                    // fill that wrapper's height — so every card's background paints
                    // to the same height as its tallest row neighbor.
                    LazyVGrid(columns: metricCols, alignment: .leading, spacing: Theme.Space.gridGap) {
                        GaugeCard(stats: stats).frame(maxHeight: .infinity, alignment: .top)
                        FixesCard(stats: stats).frame(maxHeight: .infinity, alignment: .top)
                        WordsCard(stats: stats, history: history).frame(maxHeight: .infinity, alignment: .top)
                    }

                    LazyVGrid(columns: wideCols, alignment: .leading, spacing: Theme.Space.gridGap) {
                        UsageCard(appUsage: appUsage).frame(maxHeight: .infinity, alignment: .top)
                        StreakCard(activity: activity).frame(maxHeight: .infinity, alignment: .top)
                        MilestoneEntryCard(stats: stats).frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(LiveBackground(mood: .ambient))
            .scrollContentBackground(.hidden)
            .navigationDestination(for: MilestoneRoute.self) { route in
                switch route {
                case .plumage:
                    MilestonesView(stats: stats, activity: activity, wordFreq: wordFreq)
                }
            }
        }
    }

    /// The tier to celebrate right now, or nil. We celebrate whenever the tier the
    /// user's CURRENT total sits on is higher than the highest tier we've already
    /// congratulated them for. Comparing by tier index means a total that leapt
    /// several rungs shows one banner for the highest — and once dismissed (which
    /// writes that rung's threshold), it won't fire again. Below the first rung, or
    /// once caught up, this is nil.
    private var pendingCelebration: Int? {
        guard let reached = MilestoneLadder.tier(for: stats.totalWords) else { return nil }
        let celebratedTier = MilestoneLadder.tier(for: celebratedThreshold) // nil if 0
        if let celebratedTier, celebratedTier >= reached { return nil }
        return reached
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
            Image(nsImage: Brand.logo)
                .resizable()
                .frame(width: 26, height: 26)
            Text("Talkie")
                .font(.talkieDisplay(20))
                .foregroundStyle(Theme.ink)
        }
    }
}

// MARK: - Milestone entry card (→ Plumage subpage)

/// The dashboard's doorway to the Plumage milestones page: current tier name, a
/// mini progress bar toward the next rung, and a chevron. A `NavigationLink`
/// carrying `MilestoneRoute.plumage`, resolved by the Dashboard's
/// `navigationDestination`.
private struct MilestoneEntryCard: View {
    @ObservedObject var stats: StatsStore

    private var tierName: String {
        guard let tier = MilestoneLadder.tier(for: stats.totalWords),
              let copy = MilestoneCopy.tier(tier) else {
            return "First Feathers".loc // the rung they're working toward
        }
        return copy.name
    }

    var body: some View {
        NavigationLink(value: MilestoneRoute.plumage) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Eyebrow(text: "Milestones")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.featherCoral)
                    Text(tierName)
                        .font(.talkieHeading(17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                if let next = MilestoneLadder.next(after: stats.totalWords) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.surfaceSunken)
                            Capsule().fill(Theme.featherCoral)
                                .frame(width: max(6, geo.size.width * next.progress))
                        }
                    }
                    .frame(height: 7)
                    Text(String(format: "%1$@ / %2$@ words".loc,
                                stats.totalWords.formatted(), next.threshold.formatted()))
                        .font(.talkieHeading(12, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .monospacedDigit()
                } else {
                    Text("Top of the ladder — see your plumage".loc)
                        .font(.talkieHeading(12, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .talkieCard(fill: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Crossing celebration banner

/// A dismissible banner shown when the user's total has just cleared a new
/// milestone rung. Names the rung's word count and its equivalence, links into
/// Plumage, and its × writes the rung so it shows once per tier. Any entrance
/// animation is gated on `reduceMotion`.
private struct MilestoneCelebrationBanner: View {
    let tierIndex: Int
    let reduceMotion: Bool
    let onDismiss: () -> Void

    @State private var appeared = false

    private var threshold: Int { MilestoneLadder.thresholds[tierIndex] }
    private var equivalence: String { MilestoneCopy.tier(tierIndex)?.equivalence ?? "" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.featherGold)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "You crossed %@ words".loc, threshold.formatted()))
                    .font(.talkieHeading(15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if !equivalence.isEmpty {
                    Text(equivalence)
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NavigationLink(value: MilestoneRoute.plumage) {
                    Text("See your milestones".loc)
                        .font(.talkieHeading(12, weight: .semibold))
                        .foregroundStyle(Theme.featherCoral)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .talkieCard()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.featherGold.opacity(0.4), lineWidth: 1)
        )
        .opacity(appeared || reduceMotion ? 1 : 0)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.35)) { appeared = true }
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
                    Text(LocalizedStringKey(hasData ? "avg wpm" : "no data yet"))
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
        .talkieCard(fill: true)
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
        .talkieCard(fill: true)
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
            Text(LocalizedStringKey(label))
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
        .talkieCard(fill: true)
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
            Text(LocalizedStringKey(label))
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
        .talkieCard(fill: true)
    }
}

private struct UsageRow: View {
    let slice: UsageSlice
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Group {
                    // `slice.id` is the app's bundle id when one was captured
                    // (the common case); older records fall back to the app
                    // name, which won't resolve — the category symbol below
                    // covers that gracefully.
                    if let icon = AppIconLookup.icon(forBundleID: slice.id) {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: slice.category.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(color)
                    }
                }
                .frame(width: 16, height: 16)
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
        .talkieCard(fill: true)
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
