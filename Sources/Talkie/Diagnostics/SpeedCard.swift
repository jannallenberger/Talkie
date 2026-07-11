import SwiftUI

/// L3b — how Talkie grades the median end-to-end dictation latency. A presentation
/// layer over a measured median: the number is real (milliseconds from L3a), the
/// label is just a friendly bucket. Thresholds in seconds:
///   Instant < 0.8s · Fast < 1.5s · OK < 3s · Slow ≥ 3s
///
/// IMPORTANT (honest-claims): a grade is a label on YOUR measured latency, shown
/// only in the app's own dashboard/detail views. It must never be stamped onto a
/// shareable or exported artifact — there are none in L3b, and none should be added.
enum SpeedGrade: Int, CaseIterable {
    case instant, fast, ok, slow

    /// Bucket a median latency (milliseconds) into a grade. Boundaries are
    /// exclusive on the low side: exactly 800 ms is `.fast`, exactly 3000 ms is
    /// `.slow` — so each threshold belongs to the SLOWER bucket it opens.
    static func grade(medianMs: Double) -> SpeedGrade {
        switch medianMs {
        case ..<800:  return .instant
        case ..<1500: return .fast
        case ..<3000: return .ok
        default:      return .slow
        }
    }

    var label: String {
        switch self {
        case .instant: return "Instant".loc
        case .fast:    return "Fast".loc
        case .ok:      return "OK".loc
        case .slow:    return "Slow".loc
        }
    }

    /// The feather hue for this grade — coral (Talkie's accent) for the fast end,
    /// gold as a gentle "heads up" at the slow end. Never alarm-red: slow dictation
    /// is a nudge to open the diagnostics, not an error.
    var tint: Color {
        switch self {
        case .instant, .fast: return Theme.featherCoral
        case .ok:             return Theme.featherGold
        case .slow:           return Theme.featherGold
        }
    }
}

/// The dashboard's Dictation Speed card: the median end-to-end latency of your
/// last (up to 50) dictations — EXCLUDING the cold-start sample and any optimistic
/// insertion, both of which misrepresent steady-state speed — shown as a big
/// seconds figure with a friendly grade, and a doorway into the "why it might be
/// slow" detail page. `EmptyHint` until there's steady-state data to median.
///
/// A `NavigationLink(value: SpeedRoute.detail)`, resolved by the Dashboard's
/// second `navigationDestination` (mirrors the Milestones entry card exactly).
struct SpeedCard: View {
    @ObservedObject var latency: LatencyStore

    /// The steady-state median (cold-start + optimistic dropped), or nil when there
    /// isn't a representative sample yet.
    private var medianMs: Double? {
        latency.medianTotalMs(excludingColdStart: true, excludingOptimistic: true)
    }

    private var sampleCount: Int { latency.steadyStateSampleCount }

    var body: some View {
        NavigationLink(value: SpeedRoute.detail) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Eyebrow(text: "Dictation speed")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }

                if let medianMs {
                    let grade = SpeedGrade.grade(medianMs: medianMs)
                    // Number + unit rendered together via the localized "%.1f s" key
                    // (e.g. "1.2 s" / "1.2 秒") so the seconds suffix localizes with the
                    // value rather than as a bare, collision-prone "s".
                    Text(String(format: "%.1f s".loc, medianMs / 1000))
                        .font(.talkieMetric(42))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    GradePill(grade: grade)

                    Divider().overlay(Theme.hairline).padding(.vertical, 2)

                    Text(subtitle(count: sampleCount))
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    EmptyHint(icon: "gauge.with.dots.needle.33percent",
                              text: "Dictate a few times and your typical end-to-end speed shows up here.".loc)
                }
            }
            .talkieCard(fill: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The honest "your last dictation" / "typical across your last N dictations" line —
    /// says the REAL N when fewer than a full window of steady-state samples has
    /// accumulated, and only claims "50" once it truly has 50. Never rounds the count
    /// up. Avoids "median of one", which reads as nonsense when there's a single sample.
    private func subtitle(count: Int) -> String {
        let n = min(count, LatencyStore.maxRecords)
        if n == 1 { return "your last dictation".loc }
        return String(format: "typical across your last %d dictations".loc, n)
    }
}

/// The small grade chip ("Instant" / "Fast" / "OK" / "Slow") — a tinted wash with
/// the grade's hue. Presentation only; carries no shareable surface.
private struct GradePill: View {
    let grade: SpeedGrade
    var body: some View {
        Text(grade.label)
            .font(.talkieHeading(12, weight: .semibold))
            .foregroundStyle(grade.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(grade.tint.opacity(0.14))
            )
    }
}
