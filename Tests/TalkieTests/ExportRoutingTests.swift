import XCTest
@testable import Talkie

/// Covers C6 (P1-04 + P1-20): the Export-destinations choice is no longer dead-wired.
/// `ExportPreferences.resolvedDestination()` now picks the concrete `NoteDestination`
/// the meeting writer routes through, and `ObsidianVaultDestination` honours the
/// front-matter / wikilinks / tags toggles instead of hardcoding them ON.
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

    // MARK: resolvedDestination() routing — uses the real ExportPreferences singleton.
    // The singleton's init is private, so we seed `.shared` on the main actor and
    // restore every field afterwards so test order can't leak prefs between cases.

    @MainActor
    private func withSeededPrefs(_ body: (ExportPreferences) throws -> Void) rethrows {
        let prefs = ExportPreferences.shared
        let saved = (prefs.destination, prefs.folderPath,
                     prefs.includeFrontMatter, prefs.includeWikilinks, prefs.includeTags)
        defer {
            prefs.destination = saved.0
            prefs.folderPath = saved.1
            prefs.includeFrontMatter = saved.2
            prefs.includeWikilinks = saved.3
            prefs.includeTags = saved.4
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
    func testFolderPrefsWithAccessibleDirResolveToObsidianAndLandThere() async throws {
        let temp = try makeTempDir()
        // Seed `.shared`, resolve, and restore on the main actor; the resolved
        // destination is `Sendable`, so the write below crosses off-actor cleanly —
        // exactly the resolve-here / write-off-actor split MeetingStore now uses.
        let prefs = ExportPreferences.shared
        let saved = (prefs.destination, prefs.folderPath)
        defer { prefs.destination = saved.0; prefs.folderPath = saved.1 }
        prefs.destination = .folder
        prefs.folderPath = temp.path

        let destination = prefs.resolvedDestination()
        XCTAssertEqual(destination.id, "obsidian",
                       "an accessible custom folder must resolve to the Obsidian destination")

        let url = try await destination.write(makeNote())

        XCTAssertTrue(url.path.hasPrefix(temp.path),
                      "the note must land under the chosen folder, got \(url.path)")
        XCTAssertEqual(url.pathExtension, "md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "a .md file must exist under the temp dir")

        // And it must NOT have gone to ~/Talkie Meetings/.
        let talkieMeetings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Talkie Meetings", isDirectory: true)
        XCTAssertFalse(url.path.hasPrefix(talkieMeetings.path),
                       "the note must not fall back to ~/Talkie Meetings when the folder is good")
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

    // MARK: ObsidianVaultDestination toggle fidelity (P1-20)

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
