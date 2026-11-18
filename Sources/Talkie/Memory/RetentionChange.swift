import Foundation

/// Decision logic for the Memory page's inline "Keep history" picker. Pure, so the
/// confirm-before-shortening rule and the deleted-entry count are unit-tested.
///
/// The picker binds the SAME `AppSettings.historyRetentionDays` as Settings >
/// Privacy & history (one source of truth); `HistoryStore.updateRetention` re-prunes
/// the moment it changes, so a shorter window deletes older dictations immediately.
/// That is why a shortening that would delete anything asks first.
enum RetentionChange {
    /// The compact choice set the Memory header offers: 7 / 30 / 90 days / Forever.
    /// When the stored value is another defined option (1 day, set in Settings), it is
    /// included so the picker always shows the real current selection.
    static func quickOptions(current: HistoryRetention) -> [HistoryRetention] {
        let base: [HistoryRetention] = [.sevenDays, .thirtyDays, .ninetyDays, .forever]
        return base.contains(current) ? base : [current] + base
    }

    /// Whether moving from `oldDays` to `newDays` keeps history for less time.
    /// `0` (or negative) means forever, the longest possible window.
    static func isShorter(from oldDays: Int, to newDays: Int) -> Bool {
        let old = window(days: oldDays)
        let new = window(days: newDays)
        return new < old
    }

    /// How many entries a `newDays` window would drop right now. Mirrors
    /// `HistoryStore.prune` exactly: an entry is dropped when its timestamp is
    /// strictly older than `now - window`.
    static func entriesDeleted(timestamps: [Double], newDays: Int, now: Date) -> Int {
        let span = window(days: newDays)
        guard span.isFinite else { return 0 }
        let cutoff = now.timeIntervalSince1970 - span
        return timestamps.reduce(0) { $0 + ($1 < cutoff ? 1 : 0) }
    }

    /// The confirmation to show before applying `newDays`, as the number of entries
    /// that would be deleted; `nil` means apply straight away (a longer or equal
    /// window, or a shorter one that deletes nothing).
    static func confirmationCount(from oldDays: Int, to newDays: Int,
                                  timestamps: [Double], now: Date) -> Int? {
        guard isShorter(from: oldDays, to: newDays) else { return nil }
        let n = entriesDeleted(timestamps: timestamps, newDays: newDays, now: now)
        return n > 0 ? n : nil
    }

    /// Same conversion as `HistoryStore.seconds(forRetentionDays:)` (kept local so this
    /// enum stays nonisolated): `0` or less is forever (`.infinity`).
    static func window(days: Int) -> TimeInterval {
        days <= 0 ? .infinity : TimeInterval(days) * 24 * 60 * 60
    }

    /// The confirmation's message: how many older dictations go, and that it's now.
    static func confirmationMessage(count: Int) -> String {
        count == 1
            ? "1 older dictation will be deleted from this Mac right away. This can't be undone.".loc
            : String(format: "%d older dictations will be deleted from this Mac right away. This can't be undone.".loc, count)
    }
}
