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

// MARK: - D4: NoteComposers (note-this dictation + Brief) — pure logic

/// D4 closes the export gap: a "note this …" dictation and Today's Brief become
/// durable Markdown notes. `NoteComposers` is the pure producer (the dictation/brief
/// analogue of `MeetingStore.writeMarkdown`), so it's exhaustively unit-testable
/// with no Core Audio, model, or disk — matching the offline-core invariant. These
/// cover the risky bits the maker can't verify headless: trigger parsing (incl.
/// "Note this,"), title derivation, and entity-link matching.
final class NoteComposersTests: XCTestCase {

    // MARK: Trigger parsing

    func testTriggerBodyStripsPrefix() {
        XCTAssertEqual(NoteComposers.triggerMatch(for: "note this remember to rotate the API keys"),
                       .body("remember to rotate the API keys"),
                       "a 'note this <x>' utterance must strip the trigger and keep the remainder as the body")
    }

    func testTriggerIsCaseInsensitive() {
        XCTAssertEqual(NoteComposers.triggerMatch(for: "Note This Buy Milk"),
                       .body("Buy Milk"),
                       "the trigger match is case-insensitive but the body keeps its original casing")
    }

    func testTriggerNoteThatAlsoWorks() {
        XCTAssertEqual(NoteComposers.triggerMatch(for: "note that the build is green"),
                       .body("the build is green"),
                       "'note that' is an accepted trigger alongside 'note this'")
    }

    func testTriggerSwallowsTrailingComma() {
        XCTAssertEqual(NoteComposers.triggerMatch(for: "Note this, remember the keys"),
                       .body("remember the keys"),
                       "a single trailing comma right after the trigger is swallowed before the body")
    }

    func testTriggerSwallowsTrailingColon() {
        XCTAssertEqual(NoteComposers.triggerMatch(for: "note this: remember the keys"),
                       .body("remember the keys"),
                       "a single trailing colon right after the trigger is swallowed before the body")
    }

    func testBareTriggerReturnsPrevious() {
        XCTAssertEqual(NoteComposers.triggerMatch(for: "note this"), .previous,
                       "a bare 'note this' with no remainder means: file the previous dictation")
        XCTAssertEqual(NoteComposers.triggerMatch(for: "Note this  "), .previous,
                       "trailing whitespace after a bare trigger still counts as bare")
        XCTAssertEqual(NoteComposers.triggerMatch(for: "note this,"), .previous,
                       "a bare trigger with only a trailing comma is still bare")
    }

    func testNonTriggerReturnsNil() {
        XCTAssertNil(NoteComposers.triggerMatch(for: "the meeting notes are done"),
                     "an ordinary sentence is not a note command")
        XCTAssertNil(NoteComposers.triggerMatch(for: "I want to note this down for later"),
                     "the trigger is anchored to the START — 'note this' mid-sentence must not fire")
    }

    func testTriggerRequiresWordBoundary() {
        XCTAssertNil(NoteComposers.triggerMatch(for: "note thistle care instructions"),
                     "'note thistle' starts with the trigger letters but is a different word — must not match")
        XCTAssertNil(NoteComposers.triggerMatch(for: "notethis buy milk"),
                     "no boundary after 'note' — 'notethis' must not match")
    }

    func testTriggerToleratesLeadingWhitespace() {
        XCTAssertEqual(NoteComposers.triggerMatch(for: "  note this buy milk"),
                       .body("buy milk"),
                       "leading whitespace before the trigger is tolerated")
    }

    // MARK: Title derivation

    func testTitleFirstEightWords() {
        let body = "one two three four five six seven eight nine ten"
        XCTAssertEqual(NoteComposers.titleWords(from: body, maxWords: 8),
                       "one two three four five six seven eight",
                       "the title is the first eight whitespace-separated words")
    }

    func testTitleShorterThanLimitKeepsAll() {
        XCTAssertEqual(NoteComposers.titleWords(from: "buy milk", maxWords: 8), "buy milk",
                       "a short body keeps all its words")
    }

    func testTitleCollapsesWhitespaceAndNewlines() {
        XCTAssertEqual(NoteComposers.titleWords(from: "  hello\n\nthere   world  ", maxWords: 8),
                       "hello there world",
                       "runs of whitespace/newlines never leak into the one-line title")
    }

    func testDictationNoteTitleFallsBackWhenEmpty() {
        let note = NoteComposers.dictationNote(text: "   ", target: .unknown,
                                               date: Date(timeIntervalSince1970: 1_700_000_000),
                                               graph: .empty)
        XCTAssertEqual(note.title, "Note",
                       "an empty body yields a stable 'Note' title rather than a blank one")
    }

    // MARK: Entity-link matching

    private func entity(_ kind: EntityKind, _ name: String, aliases: [String] = []) -> Entity {
        Entity(id: EntityID(kind: kind, key: name.lowercased()),
               displayName: name, aliases: aliases,
               firstSeenUnix: 0, lastSeenUnix: 0)
    }

    func testMentionedEntitiesMatchesByDisplayName() {
        let graph = ContextGraphSnapshot(entities: [
            entity(.project, "Coralate"),
            entity(.person, "Sarah Chen"),
        ])
        let links = NoteComposers.mentionedEntities(in: "shipped the Coralate onboarding today", graph: graph)
        XCTAssertEqual(links, ["Coralate"],
                       "only entities actually named in the text become links; Sarah isn't mentioned")
    }

    func testMentionedEntitiesMatchesByAliasButReturnsCanonicalName() {
        let graph = ContextGraphSnapshot(entities: [
            entity(.person, "Sarah Chen", aliases: ["Sarah"]),
        ])
        let links = NoteComposers.mentionedEntities(in: "quick sync with Sarah about the launch", graph: graph)
        XCTAssertEqual(links, ["Sarah Chen"],
                       "an alias match still links to the canonical display name, never the alias")
    }

    func testMentionedEntitiesRespectsWordBoundaries() {
        let graph = ContextGraphSnapshot(entities: [ entity(.term, "graph") ])
        XCTAssertTrue(NoteComposers.mentionedEntities(in: "the graph is live", graph: graph).contains("graph"),
                      "a whole-word occurrence matches")
        XCTAssertTrue(NoteComposers.mentionedEntities(in: "rebuild the graph.", graph: graph).contains("graph"),
                      "trailing punctuation is a boundary — still a match")
        XCTAssertTrue(NoteComposers.mentionedEntities(in: "graphene batteries", graph: graph).isEmpty,
                      "'graphene' contains 'graph' but is a different word — no match")
        XCTAssertTrue(NoteComposers.mentionedEntities(in: "a polygraph test", graph: graph).isEmpty,
                      "'polygraph' embeds 'graph' with no boundary — no match")
    }

    func testMentionedEntitiesSkipsCommitments() {
        let graph = ContextGraphSnapshot(entities: [
            entity(.commitment, "rotate the keys"),
            entity(.project, "Talkie"),
        ])
        let links = NoteComposers.mentionedEntities(in: "rotate the keys for Talkie", graph: graph)
        XCTAssertEqual(links, ["Talkie"],
                       "commitments are action items, not wikilink nodes — only the project links")
    }

    func testMentionedEntitiesIsCaseInsensitive() {
        let graph = ContextGraphSnapshot(entities: [ entity(.project, "Coralate") ])
        let links = NoteComposers.mentionedEntities(in: "the CORALATE demo", graph: graph)
        XCTAssertEqual(links, ["Coralate"],
                       "matching is case-insensitive; the canonical spelling is returned")
    }

    func testMentionedEntitiesDeduplicates() {
        let graph = ContextGraphSnapshot(entities: [ entity(.project, "Coralate") ])
        let links = NoteComposers.mentionedEntities(in: "Coralate and Coralate again", graph: graph)
        XCTAssertEqual(links, ["Coralate"],
                       "an entity mentioned twice is linked once")
    }

    // MARK: Note assembly

    func testDictationNoteCarriesAppAndBodyAndLinks() {
        let graph = ContextGraphSnapshot(entities: [ entity(.person, "Sarah Chen", aliases: ["Sarah"]) ])
        let target = TargetApp(bundleID: "com.apple.Notes", name: "Notes", category: .other)
        let note = NoteComposers.dictationNote(
            text: "ping Sarah about the keys", target: target,
            date: Date(timeIntervalSince1970: 1_700_000_000), graph: graph)
        XCTAssertEqual(note.kind, .dictation, "a note-this dictation is kind .dictation")
        XCTAssertEqual(note.frontMatter["app"], "Notes",
                       "the frontmost app is recorded as frontMatter[app]")
        XCTAssertEqual(note.links, ["Sarah Chen"],
                       "mentioned graph entities become links (canonical spelling)")
        XCTAssertTrue(note.bodyMarkdown.contains("## Note"),
                      "the body is a single '## Note' section")
        XCTAssertTrue(note.bodyMarkdown.contains("ping Sarah about the keys"),
                      "the body contains the note text verbatim")
        XCTAssertEqual(note.title, "ping Sarah about the keys",
                       "the title is the first ~8 words of the body")
    }

    func testDictationNoteOmitsAppForUnknownTarget() {
        let note = NoteComposers.dictationNote(
            text: "remember the keys", target: .unknown,
            date: Date(timeIntervalSince1970: 1_700_000_000), graph: .empty)
        XCTAssertNil(note.frontMatter["app"],
                     "the unknown target contributes no 'app' front-matter (so {app} templates collapse cleanly)")
    }

    func testDictationNoteFileNameUsesDatetimeNote() {
        let note = NoteComposers.dictationNote(
            text: "buy milk", target: .unknown,
            date: Date(timeIntervalSince1970: 1_700_000_000), graph: .empty)
        // 1_700_000_000 → 2023-11-14 in whatever the local zone is; assert the
        // stable, zone-independent suffix rather than the (local) date digits.
        XCTAssertTrue(note.suggestedFileName.hasSuffix("-note"),
                      "the dictation filename template is {datetime}-note; got \(note.suggestedFileName)")
        XCTAssertFalse(note.suggestedFileName.isEmpty, "a filename is always produced")
    }

    // NOTE: the Brief-save composer (`NoteComposers.briefNote`) and its two tests
    // were removed on 2026-07-04 — L2-a replaced Today's Brief with the adaptive
    // dashboard Scratchpad, so the Brief-save producer became dead code (D4
    // reconciliation). Nothing constructs a `.brief` note anymore.
}
