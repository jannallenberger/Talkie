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

    var date: Date { Date(timeIntervalSince1970: timestampUnix) }

    /// Words per minute for this dictation (0 if too short to be meaningful).
    var wpm: Double {
        guard durationSec >= 1.0, wordCount > 0 else { return 0 }
        return Double(wordCount) / (durationSec / 60)
    }
}

/// Persisted log of recent dictations (auto-pruned to the last 7 days). Newest first.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [DictationEntry] = []

    private let fileURL: URL
    private let retention: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private let cap = 2000

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("history.json")
        load()
    }

    func add(
        _ text: String,
        wordCount: Int,
        durationSec: Double,
        appName: String? = nil,
        appCategory: String? = nil,
        at date: Date = Date()
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = DictationEntry(
            timestampUnix: date.timeIntervalSince1970,
            text: trimmed,
            wordCount: wordCount,
            durationSec: durationSec,
            appName: appName,
            appCategory: appCategory
        )
        entries.insert(entry, at: 0)
        prune()
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        save()
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

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
