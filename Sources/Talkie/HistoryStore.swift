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

/// Persisted log of recent dictations (auto-pruned to the last 7 days). Newest first.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [DictationEntry] = []

    private let fileURL: URL
    private let retention: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private let cap = 2000

    /// Off-main JSON encode + atomic write. Callers are unchanged: `save()` still
    /// looks synchronous to them, but it only schedules — the cost moves here.
    private let writer: HistoryFileWriter
    /// Debounce so a burst of mutations coalesces into one disk write.
    private let saveDebounce: Duration = .milliseconds(250)
    private var pendingSave: Task<Void, Never>?
    /// Monotonic save token; the writer drops any write older than the newest.
    private var saveGeneration = 0

    init() {
        let url = AppPaths.supportDirectory().appendingPathComponent("history.json")
        fileURL = url
        writer = HistoryFileWriter(fileURL: url)
        load()
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

    /// Words logged in the retained window (≈ last 7 days).
    var wordsLast7Days: Int {
        entries.reduce(0) { $0 + $1.wordCount }
    }

    /// Drop anything older than the retention window.
    private func prune(now: Date = Date()) {
        let cutoff = now.timeIntervalSince1970 - retention
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
