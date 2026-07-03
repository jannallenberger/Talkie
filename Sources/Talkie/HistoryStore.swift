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

/// Persisted log of recent dictations. Newest first, auto-pruned to the user's
/// chosen retention window (`historyRetentionDays`, default 7 days; "forever"
/// keeps everything). A separate hard `cap` bounds the file regardless of age.
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
    private let cap = 2000

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
         directory: URL? = nil) {
        let url = (directory ?? AppPaths.supportDirectory()).appendingPathComponent("history.json")
        fileURL = url
        writer = HistoryFileWriter(fileURL: url)
        retentionSeconds = HistoryStore.seconds(forRetentionDays: retentionDays)
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

    /// Apply a new retention window (in days; `0` = forever) and re-prune + save
    /// immediately, so shrinking retention takes effect without a relaunch. Wired
    /// from `AppSettings.$historyRetentionDays` at the composition root.
    func updateRetention(days: Int) {
        retentionSeconds = HistoryStore.seconds(forRetentionDays: days)
        prune()
        save()
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
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        save()
        return entry
    }

    func delete(_ entry: DictationEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clearAll() {
        entries.removeAll()
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

    /// Drop anything older than the retention window. With forever-retention
    /// (`retentionSeconds == .infinity`) the cutoff is `-.infinity`, so nothing
    /// is ever pruned.
    private func prune(now: Date = Date()) {
        let cutoff = now.timeIntervalSince1970 - retentionSeconds
        entries.removeAll { $0.timestampUnix < cutoff }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DictationEntry].self, from: data) else { return }
        entries = decoded
        prune()
        save() // persist the pruned set so the file doesn't grow unbounded
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
