import Foundation

/// One past dictation: when, the final (cleaned) text, and its size/speed.
struct DictationEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var timestampUnix: Double
    var text: String
    var wordCount: Int = 0
    var durationSec: Double = 0
    /// Which app you dictated into (optional for back-compat with older files).
    var appName: String?
    var appCategory: String?
    /// The app's stable bundle identifier — unlike `appName` (a display name,
    /// not guaranteed unique/stable across relaunches or localizations), this
    /// is what `ImplicitSelectionGate` compares against the current dictation's
    /// target app. Optional for back-compat with entries written before this
    /// field existed; those entries simply never qualify for the implicit
    /// fallback (fails closed on missing data, not a bug).
    var bundleID: String?

    var date: Date { Date(timeIntervalSince1970: timestampUnix) }

    /// Words per minute for this dictation (0 if too short to be meaningful).
    var wpm: Double {
        guard durationSec >= 1.0, wordCount > 0 else { return 0 }
        return Double(wordCount) / (durationSec / 60)
    }
}

/// Serializes the encode+write off the main actor so the dictation-completion
/// path never blocks the UI on JSON + disk I/O. Each `write` carries a monotonic
/// `generation`; a write whose generation is already stale (a newer snapshot
/// arrived first) is dropped, so a burst of saves collapses to the last state
/// and writes can't reorder. The `[DictationEntry]` snapshot is a value type
/// (Sendable), so handing it across the actor boundary copies, never shares.
actor HistoryFileWriter {
    private let fileURL: URL
    private var latestWritten = 0

    init(fileURL: URL) { self.fileURL = fileURL }

    func write(_ entries: [DictationEntry], generation: Int) {
        guard generation > latestWritten else { return }
        latestWritten = generation
        // `.sortedKeys` makes the encoding deterministic: Foundation does NOT
        // guarantee stable JSON key ordering, so a bare `JSONEncoder().encode`
        // can emit the same value with keys in different order between calls
        // (even within one process). Pinning the order keeps history.json stable
        // and diffable on disk, and makes any byte-exact comparison meaningful.
        // Key ORDER only — decoding is order-independent, so files written by
        // older builds still decode unchanged (back-compat safe).
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Persisted log of recent dictations. Newest first, pruned by two independent,
/// user-configurable limits (the stricter always wins): a retention *window*
/// (`historyRetentionDays`, default 7 days; "forever" keeps everything) and a
/// *count* cap (`historyMaxCount`, default 2000; "no limit" keeps everything).
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [DictationEntry] = []

    private let fileURL: URL
    /// How long a dictation is kept before pruning. Driven by
    /// `AppSettings.historyRetentionDays`; `0` days means "forever"
    /// (`.infinity`, so `prune` never drops anything). Not a `let` anymore
    /// because the user can change retention live (`updateRetention(days:)`),
    /// which re-prunes immediately — see `SettingsView`'s "Your history" card.
    private var retentionSeconds: TimeInterval
    /// Days used only for the honest window `wordsLast7Days` reports — always a
    /// fixed 7 days regardless of retention, so the dashboard's "Last 7 days"
    /// stat stays correct even when the user keeps history for 30/90 days.
    private let dashboardWindow: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    /// Hard cap on retained entries regardless of age. Driven by
    /// `AppSettings.historyMaxCount`; `0` = no limit. A `var` (not `let`) because
    /// the user can change it live via `updateMaxCount(_:)`, which re-trims at once.
    private var maxCount: Int

    /// Off-main JSON encode + atomic write. Callers are unchanged: `save()` still
    /// looks synchronous to them, but it only schedules — the cost moves here.
    private let writer: HistoryFileWriter
    /// Debounce so a burst of mutations coalesces into one disk write.
    private let saveDebounce: Duration = .milliseconds(250)
    private var pendingSave: Task<Void, Never>?
    /// Monotonic save token; the writer drops any write older than the newest.
    private var saveGeneration = 0

    /// `retentionDays` defaults to the value `AppSettings` already registered
    /// (7 for untouched installs; `0` = forever) so the store reads the user's
    /// real choice BEFORE `load()` runs its first prune — otherwise a "Forever"
    /// user would silently lose >7-day-old dictations on every launch. Tests pass
    /// an explicit value to construct hermetically without touching UserDefaults.
    /// Ordering guarantee: `AppSettings()` is built before `HistoryStore()` at the
    /// composition root (AppDelegate), so this default read sees the registered
    /// default even on a first run — keep that order.
    ///
    /// `directory` defaults to the real support dir; tests pass a temp dir so they
    /// neither read the developer's real `history.json` (non-deterministic) nor let
    /// the debounced `save()` clobber it. Mirrors `HistoryFileWriter(fileURL:)`.
    init(retentionDays: Int = HistoryStore.storedRetentionDays(),
         maxCount: Int = HistoryStore.storedMaxCount(),
         directory: URL? = nil) {
        let url = (directory ?? AppPaths.supportDirectory()).appendingPathComponent("history.json")
        fileURL = url
        writer = HistoryFileWriter(fileURL: url)
        retentionSeconds = HistoryStore.seconds(forRetentionDays: retentionDays)
        self.maxCount = maxCount
        load()
    }

    /// The persisted retention choice (in days), read straight from the same
    /// `UserDefaults` key `AppSettings` registers. `0` means "forever".
    static func storedRetentionDays() -> Int {
        UserDefaults.standard.integer(forKey: "historyRetentionDays")
    }

    /// Convert a retention-days setting to a cutoff window. `0` (or negative,
    /// defensively) → `.infinity` so `prune` keeps everything.
    static func seconds(forRetentionDays days: Int) -> TimeInterval {
        days <= 0 ? .infinity : TimeInterval(days) * 24 * 60 * 60
    }

    /// The persisted count cap, read straight from the same `UserDefaults` key
    /// `AppSettings` registers (default 2000). `0` means "no limit". Mirrors
    /// `storedRetentionDays()` and shares its init-ordering guarantee.
    static func storedMaxCount() -> Int {
        UserDefaults.standard.integer(forKey: "historyMaxCount")
    }

    /// Apply a new retention window (in days; `0` = forever) and re-prune + save
    /// immediately, so shrinking retention takes effect without a relaunch. Wired
    /// from `AppSettings.$historyRetentionDays` at the composition root.
    func updateRetention(days: Int) {
        retentionSeconds = HistoryStore.seconds(forRetentionDays: days)
        prune()
        save()
    }

    /// Apply a new count cap (`0` = no limit) and re-trim + save immediately, so
    /// lowering the cap takes effect without a relaunch. Wired from
    /// `AppSettings.$historyMaxCount` at the composition root.
    func updateMaxCount(_ count: Int) {
        maxCount = count
        applyCap()
        save()
    }

    /// Drop the oldest entries beyond `maxCount`. No-op when `maxCount <= 0`
    /// ("no limit") or already within the cap. Entries are newest-first, so the
    /// tail is the oldest — exactly what falls off.
    private func applyCap() {
        guard maxCount > 0, entries.count > maxCount else { return }
        entries.removeLast(entries.count - maxCount)
    }

    /// `id` defaults to a fresh UUID (existing call sites are unaffected) but can be
    /// supplied by the caller so it can reuse the SAME id as a `Provenance.sourceID`
    /// when it also feeds the context graph from the same dictation — the two stores
    /// then agree on "which dictation was this," which is what lets the graph's
    /// dedup-by-(source, sourceID) logic actually work for live dictation instead of
    /// silently collapsing every session into one.
    @discardableResult
    func add(
        _ text: String,
        wordCount: Int,
        durationSec: Double,
        appName: String? = nil,
        appCategory: String? = nil,
        bundleID: String? = nil,
        at date: Date = Date(),
        id: UUID = UUID()
    ) -> DictationEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let entry = DictationEntry(
            id: id,
            timestampUnix: date.timeIntervalSince1970,
            text: trimmed,
            wordCount: wordCount,
            durationSec: durationSec,
            appName: appName,
            appCategory: appCategory,
            bundleID: bundleID
        )
        entries.insert(entry, at: 0)
        prune()
        applyCap()
        save()
        return entry
    }

    func delete(_ entry: DictationEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    /// Rewrite the text of an existing entry in place, keeping its id, timestamp, and
    /// app metadata (B9). Used when a voice edit ("replace X with Y") fixes text the
    /// user just dictated: the stored history must reflect what's now on screen so a
    /// follow-up "replace…" composes on the EDITED text, not the stale original — and
    /// so the History tab shows the corrected version. Deliberately does NOT touch
    /// word counts, lifetime stats, or the context graph: an in-place edit isn't a new
    /// dictation, and re-ingesting it would double-count words and duplicate graph
    /// provenance. A "scratch that" removes the entry entirely via `delete` instead of
    /// storing an empty one. No-op if the id isn't found or the new text is empty
    /// (a full erase should route through `delete`, not this).
    func updateText(id: UUID, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text = trimmed
        save()
    }

    func clearAll() {
        entries.removeAll()
        // Overwrite-then-delete the existing history.json before the empty rewrite,
        // so the literal dictation text it held doesn't sit intact-but-unlinked on
        // disk (best effort — see FileShredder). save() then writes the now-empty set.
        // Cancel any in-flight debounced write first so it can't race the shred and
        // re-materialize the old bytes between the overwrite and the empty rewrite.
        pendingSave?.cancel()
        pendingSave = nil
        FileShredder.shred(fileURL)
        save()
    }

    /// All entries as plain text, newest first — for "Copy all".
    func allAsText() -> String {
        entries.map(\.text).joined(separator: "\n\n")
    }

    /// Words logged in the trailing 7 days. Filters on an explicit 7-day cutoff
    /// rather than summing every retained entry, so the dashboard's "Last 7 days"
    /// stat stays honest at any retention setting (30/90 days / forever). Kept as
    /// a computed property so the DashboardView call site is unchanged; the
    /// testable core lives in `wordsInLast7Days(now:)`.
    var wordsLast7Days: Int { wordsInLast7Days(now: Date()) }

    /// Testable core of `wordsLast7Days` with an injectable `now`.
    func wordsInLast7Days(now: Date) -> Int {
        let cutoff = now.timeIntervalSince1970 - dashboardWindow
        return entries.reduce(0) { $0 + ($1.timestampUnix >= cutoff ? $1.wordCount : 0) }
    }

    /// On-disk size of `history.json` in bytes, read via a cheap file stat — NOT a
    /// re-encode of `entries`. Encoding the whole log (hundreds of long dictations)
    /// on a SwiftUI body pass is wasteful and can stutter the UI, so the settings
    /// "how much space" readout reflects the last debounced write instead. That means
    /// it can trail the in-memory count by a fraction of a second (a fresh dictation
    /// shows before the file grows); acceptable for an at-a-glance footprint. `0`
    /// before the first save, or if the file was shredded by `clearAll`.
    var onDiskByteCount: Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? Int) ?? 0
    }

    /// Drop anything older than the retention window. With forever-retention
    /// (`retentionSeconds == .infinity`) the cutoff is `-.infinity`, so nothing
    /// is ever pruned.
    private func prune(now: Date = Date()) {
        let cutoff = now.timeIntervalSince1970 - retentionSeconds
        entries.removeAll { $0.timestampUnix < cutoff }
    }

    private func load() {
        guard let decoded = StoreLoad.loadJSONWithQuarantine([DictationEntry].self, from: fileURL) else { return }
        entries = decoded
        prune()
        applyCap()
        save() // persist the pruned+capped set so the file doesn't grow unbounded
    }

    /// Schedule a coalesced, off-main persist. Synchronous to callers — it only
    /// snapshots the current entries and debounces; the JSON encode + atomic write
    /// run on `HistoryFileWriter`, never on the main actor.
    private func save() {
        saveGeneration += 1
        let generation = saveGeneration
        let snapshot = entries          // value-type copy — Sendable across the hop
        let writer = self.writer
        let delay = saveDebounce
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await writer.write(snapshot, generation: generation)
            // Only clear the handle if a newer save hasn't already replaced it.
            if let self, self.saveGeneration == generation { self.pendingSave = nil }
        }
    }

    /// Force any pending debounced save to complete now (app teardown / tests).
    /// Writes the latest snapshot synchronously-from-the-caller's-await; the encode
    /// + disk write still happen off the main actor on the writer.
    func flush() async {
        pendingSave?.cancel()
        pendingSave = nil
        saveGeneration += 1
        await writer.write(entries, generation: saveGeneration)
    }
}
