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
        let dir = AppPaths.meetingsDirectory()
        let fileName = Self.resolvedFileName(for: note, in: dir)
        let url = dir.appendingPathComponent(fileName)
        try Data(Self.render(note).utf8).write(to: url, options: .atomic)
        return url
    }

    /// Meeting notes already arrive with a `.md` extension and a uuid baked into the
    /// name (collision-free by construction) and are written through untouched. A
    /// "note this" dictation note has neither: `NoteComposers.dictationNote` builds
    /// `suggestedFileName` via `NoteTemplate.fileName(..., existing: [])` — an EMPTY
    /// collision set, because the composer has no visibility into what this
    /// destination's directory already contains. Two such notes filed in the same
    /// minute would otherwise produce the identical base name, and the atomic write
    /// above would silently destroy the first one while the HUD still reports
    /// "Saved". De-collide here — mirroring `ObsidianVaultDestination.write` — against
    /// the `.md` base names actually on disk, then append the extension the composer
    /// never had a chance to add.
    static func resolvedFileName(for note: ExportableNote, in dir: URL) -> String {
        guard !note.suggestedFileName.hasSuffix(".md") else { return note.suggestedFileName }
        let existing = existingBaseNames(in: dir)
        let base = NoteTemplate.fileName(note.suggestedFileName, for: note, existing: existing)
        return base + ".md"
    }

    /// The extensionless base names of `.md` files already in `dir`, for collision
    /// avoidance. Mirrors `ObsidianVaultDestination.existingBaseNames` exactly.
    private static func existingBaseNames(in dir: URL) -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return Set(names.filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) })
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
