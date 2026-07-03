import Foundation

/// The lifetime-words milestone ladder: a fixed set of ascending word-count
/// thresholds and the pure arithmetic for placing a running total against them.
///
/// This is a DATA layer only — no copy, no UI, no persistence. It answers three
/// questions a caller (a badge, a "you're almost there" nudge, a celebration on
/// crossing) needs: which rung are you standing on, how far to the next one, and
/// did a given jump just clear a new rung. Callers own all the strings.
///
/// `tier` is an INDEX into `thresholds` (0 = the 10k rung, 8 = the 1M-plus… wait,
/// the 2M rung), not a word count — so callers can look up their own label array
/// by the same index. `nil` means "below the first rung" everywhere.
enum MilestoneLadder {
    /// Ascending, distinct. Index 0 is the first rung a user can reach.
    static let thresholds = [
        10_000, 25_000, 50_000, 100_000, 250_000,
        500_000, 750_000, 1_000_000, 2_000_000,
    ]

    /// The index of the highest threshold that `total` has reached (`>=`), or
    /// `nil` if `total` is below the first rung (10k). A total sitting exactly on
    /// a threshold counts as having reached it.
    static func tier(for total: Int) -> Int? {
        var result: Int? = nil
        for (i, t) in thresholds.enumerated() where total >= t {
            result = i
        }
        return result
    }

    /// The next rung above `total` and how far along the user is toward it,
    /// measured from the PREVIOUS rung (0 at the previous rung, 1 at the next).
    ///
    /// - Below the first rung, "previous" is 0, so progress runs 0…1 across the
    ///   first `[0, 10_000)` band.
    /// - At or above the TOP rung there is no next rung, so this returns `nil`.
    /// - `progress` is clamped to `0...1` for safety against odd inputs.
    static func next(after total: Int) -> (threshold: Int, progress: Double)? {
        // Find the first threshold strictly greater than `total` — that's the target.
        guard let nextIndex = thresholds.firstIndex(where: { $0 > total }) else {
            return nil // already at or past the last rung
        }
        let nextThreshold = thresholds[nextIndex]
        // The floor of the current band: the previous threshold, or 0 below the first.
        let previous = nextIndex == 0 ? 0 : thresholds[nextIndex - 1]
        let span = nextThreshold - previous
        let raw = span > 0 ? Double(total - previous) / Double(span) : 0
        let progress = min(1, max(0, raw))
        return (nextThreshold, progress)
    }

    /// The highest tier index newly crossed by moving from `from` to `to`, or
    /// `nil` if no new rung was cleared. A single update that leaps several rungs
    /// at once reports the HIGHEST one reached (the caller celebrates the biggest).
    ///
    /// "Newly crossed" means reached by `to` but not already by `from`, so calling
    /// this repeatedly with a monotonically rising total fires each rung exactly
    /// once. A non-increasing move (`to <= from`) never reports a crossing.
    static func crossed(from: Int, to: Int) -> Int? {
        guard to > from else { return nil }
        let before = tier(for: from)
        guard let after = tier(for: to) else { return nil }
        // `after` is the highest rung `to` reached. If `from` was already at or
        // above it, nothing new was crossed.
        if let before, before >= after { return nil }
        return after
    }
}
