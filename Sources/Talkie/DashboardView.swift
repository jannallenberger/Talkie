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

    /// L7: true while the pointer is over the welcome header. Drives the reveal of the
    /// "Add a photo" affordance when no photo is set (a set photo shows regardless).
    @State private var headerHovered = false

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

                    // L-bento: the hero band — a slim WPM gauge leading, the wide
                    // words-per-day chart filling the rest. Reflows to a stack when the
                    // window is too narrow to seat both side by side.
                    heroBand

                    // Equal-height cards take two cooperating pieces: the outer
                    // `.frame(maxHeight: .infinity, alignment: .top)` top-aligns
                    // each LazyVGrid cell wrapper (so a short card sits at the top
                    // of its row rather than vertically centered), while the inner
                    // `talkieCard(fill: true)` stretches the *painted* surface to
                    // fill that wrapper's height — so every card's background paints
                    // to the same height as its tallest row neighbor.
                    LazyVGrid(columns: metricCols, alignment: .leading, spacing: Theme.Space.gridGap) {
                        // K9: each read-only stat card reads as ONE combined VoiceOver
                        // element (its eyebrow + values as a single phrase) instead of
                        // a stream of disconnected fragments. (The WPM gauge moved up
                        // into the hero band, so this grid starts at Speed.)
                        SpeedCard(latency: latency).frame(maxHeight: .infinity, alignment: .top)
                            .accessibilityElement(children: .combine)
                        FixesCard(stats: stats).frame(maxHeight: .infinity, alignment: .top)
                            .accessibilityElement(children: .combine)
                        WordsCard(stats: stats, history: history).frame(maxHeight: .infinity, alignment: .top)
                            .accessibilityElement(children: .combine)
                        RecordsCard(stats: stats, activity: activity).frame(maxHeight: .infinity, alignment: .top)
                            .accessibilityElement(children: .combine)
                        TaughtWordsCard(stats: stats).frame(maxHeight: .infinity, alignment: .top)
                            .accessibilityElement(children: .combine)
                    }

                    LazyVGrid(columns: wideCols, alignment: .leading, spacing: Theme.Space.gridGap) {
                        UsageCard(appUsage: appUsage).frame(maxHeight: .infinity, alignment: .top)
                            .accessibilityElement(children: .combine)
                        StreakCard(activity: activity).frame(maxHeight: .infinity, alignment: .top)
                            .accessibilityElement(children: .combine)
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
                    MilestonesView(stats: stats, activity: activity, wordFreq: wordFreq,
                                   appUsage: appUsage, jobTitle: jobTitle)
                }
            }
            .navigationDestination(for: SpeedRoute.self) { route in
                switch route {
                case .detail:
                    SpeedDetailView(latency: latency, pressure: pressure)
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
        HStack(alignment: .top, spacing: headerAvatarSpacing) {
            // L7: the profile picture leads the welcome title. When a photo is set it
            // always shows; when none is set the slot collapses to zero width at rest —
            // so the header is pixel-identical to pre-L7 — and only reveals a dashed
            // "Add a photo" affordance when the header is hovered. This control IS the
            // setting (photo menu on click + drag-drop); there is no Settings row.
            DashboardAvatar(profileImage: profileImage, headerHovered: headerHovered)
                .padding(.top, 4)
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
        // Hovering anywhere on the header reveals the "Add a photo" affordance when no
        // photo is set; a set photo ignores this (it's always shown).
        .onHover { headerHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: headerHovered)
    }

    /// The leading gap before the title: 14 pt once the avatar slot is occupying
    /// space (photo set, or the affordance is revealed), and 0 when the slot is
    /// collapsed — so an empty header sits exactly where it did before L7.
    private var headerAvatarSpacing: CGFloat {
        (profileImage.image != nil || headerHovered) ? 14 : 0
    }

    private var greeting: String {
        let total = stats.totalWords
        if total == 0 { return "Hold your dictation key and speak — your stats will fill in here." }
        return "\(total.formatted()) words dictated, all on-device."
    }

    // MARK: Hero band

    /// The bento hero: a slim WPM gauge leading and the wide words-per-day chart
    /// filling the rest. `ViewThatFits` seats them side by side when there's room
    /// (the common case) and stacks them when the window narrows, so neither the
    /// gauge nor the chart is ever crushed. `heroHeight` pins both to one height in
    /// the side-by-side layout so their surfaces paint level, like the grid rows.
    private var heroBand: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.gridGap) {
                GaugeCard(stats: stats)
                    .frame(width: 236)
                    .accessibilityElement(children: .combine)
                WordsPerDayCard(activity: activity)
                    .frame(minWidth: 320, maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
            }
            .frame(height: heroHeight)
            VStack(spacing: Theme.Space.gridGap) {
                GaugeCard(stats: stats)
                    .accessibilityElement(children: .combine)
                WordsPerDayCard(activity: activity)
                    .frame(height: heroHeight)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    /// The side-by-side hero height — tall enough to seat the gauge's arc plus its
    /// two comparison lines, and the chart's number plus its bars, without crushing
    /// either. Tuned to the gauge card's natural height so nothing compresses.
    private let heroHeight: CGFloat = 236
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
                    .font(.talkieDisplay(28))
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
                        .font(.talkieDisplay(28))
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

// MARK: - Dashboard profile avatar (opt-in, photo-only)

/// L7 — the profile-picture control in the dashboard header. This IS the entire
/// profile-photo setting (no Settings row, per the post-H1 IA + no-new-toggles rule):
///
///   • Photo set   → a 34-pt `AvatarView`, always visible; click opens a menu with
///                   "Choose photo…" and "Remove photo".
///   • No photo    → nothing at rest (the header looks identical to pre-L7); on hover
///                   a dashed "Add a photo" circle fades in. Click opens the picker.
///   • Either way  → dropping an image file onto the control sets the photo.
///
/// The picker is a plain `NSOpenPanel` restricted to `[.image]` — deliberately NOT a
/// PhotosPicker, so there is zero photo-library permission surface; the panel grants
/// exactly the one file the user chooses.
private struct DashboardAvatar: View {
    @ObservedObject var profileImage: ProfileImageStore
    /// Whether the pointer is over the header (owned by `DashboardView`). When no photo
    /// is set, the "Add a photo" affordance only appears while this is true; otherwise
    /// the slot collapses to zero width so the header matches its pre-L7 layout.
    let headerHovered: Bool
    @State private var dropTargeting = false

    private let size: CGFloat = 34

    /// Whether the affordance should be shown when no photo is set (hovering the header
    /// or a drag hovering the slot). A set photo ignores this — it's always shown.
    private var revealed: Bool { headerHovered || dropTargeting }

    var body: some View {
        control
            // Collapse to zero width when there's no photo and nothing to reveal, so the
            // title sits exactly where it did before L7; otherwise reserve the avatar.
            .frame(width: (profileImage.image != nil || revealed) ? size : 0, height: size)
            .contentShape(Circle())
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: Self.isImageFile) else { return false }
                return profileImage.setImage(fromFile: url)
            } isTargeted: { dropTargeting = $0 }
            .animation(.easeInOut(duration: 0.15), value: revealed)
            .animation(.easeInOut(duration: 0.15), value: dropTargeting)
    }

    @ViewBuilder
    private var control: some View {
        if profileImage.image != nil {
            // A set photo sits in the SAME circular slot the "+" affordance occupies —
            // a sunken fill + a solid ring — with the photo matted a few points inside
            // it, so a set photo reads as "in the slot" rather than a bare cut-out.
            // Click opens a menu to replace or remove it.
            Menu {
                Button("Choose photo…".loc, action: choosePhoto)
                Button("Remove photo".loc, role: .destructive) { profileImage.clear() }
            } label: {
                Circle()
                    .fill(Theme.surfaceSunken.opacity(0.6))
                    .overlay(AvatarView(store: profileImage, size: size - 6))
                    .overlay(
                        Circle().strokeBorder(
                            dropTargeting ? Theme.coral : Theme.hairline,
                            lineWidth: 1.5
                        )
                    )
                    .frame(width: size, height: size)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .help("Change your photo".loc)
            .accessibilityLabel(Text("Change your photo".loc))
        } else {
            // No photo: an "add a photo" affordance revealed while the header is hovered
            // (or while a drag is over the slot). Clicking opens the picker directly —
            // there's nothing to remove yet, so no menu.
            Button(action: choosePhoto) {
                Circle()
                    .strokeBorder(
                        revealed ? Theme.coral : Theme.hairline,
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                    .background(Circle().fill(Theme.surfaceSunken.opacity(0.6)))
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(revealed ? Theme.coral : Theme.inkTertiary)
                    )
                    .opacity(revealed ? 1 : 0)
            }
            .buttonStyle(.plain)
            .help("Add a photo".loc)
            .accessibilityLabel(Text("Add a photo".loc))
            // Keep the affordance reachable/clipped to the reserved circle even as the
            // enclosing frame animates between 0 and full width.
            .frame(width: size, height: size)
            .clipped()
        }
    }

    /// Open a file picker restricted to images, and import the chosen file. Runs on
    /// the main actor; `NSOpenPanel` is modal so the result is available synchronously.
    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose".loc
        panel.message = "Choose a photo".loc
        if panel.runModal() == .OK, let url = panel.url {
            profileImage.setImage(fromFile: url)
        }
    }

    /// Whether a dropped URL is an image file we can take (extension → UTType).
    private static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
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
            .accessibilityLabel("Dismiss")
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

// MARK: - Words-per-day chart card (bento hero, right)

/// L-bento — the playful hero chart: one rounded bar per day for the last two
/// weeks, its height set by that day's word count and tinted along the feather
/// ramp (gold at the foot → macaw red at the crest). Honest by construction — it
/// reads the same on-device `ActivityStore.days` tally as the streak heatmap, so a
/// day with no dictation is a real gap (a faint stub), never a fabricated point.
/// Bars grow from the baseline on first appear unless Reduce Motion is on.
private struct WordsPerDayCard: View {
    @ObservedObject var activity: ActivityStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Two weeks reads as a clean rhythm at hero width without crowding the bars.
    private let dayCount = 14

    /// Drives the grow-from-baseline entrance; flipped once on appear.
    @State private var grown = false

    private var series: [(date: Date, words: Int)] { activity.dailyWords(days: dayCount) }
    private var maxWords: Int { max(1, series.map(\.words).max() ?? 0) }
    private var total: Int { series.reduce(0) { $0 + $1.words } }
    private var hasData: Bool { total > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "Words per day")
                Spacer()
                Text("\(dayCount) days")
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkTertiary)
            }

            if hasData {
                Text(total.formatted())
                    .font(.talkieMetric(34))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                chart
            } else {
                EmptyHint(icon: "chart.bar.xaxis",
                          text: "Dictate and your daily words chart here.")
            }
        }
        .talkieCard(fill: true)
        .onAppear {
            guard !reduceMotion else { grown = true; return }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.78)) { grown = true }
        }
    }

    /// The bar row, sized to fill whatever height the card gives it below the
    /// number. Each bar is a squircle capsule; zero-word days collapse to a faint
    /// baseline stub so the two-week axis stays continuous.
    private var chart: some View {
        GeometryReader { geo in
            let n = max(series.count, 1)
            let gap: CGFloat = 5
            let barW = max(3, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(series.enumerated()), id: \.offset) { _, day in
                    let frac = CGFloat(Double(day.words) / Double(maxWords))
                    Capsule(style: .continuous)
                        .fill(day.words == 0
                              ? AnyShapeStyle(Theme.surfaceSunken)
                              : AnyShapeStyle(LinearGradient(
                                    colors: [Theme.featherGold, Theme.featherCoral],
                                    startPoint: .top, endPoint: .bottom)))
                        .frame(width: barW,
                               height: barHeight(frac: frac, full: geo.size.height, empty: day.words == 0))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .help(dayHelp(day))
                }
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

    /// A bar's drawn height: a faint 3-pt stub for an empty day; otherwise the
    /// day's share of the busiest day scaled to the chart height — or `0` before
    /// the entrance animation runs, so the bars spring up from the baseline.
    private func barHeight(frac: CGFloat, full: CGFloat, empty: Bool) -> CGFloat {
        if empty { return 3 }
        guard grown else { return 0 }
        return max(4, full * frac)
    }

    /// Tooltip: "N words · Mon 3" for an active day, empty for a quiet one.
    private func dayHelp(_ day: (date: Date, words: Int)) -> String {
        guard day.words > 0 else { return "" }
        let when = day.date.formatted(.dateTime.weekday(.abbreviated).day())
        return "\(day.words) words · \(when)"
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

// MARK: - Personal records card

/// K3 — "your only competitor is yourself." The three honest personal records:
/// fastest WPM, longest single dictation, and biggest word day. Each reuses the
/// same honesty guard as the WPM gauge — a zero value shows an em dash, not a
/// bogus "0", so day-one use reads as "no record yet" rather than a hollow score.
private struct RecordsCard: View {
    @ObservedObject var stats: StatsStore
    @ObservedObject var activity: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Personal records")

            MiniStat(icon: "speedometer", label: "Fastest speed",
                     value: stats.bestWPM > 0 ? "\(Int(stats.bestWPM.rounded())) WPM" : "—")
            MiniStat(icon: "text.alignleft", label: "Longest dictation",
                     value: longestDictationValue)
            MiniStat(icon: "calendar", label: "Biggest word day",
                     value: activity.biggestWordDay > 0
                         ? activity.biggestWordDay.formatted() + " words"
                         : "—")
        }
        .talkieCard(fill: true)
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

// MARK: - Words you taught me card

/// K5 — the jargon terms Talkie has learned to get right for you, most-rescued
/// first. Terms are user content, so they render verbatim (never localized) and
/// are only ever read from the on-device `stats.json` tally.
private struct TaughtWordsCard: View {
    @ObservedObject var stats: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Words you taught me")

            let top = stats.topTaughtWords(limit: 5)
            if top.isEmpty {
                Text("The terms you teach it to spell right show up here.")
                    .font(.talkieHeading(13, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(top, id: \.term) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: "character.book.closed")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                            .frame(width: 16)
                        Text(verbatim: entry.term)
                            .font(.talkieHeading(13, weight: .regular))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(verbatim: "\(entry.count)×")
                            .font(.talkieHeading(13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .monospacedDigit()
                    }
                }
            }
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
