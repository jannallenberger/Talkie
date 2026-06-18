import Foundation

/// The default, zero-config `NoteDestination`: writes plain Markdown into
/// `~/Talkie Meetings/` — no third-party app, no configuration. The shared
/// `render` helper is the single source of truth for a meeting note's Markdown,
/// used by both this destination and `MeetingStore.writeMarkdown`.
struct TalkieFolderDestination: NoteDestination {
    let id = "talkie-folder"
    let displayName = "Talkie Meetings folder"
    var isConfigured: Bool { true }

    @discardableResult
    func write(_ note: ExportableNote) async throws -> URL {
        let url = AppPaths.meetingsDirectory().appendingPathComponent(note.suggestedFileName)
        try Data(Self.render(note).utf8).write(to: url, options: .atomic)
        return url
    }

    /// Compose the meeting Markdown: YAML front-matter (historical key order, then
    /// any extras sorted for forward-compat) followed by the pre-composed body.
    /// Byte-compatible with the prior inline `MeetingStore.writeMarkdown`.
    static func render(_ note: ExportableNote) -> String {
        let iso = ISO8601DateFormatter().string(from: note.date)
        // Title and every value go through NoteTemplate's YAML escaper: a raw
        // calendar/meeting title with a metachar (`:`, `#`, leading space, quote)
        // — or, worse, a newline — would otherwise corrupt the block or inject
        // arbitrary front-matter keys. `renderYAMLField` passes producer-composed
        // `[...]` arrays through untouched and scalar-escapes everything else.
        var lines = ["---", "title: \(NoteTemplate.yamlValue(note.title))", "date: \(iso)"]
        let ordered = ["duration_min", "participants", "source"]
        for key in ordered {
            if let value = note.frontMatter[key] { lines.append("\(key): \(NoteTemplate.renderYAMLField(value))") }
        }
        for (key, value) in note.frontMatter.sorted(by: { $0.key < $1.key }) where !ordered.contains(key) {
            lines.append("\(key): \(NoteTemplate.renderYAMLField(value))")
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + note.bodyMarkdown
    }
}
