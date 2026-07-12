import Foundation

/// An *example* community `NoteDestination` (feature 10) showing how a third-party
/// note system plugs into the export seam WITHOUT touching core: it conforms to the
/// spine's `NoteDestination`, reuses `NoteTemplate` for all rendering, and only
/// differs from the default by which flags it turns on (wikilinks + front-matter
/// ON, tags ON) and by writing into a user-chosen vault subfolder.
///
/// It is NOT part of the zero-config default — the user must point it at a vault.
/// It is still 100% local disk I/O (no `URLSession`, nothing leaves the Mac); a
/// networked destination (e.g. a Notion API impl) would live outside core behind
/// the network wall. This file is the canonical reference a contributor copies to
/// support Logseq, a daily-note vault, callout-wrapped notes, etc.
///
/// Wikilinks light up `note.links` (the entity display names the context graph
/// extracted, feature 05) as `[[Sarah Chen]]` / `[[GitHub]]` so a flat transcript
/// becomes a navigable knowledge node — gracefully empty until the graph exists.
struct ObsidianVaultDestination: NoteDestination {
    let id = "obsidian"
    let displayName = "Obsidian vault"

    /// The vault root the user picked (injected — core never hardcodes a path).
    /// Under the App Sandbox this is resolved from a security-scoped bookmark by
    /// the caller before construction; here it is a plain, accessible URL.
    var vaultURL: URL

    /// Subfolder inside the vault to write into (e.g. "Talkie", "Inbox/Voice").
    /// Empty ⇒ the vault root. Created on demand.
    var subfolder: String = "Talkie"

    /// Filename template (see `NoteTemplate`). Obsidian users usually want the
    /// human title in the filename so the note's display name reads well in the
    /// sidebar and as a `[[wikilink]]` target.
    var fileNameTemplate: String = "{date}-{title}"

    /// Extra tags appended to every exported note (e.g. ["talkie", "voice"]).
    var extraTags: [String] = ["talkie"]

    /// Prepend a YAML front-matter block. Defaults ON (Obsidian's signature), but
    /// honoured per-export: `ExportPreferences.resolvedDestination()` constructs
    /// this destination with all three format flags set from `.obsidian` detection
    /// — ON for a real vault, OFF for a plain chosen folder — so the same type
    /// serves both cases and no formatting knob is exposed in Settings.
    var includeFrontMatter: Bool = true

    /// Render the note's `links` as `[[wikilinks]]` in a Related block. Defaults ON;
    /// set from vault detection at construction (see `includeFrontMatter`).
    var includeWikilinks: Bool = true

    /// Append a `#tag` line. Defaults ON; set from vault detection at construction.
    var includeTags: Bool = true

    /// Configured when the vault folder exists and is writable.
    var isConfigured: Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vaultURL.path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        return FileManager.default.isWritableFile(atPath: vaultURL.path)
    }

    @discardableResult
    func write(_ note: ExportableNote) async throws -> URL {
        let dir = subfolder.isEmpty
            ? vaultURL
            : vaultURL.appendingPathComponent(subfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // De-collide against the .md files already in the target directory.
        let existing = Self.existingBaseNames(in: dir)
        let base = NoteTemplate.fileName(fileNameTemplate, for: note, existing: existing)

        // Obsidian's signature is front-matter / [[wikilinks]] / tags ON; each is
        // honoured per-export, so a plain chosen folder (all flags OFF) writes
        // clean Markdown through this very same destination.
        let markdown = NoteTemplate.wrap(
            note,
            frontMatter: includeFrontMatter,
            tags: includeTags,
            wikilinks: includeWikilinks,
            extraTags: extraTags
        )

        let url = dir.appendingPathComponent(base + ".md")
        try Data(markdown.utf8).write(to: url, options: .atomic)
        return url
    }

    /// The extensionless base names of `.md` files already in `dir`, for collision
    /// avoidance. Cheap (one shallow directory read per write).
    private static func existingBaseNames(in dir: URL) -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return Set(names.filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) })
    }
}
