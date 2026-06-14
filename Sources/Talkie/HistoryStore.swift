import Foundation

/// One past dictation: when, and the final (cleaned) text.
struct DictationEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var timestampUnix: Double
    var text: String

    var date: Date { Date(timeIntervalSince1970: timestampUnix) }
}

/// Persisted log of past dictations, shown in the History tab. Newest first.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [DictationEntry] = []

    private let fileURL: URL
    private let cap = 1000

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("history.json")
        load()
    }

    func add(_ text: String, at date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(DictationEntry(timestampUnix: date.timeIntervalSince1970, text: trimmed), at: 0)
        if entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
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

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DictationEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
