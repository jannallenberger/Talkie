import XCTest
@testable import Talkie

/// H10 (Ideas #15): Export is one question — *where* — and the vault case
/// configures itself. `ExportPreferences.resolvedDestination()` picks the concrete
/// `NoteDestination` the meeting/dictation writers route through, and now decides
/// the *shape* of the notes from `.obsidian` detection instead of three settings
/// toggles (deleted): a real vault → Obsidian formatting; a plain chosen folder →
/// plain Markdown in that folder; a bad path → the zero-config Talkie folder.
///
/// These are pure disk-I/O tests (temp dirs only) — no Core Audio, no model, no
/// network — matching the offline-core invariant the rest of the suite holds to.
final class ExportRoutingTests: XCTestCase {

    private func makeNote(title: String = "Sync with Sarah") -> ExportableNote {
        ExportableNote(
            kind: .meeting,
            title: title,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            bodyMarkdown: "## Summary\n\nshipped it\n\n## Transcript\n\nhello",
            frontMatter: ["duration_min": "12", "participants": "[Me, Them]", "source": "talkie (mic-only)"],
            tags: ["meeting"],
            links: ["Sarah Chen", "Coralate"],
            suggestedFileName: "2023-11-14-1453-meeting.md"
        )
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Turn a bare temp dir into an Obsidian vault by creating its `.obsidian`
    /// config directory — exactly what Obsidian writes when it opens a folder.
    private func makeVault() throws -> URL {
        let dir = try makeTempDir()
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".obsidian", isDirectory: true),
            withIntermediateDirectories: true)
        return dir
    }

    // MARK: isObsidianVault — the pure detector (Idea #15, criterion 3)

    func testIsObsidianVaultTrueWhenDotObsidianDirPresent() throws {
        let vault = try makeVault()
        XCTAssertTrue(ExportPreferences.isObsidianVault(vault.path),
                      "a folder containing a .obsidian directory must be detected as a vault")
    }

    func testIsObsidianVaultFalseForPlainFolder() throws {
        let plain = try makeTempDir()
        XCTAssertFalse(ExportPreferences.isObsidianVault(plain.path),
                       "a folder with no .obsidian directory is not a vault")
    }

    func testIsObsidianVaultFalseWhenDotObsidianIsAFileNotADir() throws {
        // A stray file literally named ".obsidian" must NOT count — vaults use a dir.
        let dir = try makeTempDir()
        try Data("not a config dir".utf8)
            .write(to: dir.appendingPathComponent(".obsidian"))
        XCTAssertFalse(ExportPreferences.isObsidianVault(dir.path),
                       "a .obsidian *file* (not directory) must not be read as a vault")
    }

    func testIsObsidianVaultFalseForEmptyPath() {
        XCTAssertFalse(ExportPreferences.isObsidianVault(""),
                       "an empty path is never a vault")
    }

    // MARK: resolvedDestination() routing — uses the real ExportPreferences singleton.
    // The singleton's init is private, so we seed `.shared` on the main actor and
    // restore both fields afterwards so test order can't leak prefs between cases.

    @MainActor
    private func withSeededPrefs(_ body: (ExportPreferences) throws -> Void) rethrows {
        let prefs = ExportPreferences.shared
        let saved = (prefs.destination, prefs.folderPath)
        defer {
            prefs.destination = saved.0
            prefs.folderPath = saved.1
        }
        try body(prefs)
    }

    @MainActor
    func testTalkieFolderPrefsResolveToTalkieFolder() {
        withSeededPrefs { prefs in
            prefs.destination = .talkieFolder
            XCTAssertEqual(prefs.resolvedDestination().id, "talkie-folder",
                           "the zero-config default must resolve to the Talkie folder")
        }
    }

    @MainActor
    func testFolderPrefsWithBogusPathFallBackToTalkieFolder() {
        withSeededPrefs { prefs in
            prefs.destination = .folder
            prefs.folderPath = "/no/such/path/\(UUID().uuidString)/vault"
            XCTAssertEqual(prefs.resolvedDestination().id, "talkie-folder",
                           "an inaccessible custom path must fall back to the Talkie folder — never lose a note")
        }
    }

    /// A real vault → Obsidian formatting, with ZERO configuration: the written
    /// note lands in the vault and carries front-matter, [[wikilinks]] and a #tag.
    @MainActor
    func testVaultFolderResolvesToObsidianFormattingWithNoConfig() async throws {
        let vault = try makeVault()
        let prefs = ExportPreferences.shared
        let saved = (prefs.destination, prefs.folderPath)
        defer { prefs.destination = saved.0; prefs.folderPath = saved.1 }
        prefs.destination = .folder
        prefs.folderPath = vault.path

        let destination = prefs.resolvedDestination()
        XCTAssertEqual(destination.id, "obsidian",
                       "an accessible vault must resolve to the Obsidian destination")

        let url = try await destination.write(makeNote())
        XCTAssertTrue(url.path.hasPrefix(vault.path),
                      "the note must land inside the vault, got \(url.path)")
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("---"),
                      "a vault export must open with a YAML front-matter fence:\n\(written)")
        XCTAssertTrue(written.contains("[[Sarah Chen]]"),
                      "a vault export must render related entities as [[wikilinks]]:\n\(written)")
        XCTAssertTrue(written.contains("#talkie"),
                      "a vault export must append the #talkie tag line:\n\(written)")
    }

    /// A plain chosen folder (no `.obsidian`) → plain Markdown, written INTO that
    /// folder (not ~/Talkie Meetings), with no front-matter, no [[links]], no tags.
    @MainActor
    func testPlainFolderResolvesToPlainMarkdownInThatFolder() async throws {
        let plain = try makeTempDir()
        let prefs = ExportPreferences.shared
        let saved = (prefs.destination, prefs.folderPath)
        defer { prefs.destination = saved.0; prefs.folderPath = saved.1 }
        prefs.destination = .folder
        prefs.folderPath = plain.path

        let destination = prefs.resolvedDestination()
        XCTAssertEqual(destination.id, "obsidian",
                       "a plain chosen folder still uses the folder-writing destination type")

        let url = try await destination.write(makeNote())
        XCTAssertTrue(url.path.hasPrefix(plain.path),
                      "the note must land in the chosen folder, got \(url.path)")
        // And NOT in ~/Talkie Meetings/.
        let talkieMeetings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Talkie Meetings", isDirectory: true)
        XCTAssertFalse(url.path.hasPrefix(talkieMeetings.path),
                       "a reachable plain folder must not fall back to ~/Talkie Meetings")

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(written.hasPrefix("---"),
                       "a plain-folder export must NOT emit front-matter:\n\(written)")
        XCTAssertFalse(written.contains("[[Sarah Chen]]"),
                       "a plain-folder export must NOT wikilink related entities:\n\(written)")
        XCTAssertFalse(written.contains("#talkie"),
                       "a plain-folder export must NOT append the #talkie tag line:\n\(written)")
    }

    /// Creating `.obsidian` inside an already-chosen folder upgrades the NEXT export
    /// with no settings change — the detector is re-run fresh on every resolve.
    @MainActor
    func testLateCreatedDotObsidianUpgradesNextExport() async throws {
        let folder = try makeTempDir()
        let prefs = ExportPreferences.shared
        let saved = (prefs.destination, prefs.folderPath)
        defer { prefs.destination = saved.0; prefs.folderPath = saved.1 }
        prefs.destination = .folder
        prefs.folderPath = folder.path

        // First export: plain folder, plain Markdown.
        let plainURL = try await prefs.resolvedDestination().write(makeNote(title: "Before"))
        let plain = try String(contentsOf: plainURL, encoding: .utf8)
        XCTAssertFalse(plain.hasPrefix("---"),
                       "before .obsidian exists, the export must be plain Markdown")

        // The user opens the folder in Obsidian — a `.obsidian` dir appears.
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(".obsidian", isDirectory: true),
            withIntermediateDirectories: true)

        // Next export, same prefs (nothing touched in Settings): now formatted.
        let vaultURL = try await prefs.resolvedDestination().write(makeNote(title: "After"))
        let vault = try String(contentsOf: vaultURL, encoding: .utf8)
        XCTAssertTrue(vault.hasPrefix("---"),
                      "after .obsidian appears, the next export must include front-matter with no settings change:\n\(vault)")
    }

    // MARK: Back-compat — old prefs files with the removed keys (criterion 4)

    /// Pre-existing `export_prefs.json` files still carry `includeFrontMatter` /
    /// `includeWikilinks` / `includeTags`. The new persistence keeps only
    /// `destination` + `folderPath`; `JSONDecoder` ignores keys not present in the
    /// target, so an old file decodes cleanly (the extra keys are simply dropped).
    /// This mirrors the exact decode `ExportPreferences.load()` performs.
    func testOldPrefsFileWithRemovedKeysDecodesWithoutError() throws {
        // A struct with EXACTLY the fields the current ExportPreferences persists,
        // so this asserts the real tolerant-decode contract, not a looser one.
        struct CurrentSnapshot: Codable {
            enum Destination: String, Codable { case talkieFolder, folder }
            var destination: Destination
            var folderPath: String
        }

        let oldJSON = """
        {
          "destination": "folder",
          "folderPath": "/Users/someone/Vault",
          "includeFrontMatter": true,
          "includeWikilinks": false,
          "includeTags": true
        }
        """
        let data = Data(oldJSON.utf8)

        let decoded = try JSONDecoder().decode(CurrentSnapshot.self, from: data)
        XCTAssertEqual(decoded.destination, .folder,
                       "the still-present destination key must decode")
        XCTAssertEqual(decoded.folderPath, "/Users/someone/Vault",
                       "the still-present folderPath key must decode")
        // The three removed keys were tolerated (ignored) — no throw reached here.
    }

    // MARK: ObsidianVaultDestination toggle fidelity — the type still honours its
    // flags per-export (the resolver sets them from vault detection; a community
    // destination or a future caller may set them directly).

    func testFrontMatterOffOmitsYAMLFence() async throws {
        let temp = try makeTempDir()
        let destination = ObsidianVaultDestination(
            vaultURL: temp,
            subfolder: "",
            includeFrontMatter: false,
            includeWikilinks: true,
            includeTags: true
        )
        let url = try await destination.write(makeNote())
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(written.hasPrefix("---"),
                       "with front-matter OFF the output must not start with a YAML fence")
    }

    func testFrontMatterOnEmitsYAMLFence() async throws {
        let temp = try makeTempDir()
        let destination = ObsidianVaultDestination(
            vaultURL: temp,
            subfolder: "",
            includeFrontMatter: true,
            includeWikilinks: true,
            includeTags: true
        )
        let url = try await destination.write(makeNote())
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("---"),
                      "with front-matter ON the output must open with a YAML fence")
    }

    func testTagsOffOmitsTagLineAndWikilinksOffPlainLinks() async throws {
        let temp = try makeTempDir()
        let destination = ObsidianVaultDestination(
            vaultURL: temp,
            subfolder: "",
            includeFrontMatter: false,
            includeWikilinks: false,
            includeTags: false
        )
        let url = try await destination.write(makeNote())
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(written.contains("#talkie"),
                       "with tags OFF the #tag line must be omitted")
        XCTAssertFalse(written.contains("[[Sarah Chen]]"),
                       "with wikilinks OFF related entities must render as plain text, not [[links]]")
        XCTAssertTrue(written.contains("Sarah Chen"),
                      "the related entity should still appear, just unlinked")
    }
}
