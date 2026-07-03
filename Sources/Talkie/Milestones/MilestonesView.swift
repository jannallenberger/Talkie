import SwiftUI

/// "Plumage" — the milestones page. Turns your lifetime word count into a
/// feather-tier ladder (`MilestoneLadder` × `MilestoneCopy`), shows how far you
/// are to the next rung at your real pace, your personal bests, and the words
/// and phrases you actually say most.
///
/// A Dashboard SUBPAGE (reached via `navigationDestination`), not an eighth
/// sidebar tab. Everything here is drawn from stores already on-device; nothing
/// is invented. The equivalence lines are playful senses of scale, kept honest
/// with "≈" (dictated words include commands and repetition — see MilestoneCopy).
struct MilestonesView: View {
    @ObservedObject var stats: StatsStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var wordFreq: WordFrequencyStore

    private let cols = [GridItem(.adaptive(minimum: 300), spacing: Theme.Space.gridGap)]

    /// The rung the user is standing on right now (nil below the first rung).
    private var currentTier: Int? { MilestoneLadder.tier(for: stats.totalWords) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                header

                LazyVGrid(columns: cols, alignment: .leading, spacing: Theme.Space.gridGap) {
                    ProgressCard(stats: stats).frame(maxHeight: .infinity, alignment: .top)
                    BestsCard(stats: stats, activity: activity).frame(maxHeight: .infinity, alignment: .top)
                }

                ladder

                MostSaidCard(wordFreq: wordFreq)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LiveBackground(mood: .ambient))
        .scrollContentBackground(.hidden)
        .navigationTitle("Plumage")
    }

    // MARK: Header — current tier, total words, real time spoken

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plumage")
                .font(.talkieDisplay(28))
                .foregroundStyle(Theme.ink)
            Text(currentTierName)
                .font(.talkieHeading(15, weight: .medium))
                .foregroundStyle(Theme.featherCoral)
            Text(subtitle)
                .font(.talkieHeading(13, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    private var currentTierName: String {
        guard let tier = currentTier, let copy = MilestoneCopy.tier(tier) else {
            return "Just getting started".loc
        }
        return copy.name
    }

    private var subtitle: String {
        let words = stats.totalWords.formatted()
        let time = formatDuration(stats.totalDurationSec)
        return String(format: "%1$@ words spoken · %2$@ of talking".loc, words, time)
    }

    // MARK: The ladder — every rung, achieved in color, future dimmed

    private var ladder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "The ladder")
            VStack(spacing: 0) {
                ForEach(Array(MilestoneCopy.all.enumerated()), id: \.offset) { index, tier in
                    LadderRow(
                        threshold: MilestoneLadder.thresholds[index],
                        tier: tier,
                        achieved: (currentTier ?? -1) >= index,
                        isCurrent: currentTier == index
                    )
                    if index < MilestoneCopy.all.count - 1 {
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
        }
        .talkieCard()
    }
}

// MARK: - Progress-to-next card

/// The Capsule bar toward the next rung, with a sub-line estimating how long,
/// at your real pace, the remaining words would take to say. The sub-line is
/// OMITTED when we have no pace to estimate from (`averageWPM == 0`).
private struct ProgressCard: View {
    @ObservedObject var stats: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Next milestone")
            if let next = MilestoneLadder.next(after: stats.totalWords),
               let copy = MilestoneCopy.tier(nextTierIndex(for: next.threshold)) {
                Text(copy.name)
                    .font(.talkieHeading(17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(copy.equivalence)
                    .font(.talkieHeading(12, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                bar(progress: next.progress)

                HStack {
                    Text(String(format: "%1$@ / %2$@ words".loc,
                                stats.totalWords.formatted(), next.threshold.formatted()))
                        .font(.talkieHeading(12, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .monospacedDigit()
                    Spacer()
                }

                if let eta = etaLine(remaining: next.threshold - stats.totalWords) {
                    Text(eta)
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkTertiary)
                }
            } else {
                // At or past the top rung — nothing higher to climb toward.
                Text("Mythical")
                    .font(.talkieHeading(17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("You’ve reached the top of the ladder. Every word from here is legend.".loc)
                    .font(.talkieHeading(12, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .talkieCard(fill: true)
    }

    /// The tier index of a given next-threshold value (so we can name it).
    private func nextTierIndex(for threshold: Int) -> Int {
        MilestoneLadder.thresholds.firstIndex(of: threshold) ?? 0
    }

    private func bar(progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceSunken)
                Capsule().fill(Theme.featherCoral)
                    .frame(width: max(6, geo.size.width * progress))
            }
        }
        .frame(height: 8)
    }

    /// "≈ Nh of talking at your pace to go" — remaining words divided by the real
    /// average pace. Returns nil when there's no pace yet (`averageWPM == 0`).
    private func etaLine(remaining: Int) -> String? {
        let wpm = stats.averageWPM
        guard wpm > 0, remaining > 0 else { return nil }
        let minutes = Double(remaining) / wpm
        let duration = formatDuration(minutes * 60)
        return String(format: "≈ %@ of talking at your pace to go".loc, duration)
    }
}

// MARK: - Personal bests card

/// Personal bests. `bestWPM` is surfaced here for the FIRST time anywhere — with
/// the same honesty guard the gauge uses (0 means "not enough to say yet", shown
/// as a dash). Longest streak comes straight from the activity log.
private struct BestsCard: View {
    @ObservedObject var stats: StatsStore
    @ObservedObject var activity: ActivityStore

    private var hasBestWPM: Bool { stats.bestWPM > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Personal bests")

            BestRow(icon: "gauge.with.dots.needle.67percent",
                    label: "Fastest pace",
                    value: hasBestWPM ? String(format: "%d wpm".loc, Int(stats.bestWPM.rounded())) : "—",
                    color: Theme.featherCoral)

            Divider().overlay(Theme.hairline).padding(.vertical, 2)

            BestRow(icon: "flame.fill",
                    label: "Longest streak",
                    value: activity.longestStreak > 0
                        ? String(format: "%d days".loc, activity.longestStreak)
                        : "—",
                    color: Theme.featherGold)
        }
        .talkieCard(fill: true)
    }
}

private struct BestRow: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20)
            Text(LocalizedStringKey(label))
                .font(.talkieHeading(13, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.talkieHeading(17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
        }
    }
}

// MARK: - One ladder row

private struct LadderRow: View {
    let threshold: Int
    let tier: MilestoneCopy.Tier
    let achieved: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: achieved ? "checkmark.seal.fill" : "seal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(achieved ? Theme.featherCoral : Theme.inkTertiary)
                .frame(width: 22)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(tier.name)
                        .font(.talkieHeading(14.5, weight: .semibold))
                        .foregroundStyle(achieved ? Theme.ink : Theme.inkTertiary)
                    if isCurrent {
                        Text("You’re here".loc.uppercased())
                            .font(.talkieEyebrow)
                            .tracking(0.6)
                            .foregroundStyle(Theme.featherCoral)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.featherCoral.opacity(0.14)))
                    }
                    Spacer(minLength: 4)
                    Text(threshold.formatted())
                        .font(.talkieHeading(12, weight: .semibold))
                        .foregroundStyle(achieved ? Theme.inkSecondary : Theme.inkTertiary)
                        .monospacedDigit()
                }
                // Only spend the equivalence line on rungs the user has reached —
                // future rungs stay a teaser (name + number), so the payoff lands
                // when it's earned.
                if achieved {
                    Text(tier.equivalence)
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 11)
        .opacity(achieved ? 1 : 0.55)
    }
}

// MARK: - Words you say most

/// The top words and short phrases from the on-device frequency store. Empty
/// until you've dictated enough for a favourite to emerge.
private struct MostSaidCard: View {
    @ObservedObject var wordFreq: WordFrequencyStore

    private var topWords: [(key: String, value: Int)] {
        wordFreq.words
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(5)
            .map { ($0.key, $0.value) }
    }

    private var topPhrases: [(key: String, value: Int)] {
        wordFreq.phrases
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3)
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Words you say most")

            if topWords.isEmpty && topPhrases.isEmpty {
                EmptyHint(icon: "text.word.spacing",
                          text: "Keep dictating — the words and phrases you reach for most will show up here.")
            } else {
                if !topWords.isEmpty {
                    FlowChips(items: topWords, tint: Theme.featherCoral)
                }
                if !topPhrases.isEmpty {
                    Divider().overlay(Theme.hairline).padding(.vertical, 2)
                    Eyebrow(text: "Phrases you reach for")
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(topPhrases, id: \.key) { item in
                            HStack(spacing: 8) {
                                Text("“\(item.key)”")
                                    .font(.talkieHeading(13, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                                Text("×\(item.value)")
                                    .font(.talkieHeading(12, weight: .semibold))
                                    .foregroundStyle(Theme.inkSecondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .talkieCard(fill: true)
    }
}

/// A soft-wrapping run of "word ×N" chips, laid out with the shared `FlowLayout`
/// (DesignSystem) so chips keep their natural width and wrap cleanly at any card
/// width — the same flow used by the dictionary/commands chip rows.
private struct FlowChips: View {
    let items: [(key: String, value: Int)]
    let tint: Color

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.key) { item in
                HStack(spacing: 5) {
                    Text(item.key)
                        .font(.talkieHeading(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("×\(item.value)")
                        .font(.talkieHeading(11, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(tint.opacity(0.12)))
            }
        }
    }
}
