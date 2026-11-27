import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

/// L3b — the Dictation Speed detail ("why it might be slow") subpage route. Its
/// own enum + `navigationDestination`, mirroring `MilestoneRoute`, so the Speed
/// card pushes a detail page rather than opening a new tab.
enum SpeedRoute: Hashable {
    case detail
}

struct DashboardView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var stats: StatsStore
    @ObservedObject var history: HistoryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var appUsage: AppUsageStore
    @ObservedObject var scratchpad: ScratchpadStore
    /// L7: the optional profile picture, shown leading the welcome title (and only
    /// when a photo is set). The header's photo menu IS the setting — there is no
    /// Settings row.
    @ObservedObject var profileImage: ProfileImageStore
    /// L5-a: lifetime word/phrase frequency, threaded through to the Plumage
    /// subpage's "words you say most" card.
    @ObservedObject var wordFreq: WordFrequencyStore
    /// L5-b: the on-device invented job title, threaded through to the Plumage
    /// subpage's title card (owned by AppDelegate so its cache + generation state
    /// survive navigating away and back).
    @ObservedObject var jobTitle: JobTitleStore
    /// L3a/L3b: rolling per-dictation latency, powering the Dictation Speed card
    /// and its detail page.
    @ObservedObject var latency: LatencyStore
    /// L3b: session-scoped memory-pressure observer, read by the speed detail
    /// page's environment diagnostics.
    @ObservedObject var pressure: SystemPressure
    @ObservedObject var router: SettingsRouter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Update reminder: last dismissal (epoch seconds, 0 = never). Evaluated once per
    /// appearance; no timers, no network.
    @AppStorage("updateReminderDismissedAt") private var updateDismissedAt: Double = 0
    @State private var updateDecision: UpdateReminder.Decision = .hidden

    /// The highest milestone tier the user has already been congratulated for.
    /// Persisted so the crossing banner fires ONCE per tier, never on relaunch.
    /// A raw threshold value (0 = none celebrated yet); we compare tiers by index.
    @AppStorage("milestoneCelebratedThreshold") private var celebratedThreshold = 0

    var body: some View {
        NavigationStack {
            TalkieScrollPage(spacing: Theme.Space.gridGap, background: .ambient) {
                    header
                        .padding(.bottom, 6)

                    if case .show(let days) = updateDecision {
                        UpdateReminderLine(days: days) {
                            updateDismissedAt = Date().timeIntervalSince1970
                            updateDecision = .hidden
                        }
                    }

                    if let banner = pendingCelebration {
                        MilestoneCelebrationBanner(
                            tierIndex: banner,
                            reduceMotion: reduceMotion,
                            onDismiss: { celebratedThreshold = MilestoneLadder.thresholds[banner] }
                        )
                    }

                    // The bento: four rows on one grid, every card filling its cell,
                    // so nothing is orphaned on a row of its own. A window too narrow
                    // for the grid gets the same cards in a single column.
                    ViewThatFits(in: .horizontal) {
                        wideBento
                        narrowBento
                    }
            }
            .onAppear {
                updateDecision = UpdateReminder.decide(
                    buildDate: UpdateReminder.bundleBuildDate, now: Date(),
                    lastDismissed: updateDismissedAt > 0 ? Date(timeIntervalSince1970: updateDismissedAt) : nil)
            }
            .navigationDestination(for: MilestoneRoute.self) { route in
                switch route {
                case .plumage:
                    MilestonesView(stats: stats, activity: activity, wordFreq: wordFreq,
                                   appUsage: appUsage, jobTitle: jobTitle)
                        .talkiePushedPage()
                }
            }
            .navigationDestination(for: SpeedRoute.self) { route in
                switch route {
                case .detail:
                    SpeedDetailView(latency: latency, pressure: pressure)
                        .talkiePushedPage()
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
        HStack(alignment: .top, spacing: 14) {
            // The profile picture leads the welcome title: the photo, or the user's
            // initial until one is set. Click it to choose, change or remove the
            // photo (the same control lives in Settings ▸ Profile & appearance).
            DashboardAvatar(profileImage: profileImage, name: settings.userName)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                // H1: the dedicated Settings ▸ Profile "Name" field is gone. The
                // dashboard title IS the name editor now — click it to type your name
                // inline (or "Add your name" when it's empty), commit on Return/blur.
                // Same one setting (`settings.userName`), one fewer settings section.
                EditableNameTitle(name: $settings.userName)
                Text(greeting)
                    .font(.talkieHeading(13, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                // K6: the one optional text field WS-K adds — names the bird. H1
                // deleted the Settings ▸ Profile card this spec originally targeted,
                // so the field lives here beside `userName` (its post-H1 home),
                // following the same inline click-to-edit pattern. Empty by default,
                // so it changes nothing until the user opts in.
                EditableParrotName(name: $settings.parrotName)
            }
            Spacer()
            Wordmark()
        }
    }

    private var greeting: String {
        let total = stats.totalWords
        if total == 0 { return "Press your dictation key and speak. Your stats will show up here.".loc }
        return String(format: "%@ words dictated, all on-device.".loc, total.formatted())
    }

    // MARK: Bento

    private var gap: CGFloat { Theme.Space.gridGap }

    /// The grid at normal widths. Row heights are fixed, so the cards of a row are
    /// level and the page is short: speed and the daily chart, four figures, the
    /// scratchpad beside the streak, then apps beside milestones and records.
    private var wideBento: some View {
        VStack(spacing: gap) {
            BentoRow(spacing: gap) {
                GaugeCard(stats: stats).bentoWeight(4)
                    .accessibilityElement(children: .combine)
                WordsPerDayCard(activity: activity).bentoWeight(8)
                    .accessibilityElement(children: .combine)
            }
            .frame(height: 206)
            tiles
                .frame(height: 116)
            BentoRow(spacing: gap) {
                ScratchpadCard(scratchpad: scratchpad).bentoWeight(5)
                StreakCard(activity: activity).bentoWeight(7)
                    .accessibilityElement(children: .combine)
            }
            .frame(height: 214)
            BentoRow(spacing: gap) {
                UsageCard(appUsage: appUsage).bentoWeight(7)
                    .accessibilityElement(children: .combine)
                VStack(spacing: gap) {
                    MilestoneEntryCard(stats: stats)
                        .frame(height: 88)
                    RecordsCard(stats: stats, activity: activity)
                        .accessibilityElement(children: .combine)
                }
                .bentoWeight(5)
            }
            .frame(height: 214)
        }
        .frame(minWidth: BentoRow.minimumGridWidth, maxWidth: .infinity)
    }

    /// The four figures: total words, fixes, dictation speed, time spoken.
    private var tiles: some View {
        BentoRow(spacing: gap) {
            WordsTile(stats: stats, history: history)
                .accessibilityElement(children: .combine)
            FixesTile(stats: stats)
                .accessibilityElement(children: .combine)
            SpeedCard(latency: latency, compact: true)
                .accessibilityElement(children: .combine)
            TimeTile(stats: stats)
                .accessibilityElement(children: .combine)
        }
    }

    /// The same cards in one column, for a window too narrow for the grid.
    private var narrowBento: some View {
        VStack(spacing: gap) {
            GaugeCard(stats: stats).frame(height: 206)
                .accessibilityElement(children: .combine)
            WordsPerDayCard(activity: activity).frame(height: 206)
                .accessibilityElement(children: .combine)
            BentoRow(spacing: gap) {
                WordsTile(stats: stats, history: history).accessibilityElement(children: .combine)
                FixesTile(stats: stats).accessibilityElement(children: .combine)
            }
            .frame(height: 116)
            BentoRow(spacing: gap) {
                SpeedCard(latency: latency, compact: true).accessibilityElement(children: .combine)
                TimeTile(stats: stats).accessibilityElement(children: .combine)
            }
            .frame(height: 116)
            ScratchpadCard(scratchpad: scratchpad).frame(height: 214)
            StreakCard(activity: activity).frame(height: 214)
                .accessibilityElement(children: .combine)
            UsageCard(appUsage: appUsage).frame(height: 214)
                .accessibilityElement(children: .combine)
            MilestoneEntryCard(stats: stats).frame(height: 88)
            RecordsCard(stats: stats, activity: activity).frame(height: 112)
                .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Bento row layout

private struct BentoWeightKey: LayoutValueKey {
    static let defaultValue: Double = 1
}

extension View {
    /// This card's share of a `BentoRow`'s width (default 1).
    func bentoWeight(_ weight: Double) -> some View {
        layoutValue(key: BentoWeightKey.self, value: weight)
    }
}

/// One row of the dashboard grid: the children share the width by weight (a 4 and
/// an 8 are a third and two thirds) and every one is given the row's full height,
/// so the cards of a row are always level.
struct BentoRow: Layout {
    var spacing: CGFloat = Theme.Space.gridGap

    /// Below this the grid's narrowest cards cannot hold their content.
    static let minimumGridWidth: CGFloat = 540

    /// The cell widths for `total` points shared by `weights`. Pure, unit-tested.
    static func widths(total: CGFloat, weights: [Double], spacing: CGFloat) -> [CGFloat] {
        guard !weights.isEmpty else { return [] }
        let usable = max(0, total - spacing * CGFloat(weights.count - 1))
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return weights.map { _ in usable / CGFloat(weights.count) } }
        return weights.map { usable * CGFloat($0 / sum) }
    }

    private func widths(_ total: CGFloat, _ subviews: Subviews) -> [CGFloat] {
        Self.widths(total: total, weights: subviews.map { $0[BentoWeightKey.self] }, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.minimumGridWidth
        if let height = proposal.height { return CGSize(width: width, height: height) }
        let cells = widths(width, subviews)
        let height = zip(subviews, cells)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width, subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

/// The dashboard's serif title, doubling as the inline editor for `userName`
/// (H1 — replaces the deleted Settings ▸ Profile "Name" field, zero capability
/// lost). Reads as a plain title until clicked; a click swaps in a borderless
/// `TextField` bound to the same setting, which commits on Return or when focus
/// leaves it. Empty name → an "Add your name" affordance instead of a dead
/// "Dashboard" label, so the one place to set your name is discoverable.
private struct EditableNameTitle: View {
    @Binding var name: String
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// The non-editing label: "Welcome back, {name}" once set, else a prompt.
    private var displayText: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Add your name".loc
                               : String(format: "Welcome back, %@".loc, trimmed)
    }

    var body: some View {
        Group {
            if editing {
                TextField("Your name".loc, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.talkiePageTitle)
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in
                        // Commit on blur too, so clicking away saves rather than discards.
                        if !isFocused { commit() }
                    }
                    .frame(maxWidth: 360, alignment: .leading)
            } else {
                Button(action: beginEditing) {
                    Text(displayText)
                        .font(.talkiePageTitle)
                        .foregroundStyle(name.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? Theme.inkTertiary : Theme.ink)
                }
                .buttonStyle(.plain)
                .help("Click to edit your name".loc)
            }
        }
    }

    private func beginEditing() {
        draft = name
        editing = true
        focused = true
    }

    private func commit() {
        name = draft.trimmingCharacters(in: .whitespaces)
        editing = false
    }
}

/// K6 — the optional inline editor for the bird's name, sitting just under the
/// greeting. Mirrors `EditableNameTitle`'s click-to-edit interaction at a quieter
/// weight (this is garnish, not the headline): a small parrot-voiced affordance
/// ("Name the macaw" when unset) that swaps in a borderless `TextField` on click
/// and commits on Return or blur. The binding is `AppSettings.parrotName`, which
/// normalizes (trim + 24-char cap) on write, so nothing typed here can blow out
/// the pill layout the name later appears in.
private struct EditableParrotName: View {
    @Binding var name: String
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// The resting label: the named bird ("Kiwi") once set, else a gentle,
    /// K1-voice invitation to name it. No emoji prefix — the bare name reads
    /// cleaner beside the greeting, and the name is user content so it renders
    /// verbatim (never localized).
    private var displayText: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Name the macaw".loc : trimmed
    }

    var body: some View {
        Group {
            if editing {
                TextField("Name the macaw (optional)".loc, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.talkieHeading(13, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
                    .frame(maxWidth: 240, alignment: .leading)
            } else {
                Button(action: beginEditing) {
                    Text(displayText)
                        .font(.talkieHeading(13, weight: .regular))
                        .foregroundStyle(name.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? Theme.inkTertiary : Theme.inkSecondary)
                }
                .buttonStyle(.plain)
                .help("Click to name your parrot".loc)
            }
        }
    }

    private func beginEditing() {
        draft = name
        editing = true
        focused = true
    }

    private func commit() {
        // `AppSettings.parrotName` normalizes (trim + cap) on assignment; trim here
        // too so an all-whitespace draft settles to empty before it round-trips.
        name = draft.trimmingCharacters(in: .whitespaces)
        editing = false
    }
}

/// The parrot mark + serif wordmark, shown top-right of the dashboard.
private struct Wordmark: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: Brand.logo)
                .resizable()
                .frame(width: 26, height: 26)
            Text(verbatim: Brand.displayName)
                .font(.talkieDisplay(20))
                .foregroundStyle(Theme.ink)
        }
    }
}

// MARK: - Dashboard profile avatar

/// The profile-picture control in the dashboard header: the photo (or the user's
/// initial) in a 40-pt circle, always visible. Click it for a popover that chooses,
/// changes or removes the photo; an image file can also be dropped straight on it.
private struct DashboardAvatar: View {
    @ObservedObject var profileImage: ProfileImageStore
    let name: String

    @State private var showEditor = false
    @State private var dropTargeting = false
    @State private var hovering = false

    private let size: CGFloat = 40

    var body: some View {
        Button { showEditor.toggle() } label: {
            AvatarView(store: profileImage, size: size, showsPlaceholder: true, name: name)
                .overlay(alignment: .bottomTrailing) {
                    // The edit badge says "this is a control" without hiding the photo.
                    Image(systemName: profileImage.image == nil ? "plus" : "pencil")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Theme.keycap)
                            .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 0.5))
                        .offset(x: 2, y: 2)
                        .opacity(hovering || profileImage.image == nil ? 1 : 0)
                }
                .overlay(Circle().strokeBorder(Theme.brand, lineWidth: 2).opacity(dropTargeting ? 1 : 0))
                .scaleEffect(hovering ? 1.04 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: dropTargeting)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .help(profileImage.image == nil ? "Add a photo".loc : "Change your photo".loc)
        .accessibilityLabel(Text(profileImage.image == nil ? "Add a photo".loc : "Change your photo".loc))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: ProfileImageStore.isImageFile) else { return false }
            return profileImage.setImage(fromFile: url)
        } isTargeted: { dropTargeting = $0 }
        .popover(isPresented: $showEditor, arrowEdge: .bottom) {
            TalkiePopover(title: "Your photo", width: Theme.Width.popoverWide) {
                ProfilePhotoEditor(store: profileImage, name: name, avatarSize: 84)
            }
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.dataColor(series: 1))
                    Text(tierName)
                        .font(.talkieHeading(15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
                Spacer(minLength: 0)
                if let next = MilestoneLadder.next(after: stats.totalWords) {
                    Text(String(format: "%1$@ / %2$@ words".loc,
                                stats.totalWords.formatted(), next.threshold.formatted()))
                        .font(.talkieHeading(11.5, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.surfaceSunken)
                            Capsule()
                                .fill(LinearGradient(gradient: Theme.dataRamp, startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(6, geo.size.width * next.progress))
                        }
                    }
                    .frame(height: 6)
                } else {
                    Text("Top of the ladder — see your plumage".loc)
                        .font(.talkieHeading(12, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
            }
            .talkieCard(padding: 16, fill: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Milestones".loc))
        .accessibilityValue(Text(verbatim: tierName))
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
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "You crossed %@ words".loc, threshold.formatted()))
                    .font(.talkieHeading(15, weight: .semibold))
                    .foregroundStyle(.white)
                if !equivalence.isEmpty {
                    Text(equivalence)
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                NavigationLink(value: MilestoneRoute.plumage) {
                    Text("See your milestones".loc)
                        .font(.talkieHeading(12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(Theme.Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(LinearGradient(gradient: Theme.emberRamp, startPoint: .leading, endPoint: .trailing))
                .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
                .shadow(color: .black.opacity(0.07), radius: 20, x: 0, y: 10)
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
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Words per minute")
            ZStack(alignment: .bottom) {
                Gauge(fraction: min(1, avg / SpeedBenchmark.worldRecord))
                    .frame(height: 86)
                VStack(spacing: 0) {
                    Text(hasData ? "\(Int(avg.rounded()))" : "—".loc)
                        .font(.talkieMetric(36))
                        .foregroundStyle(Theme.ink)
                    Text(LocalizedStringKey(hasData ? "avg wpm".loc : "no data yet".loc))
                        .font(.talkieHeading(11, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                ComparisonLine(symbol: "person.fill", text: officeComparison)
                ComparisonLine(symbol: "trophy.fill", text: recordComparison)
            }
        }
        .talkieCard(padding: 16, fill: true)
    }

    private var officeComparison: String {
        guard hasData else { return "An office typist holds ~40 wpm".loc }
        let mult = avg / SpeedBenchmark.officeWorker
        if mult >= 1 { return String(format: "%.1f× an office typist's pace".loc, mult) }
        return String(format: "%lld%% of an office typist's pace".loc, Int((mult * 100).rounded()))
    }

    private var recordComparison: String {
        guard hasData else { return "World record is 212 wpm (B. Blackburn)".loc }
        let pct = avg / SpeedBenchmark.worldRecord * 100
        return String(format: "%lld%% of the world record (212 wpm)".loc, Int(pct.rounded()))
    }
}

private struct ComparisonLine: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.dataColor(series: 1))
                .frame(width: 14)
            Text(text.loc)
                .font(.talkieHeading(12, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

/// A top-half speedometer arc, sized to its frame (no fixed geometry → can't
/// overflow the card). Track in the sunken tone, value swept along the data ramp
/// (the backdrop's colours), ending in a small lit knob.
private struct Gauge: View {
    let fraction: Double
    private let lineWidth: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let r = max(8, min((w - lineWidth) / 2, h - lineWidth / 2))
            let center = CGPoint(x: w / 2, y: h - lineWidth / 2)
            let swept = max(0.001, min(1, fraction))
            ZStack {
                arc(center: center, radius: r, to: 1)
                    .stroke(Theme.surfaceSunken, style: stroke)
                arc(center: center, radius: r, to: swept)
                    .stroke(
                        AngularGradient(
                            gradient: Theme.dataRamp,
                            center: UnitPoint(x: center.x / max(1, w), y: center.y / max(1, h)),
                            startAngle: .degrees(180), endAngle: .degrees(360)
                        ),
                        style: stroke
                    )
                if fraction > 0 {
                    let angle = Double.pi * (1 + swept)
                    Circle()
                        .fill(.white)
                        .frame(width: lineWidth - 4, height: lineWidth - 4)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 0.5)
                        .position(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
                }
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

// MARK: - Words-per-day chart card

/// The daily chart: one rounded bar per day for the last two weeks, each in its
/// place along the data ramp (so the row runs through the backdrop's colours), the
/// weekday under it, today marked, and a dashed line at the average of the days
/// you dictated. Honest by construction — it reads the same on-device
/// `ActivityStore.days` tally as the streak heatmap, so a day with no dictation is
/// a real gap (a faint stub), never a fabricated point. Bars grow from the baseline
/// on first appear unless Reduce Motion is on.
private struct WordsPerDayCard: View {
    @ObservedObject var activity: ActivityStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Two weeks reads as a clean rhythm at hero width without crowding the bars.
    private let dayCount = 14

    /// Drives the grow-from-baseline entrance; flipped once on appear. Starts grown
    /// once the entrance has played in this launch: any running SwiftUI animation
    /// makes every frame re-diff the whole dashboard, so the rise is a first-visit
    /// flourish, not a toll on every tab switch.
    @State private var grown = WordsPerDayCard.entrancePlayed
    @MainActor private static var entrancePlayed = false

    var body: some View {
        // Derived once per render: `dailyWords` walks the activity log.
        let series = activity.dailyWords(days: dayCount)
        let total = series.reduce(0) { $0 + $1.words }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "Words per day")
                Spacer()
                Text("\(dayCount) days")
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkTertiary)
            }

            if total > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(total.formatted())
                        .font(.talkieMetric(30))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let average = DashboardChartMath.activeDayAverage(series.map(\.words)) {
                        Text(String(format: "%@ a day when you dictate".loc, average.formatted()))
                            .font(.talkieHeading(12, weight: .regular))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                chart(series, total: total)
            } else {
                EmptyHint(icon: "chart.bar.xaxis",
                          text: "Dictate and your daily words chart here.")
                Spacer(minLength: 0)
            }
        }
        .talkieCard(padding: 16, fill: true)
        .onAppear {
            guard !grown else { return }
            Self.entrancePlayed = true
            guard !reduceMotion else { grown = true; return }
            // A finite ease-out with a little overshoot (the old spring's look) instead
            // of the spring itself, whose settling tail kept SwiftUI re-rendering the
            // whole dashboard for ~2 s after every visit.
            withAnimation(.timingCurve(0.34, 1.35, 0.64, 1, duration: 0.6)) { grown = true }
        }
    }

    private static let labelHeight: CGFloat = 15

    private func chart(_ series: [(date: Date, words: Int)], total: Int) -> some View {
        let maxWords = max(1, series.map(\.words).max() ?? 0)
        let average = DashboardChartMath.activeDayAverage(series.map(\.words))
        let calendar = Calendar.current
        return GeometryReader { geo in
            let n = max(series.count, 1)
            let gap: CGFloat = n > 10 ? 6 : 8
            let barW = max(3, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            let plotH = max(8, geo.size.height - Self.labelHeight)
            VStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(Array(series.enumerated()), id: \.offset) { index, day in
                            let frac = CGFloat(Double(day.words) / Double(maxWords))
                            let color = Theme.dataColor(at: Double(index) / Double(max(1, n - 1)))
                            RoundedRectangle(cornerRadius: min(barW / 2, 6), style: .continuous)
                                .fill(day.words == 0
                                      ? AnyShapeStyle(Theme.surfaceSunken)
                                      : AnyShapeStyle(LinearGradient(
                                            colors: [color.mix(with: .white, by: 0.22), color],
                                            startPoint: .top, endPoint: .bottom)))
                                .frame(width: barW, height: day.words == 0 ? 3 : max(5, plotH * frac))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                                .help(dayHelp(day))
                        }
                    }
                    // Entrance: the bars rise from the baseline. A vertical scale is a
                    // render-only transform; animating each bar's HEIGHT re-ran layout
                    // for the whole window on every frame.
                    .scaleEffect(x: 1, y: grown ? 1 : 0.001, anchor: .bottom)

                    if let average, average < maxWords {
                        // The average of the days with dictation, as a quiet guide.
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: 0.5))
                            p.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
                        }
                        .stroke(Theme.ink.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(height: 1)
                        .offset(y: -plotH * CGFloat(Double(average) / Double(maxWords)))
                        .opacity(grown ? 1 : 0)
                    }
                }
                .frame(height: plotH)

                HStack(spacing: gap) {
                    ForEach(Array(series.enumerated()), id: \.offset) { _, day in
                        let today = calendar.isDateInToday(day.date)
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 9, weight: today ? .bold : .medium))
                            .foregroundStyle(today ? Theme.ink : Theme.inkTertiary)
                            .frame(width: barW)
                    }
                }
                .frame(height: Self.labelHeight, alignment: .bottom)
            }
        }
        .frame(maxHeight: .infinity)
        // VoiceOver: fold the 14 individual bars — whose per-day counts are exposed
        // only through mouse `.help` tooltips — into a single element with a spoken
        // summary, so VO users get the data without tabbing past 14 unlabeled shapes.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Words per day, last \(dayCount) days")
        .accessibilityValue(DashboardChartSummary.wordsPerDay(series: series, total: total))
    }

    /// Tooltip: "N words · Mon 3" for an active day, empty for a quiet one.
    private func dayHelp(_ day: (date: Date, words: Int)) -> String {
        guard day.words > 0 else { return "" }
        let when = day.date.formatted(.dateTime.weekday(.abbreviated).day())
        return "\(day.words) words · \(when)"
    }
}

/// Small sums behind the dashboard charts. Pure, unit-tested.
enum DashboardChartMath {
    /// The mean of the days that have any words (a quiet day is not a zero score),
    /// or nil when fewer than two days have words — one day is not an average.
    static func activeDayAverage(_ words: [Int]) -> Int? {
        let active = words.filter { $0 > 0 }
        guard active.count >= 2 else { return nil }
        return Int((Double(active.reduce(0, +)) / Double(active.count)).rounded())
    }

    /// Each part's share of the whole as a fraction (0 for an empty whole).
    static func shares(_ parts: [Int]) -> [Double] {
        let total = parts.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return parts.map { _ in 0 } }
        return parts.map { Double(max(0, $0)) / Double(total) }
    }
}

// MARK: - Figure tiles

/// One figure of the dashboard's tile row: a tinted glyph and label, the number in
/// the serif, and one line (or a small bar) of detail under it.
struct DashboardTile<Detail: View>: View {
    let title: String
    let value: String
    let symbol: String
    /// Which colour of the data palette the glyph wears.
    let series: Int
    /// A chevron in the corner: the tile opens a page.
    var opens = false
    @ViewBuilder var detail: Detail

    var body: some View {
        let tint = Theme.dataColor(series: series)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(tint.opacity(0.16)))
                    .accessibilityHidden(true)
                Text(title.loc.uppercased())
                    .font(.talkieEyebrow)
                    .tracking(0.6)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if opens {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
            Text(verbatim: value)
                .font(.talkieMetric(28))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Spacer(minLength: 0)
            detail
        }
        .talkieCard(padding: 14, fill: true)
    }
}

/// The quiet line under a tile's number.
struct DashboardTileNote: View {
    let text: String
    var body: some View {
        Text(verbatim: text)
            .font(.talkieHeading(11.5, weight: .regular))
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

private struct WordsTile: View {
    @ObservedObject var stats: StatsStore
    @ObservedObject var history: HistoryStore

    var body: some View {
        DashboardTile(title: "Total words", value: stats.totalWords.formatted(), symbol: "text.word.spacing", series: 0) {
            DashboardTileNote(text: String(format: "%@ in the last 7 days".loc, history.wordsLast7Days.formatted()))
        }
    }
}

private struct TimeTile: View {
    @ObservedObject var stats: StatsStore

    var body: some View {
        DashboardTile(title: "Time spoken", value: formatDuration(stats.totalDurationSec), symbol: "clock.fill", series: 3) {
            DashboardTileNote(text: String(format: "%@ dictations".loc, stats.totalDictations.formatted()))
        }
    }
}

/// Fixes: the total, and a bar split into what was polished, what the dictionary
/// corrected and what fillers were removed.
private struct FixesTile: View {
    @ObservedObject var stats: StatsStore

    private var parts: [(label: String, value: Int)] {
        [("words polished", stats.wordsCorrected), ("dictionary fixes", stats.dictionaryFixes),
         ("fillers removed", stats.fillersRemoved)]
    }

    private var breakdown: String {
        parts.map { "\($0.value.formatted()) \($0.label.loc)" }.joined(separator: " · ")
    }

    var body: some View {
        DashboardTile(title: "Fixes", value: stats.totalFixes.formatted(), symbol: "wand.and.stars", series: 1) {
            let shares = DashboardChartMath.shares(parts.map(\.value))
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(shares.enumerated()), id: \.offset) { index, share in
                        if share > 0 {
                            Rectangle()
                                .fill(Theme.dataColor(series: index))
                                .frame(width: max(3, (geo.size.width - 4) * share))
                        }
                    }
                    if stats.totalFixes == 0 { Rectangle().fill(Theme.surfaceSunken) }
                }
                .clipShape(Capsule(style: .continuous))
            }
            .frame(height: 6)
            .padding(.bottom, 3)
            .help(breakdown)
        }
        .accessibilityValue(Text(verbatim: breakdown))
    }
}

// MARK: - Personal records card

/// K3 — "your only competitor is yourself." The three honest personal records:
/// fastest WPM, longest single dictation, and biggest word day. Each reuses the
/// same honesty guard as the WPM gauge — a zero value shows an em dash, not a
/// bogus "0", so day-one use reads as "no record yet" rather than a hollow score.
private struct RecordsCard: View {
    @ObservedObject var stats: StatsStore
    @ObservedObject var activity: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Personal records")
            Spacer(minLength: 6)
            VStack(spacing: 5) {
                MiniStat(icon: "speedometer", label: "Fastest speed",
                         value: stats.bestWPM > 0 ? "\(Int(stats.bestWPM.rounded())) WPM" : "—")
                MiniStat(icon: "text.alignleft", label: "Longest dictation",
                         value: longestDictationValue)
                MiniStat(icon: "calendar", label: "Biggest word day",
                         value: activity.biggestWordDay > 0
                             ? activity.biggestWordDay.formatted() + " words"
                             : "—".loc)
            }
        }
        .talkieCard(padding: 16, fill: true)
    }

    /// "N words (M:SS)" once there's a real longest dictation, else an em dash.
    /// The duration is only meaningful alongside the word count, so both share the
    /// same zero-guard.
    private var longestDictationValue: String {
        guard stats.longestDictationWords > 0 else { return "—" }
        let words = stats.longestDictationWords.formatted()
        let dur = formatDuration(stats.longestDictationDurationSec)
        return "\(words) words (\(dur))"
    }
}

private struct MiniStat: View {
    let icon: String
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 16)
            Text(LocalizedStringKey(label))
                .font(.talkieHeading(12.5, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.talkieHeading(12.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Usage breakdown card

/// Where the words go: one bar split by app (each app a colour of the data
/// palette), then the apps as a legend with their share.
private struct UsageCard: View {
    @ObservedObject var appUsage: AppUsageStore

    var body: some View {
        let slices = appUsage.topApps(limit: 5)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "Where your words go")
                Spacer()
                if appUsage.distinctApps > 0 {
                    Text(appUsage.distinctApps == 1 ? LocalizedStringKey("1 app") : LocalizedStringKey("\(appUsage.distinctApps) apps"))
                        .font(.talkieEyebrow)
                        .foregroundStyle(Theme.inkTertiary)
                }
            }

            if slices.isEmpty {
                EmptyHint(icon: "app.dashed",
                          text: "Dictate into your apps and they'll show up here.")
                Spacer(minLength: 0)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                            Rectangle()
                                .fill(Theme.dataColor(series: index))
                                .frame(width: max(3, (geo.size.width - 2 * CGFloat(slices.count)) * slice.fraction))
                                .help("\(slice.name) · \(Int((slice.fraction * 100).rounded()))%")
                        }
                        // Everything outside the top apps.
                        Rectangle().fill(Theme.surfaceSunken)
                    }
                    .clipShape(Capsule(style: .continuous))
                }
                .frame(height: 10)

                VStack(spacing: 6) {
                    ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                        UsageRow(slice: slice, color: Theme.dataColor(series: index))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .talkieCard(padding: 16, fill: true)
    }
}

private struct UsageRow: View {
    let slice: UsageSlice
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Group {
                // `slice.id` is the app's bundle id when one was captured (the common
                // case); older records fall back to the app name, which won't
                // resolve — the category symbol below covers that gracefully.
                if let icon = AppIconLookup.icon(forBundleID: slice.id) {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: slice.category.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            .frame(width: 16, height: 16)
            Text(slice.name)
                .font(.talkieHeading(12.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("\(Int((slice.fraction * 100).rounded()))%")
                .font(.talkieHeading(12, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Streak / heatmap card (responsive — fits week count to the width)

private struct StreakCard: View {
    @ObservedObject var activity: ActivityStore
    private let cell: CGFloat = 12
    private let gap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.brand)
                    .accessibilityHidden(true)
                Eyebrow(text: String(format: "%lld-day streak".loc, activity.currentStreak))
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

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text("Less").font(.system(size: 10)).foregroundStyle(Theme.inkTertiary)
                ForEach(0..<5) { lvl in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Theme.emberHeat(lvl))
                        .frame(width: 11, height: 11)
                }
                Text("More").font(.system(size: 10)).foregroundStyle(Theme.inkTertiary)
                Spacer()
            }
        }
        .talkieCard(padding: 16, fill: true)
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
                                    .fill(cellData.isFuture ? Color.clear : Theme.emberHeat(cellData.level))
                                    .frame(width: cell, height: cell)
                                    .help(cellData.date != nil && cellData.words > 0
                                          ? String(format: "%lld words".loc, cellData.words) : "")
                            }
                        }
                    }
                }
            }
        }
        // VoiceOver: the grid can hold up to ~182 cells (26 weeks × 7 days) plus the
        // weekday/month axis labels. Exposing each as its own element would be an
        // impassable wall of stops, and today only the mouse `.help` tooltips carry
        // the per-day counts. Collapse the whole grid into one element with a spoken
        // summary instead; the streak counts already live in `StreakCard`'s header.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity heatmap")
        .accessibilityValue(DashboardChartSummary.heatmap(data))
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
            Text(text.loc)
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
