import Foundation

/// The pluggable export layer (features 02 + 10). Meetings — and, optionally,
/// dictations — are produced as a neutral `ExportableNote`; the destination
/// decides *where* and *how* to write it. The default `TalkieFolderDestination`
/// (in `Export/`) is the zero-config plain-Markdown folder; community
/// destinations (Obsidian, Logseq, Notion, …) conform WITHOUT touching core, and
/// the default needs no third-party app — the open-source genericity invariant.
protocol NoteDestination: Sendable {
    /// Stable id, e.g. "talkie-folder", "obsidian", "logseq".
    var id: String { get }
    var displayName: String { get }
    /// e.g. a folder has been picked and is accessible.
    var isConfigured: Bool { get }

    /// Write the note and return where it landed.
    @discardableResult
    func write(_ note: ExportableNote) async throws -> URL
}

/// The neutral note shape every producer fills in. Templating, front-matter, and
/// wikilinks are applied by the destination — never baked into the producer — so
/// the same note can travel to a plain folder or a wikilink-aware vault.
struct ExportableNote: Sendable {
    var kind: NoteKind
    var title: String
    var date: Date
    /// The Summary / Notes / Transcript sections, already composed as Markdown.
    var bodyMarkdown: String
    /// e.g. duration_min, participants, source, app.
    var frontMatter: [String: String] = [:]
    var tags: [String] = []
    /// Entity display names → optional `[[wikilinks]]` by a link-aware destination.
    var links: [String] = []
    var suggestedFileName: String
}

enum NoteKind: String, Sendable, Codable { case meeting, dictation, brief }
