// Reads Talkie's local dictation history as a peer of the app — the same on-disk
// JSON the app writes at ~/Library/Application Support/Talkie/history.json
// (HistoryStore.swift), and the same slim Codable mirror TalkieMCP uses
// (Sources/TalkieMCP/TalkieStore.swift) so the CLI stays a separate, app-free,
// network-free binary. Extra fields are optional for forward/back-compat.

import Foundation

/// A slim mirror of the app's persisted `DictationEntry`. Only the fields the CLI
/// prints are modeled; every optional keeps decoding tolerant of older/newer files
/// (matching HistoryStore's "new fields optional for back-compat" discipline).
struct DictationEntry: Codable {
    var id: UUID
    var timestampUnix: Double
    var text: String
    var wordCount: Int?
    var appName: String?
}

enum HistoryReader {
    /// The canonical history location, mirroring `AppPaths.supportDirectory()`.
    static func historyURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/Talkie/history.json",
                                           isDirectory: false)
    }

    /// Whether the history file exists on disk. Used to give a friendly,
    /// distinct message (vs. "exists but empty") before attempting to read.
    static func historyExists() -> Bool {
        FileManager.default.fileExists(atPath: historyURL().path)
    }

    /// Decode the history, newest first. The app already stores newest-first
    /// (it inserts at index 0), but we sort by timestamp descending anyway so the
    /// CLI's "newest" is correct regardless of how the file was produced. Returns
    /// nil only when the file is absent or unreadable/corrupt (distinct from an
    /// empty `[]`, which decodes to an empty array).
    static func load() -> [DictationEntry]? {
        let url = historyURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let entries = try? JSONDecoder().decode([DictationEntry].self, from: data) else {
            return nil
        }
        return entries.sorted { $0.timestampUnix > $1.timestampUnix }
    }
}
