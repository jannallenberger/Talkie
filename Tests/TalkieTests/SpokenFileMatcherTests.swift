import XCTest
@testable import Talkie

/// G10 — spoken repo-relative file paths for terminals. In a terminal, "exercise library
/// dot tsx" should insert `Sources/Views/ExerciseLibrary.tsx` (what a shell + Claude Code
/// want); an editor keeps the bare `ExerciseLibrary.tsx`. These tests pin the pure
/// `SpokenFileMatcher` surface (relative-path derivation, the `preferPaths` emit, trailing
/// punctuation carry, byte-identical non-matches) plus the store's per-root scoping and the
/// legacy-index migration that backfills paths.
final class SpokenFileMatcherTests: XCTestCase {

    // MARK: - relativePath derivation

    /// A file under the root strips to its repo-relative, forward-slashed path.
    func testRelativePathStripsRoot() {
        let root = URL(fileURLWithPath: "/Users/jann/Talkie")
        let abs = "/Users/jann/Talkie/Sources/Views/ExerciseLibrary.tsx"
        XCTAssertEqual(SpokenFileMatcher.relativePath(ofAbsolute: abs, underRoot: root),
                       "Sources/Views/ExerciseLibrary.tsx")
    }

    /// A file at the root's top level strips to just its basename.
    func testRelativePathTopLevelFileIsBasename() {
        let root = URL(fileURLWithPath: "/Users/jann/Talkie")
        XCTAssertEqual(
            SpokenFileMatcher.relativePath(ofAbsolute: "/Users/jann/Talkie/AppDelegate.swift", underRoot: root),
            "AppDelegate.swift")
    }

    /// A file NOT under the root yields nil (the caller then keeps the basename — never an
    /// absolute path leaks out), and a sibling dir sharing a prefix (`/a/Talkie2`) is not a
    /// false match for `/a/Talkie`.
    func testRelativePathRejectsOutsideRootAndPrefixSibling() {
        let root = URL(fileURLWithPath: "/Users/jann/Talkie")
        XCTAssertNil(SpokenFileMatcher.relativePath(ofAbsolute: "/etc/passwd", underRoot: root))
        XCTAssertNil(SpokenFileMatcher.relativePath(
            ofAbsolute: "/Users/jann/Talkie2/File.swift", underRoot: root),
            "a sibling dir sharing a name prefix must not match — the boundary is a slash")
        // The root path itself is not a file under the root.
        XCTAssertNil(SpokenFileMatcher.relativePath(ofAbsolute: "/Users/jann/Talkie", underRoot: root))
    }

    /// The `/private` ⇄ `/var` macOS divergence is collapsed: on a real temp dir, the
    /// enumerator hands back a `/private/var/…` file path while a root key is the `/var/…`
    /// standardized form — yet the relative derivation still strips correctly, because it
    /// standardizes BOTH sides (a naive prefix match would fail here). We use a REAL temp
    /// dir on purpose: `standardizedFileURL` only collapses `/private` for paths that
    /// actually resolve through the filesystem, which is exactly the production shape (the
    /// scanned files always exist).
    func testRelativePathStandardizesPrivateVarDivergence() throws {
        let repo = try makeTempDir("privvar")
        let sub = repo.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("App.swift")
        try Data().write(to: file)
        // Force the `/private/var/…` spelling the enumerator would produce for a temp dir.
        let privateAbs = "/private" + file.path
        // Root key is the standardized (`/var/…`) form the store uses.
        let rootKey = URL(fileURLWithPath: repo.standardizedFileURL.path)
        XCTAssertEqual(SpokenFileMatcher.relativePath(ofAbsolute: privateAbs, underRoot: rootKey),
                       "Sources/App.swift",
                       "a /private/var file path must strip against a /var root key")
    }

    // MARK: - preferPaths emit (terminal → path, editor → basename)

    /// A snapshot with a pathMap: `preferPaths` emits the relative path, default emits the
    /// basename — the G10 headline (terminal vs editor).
    func testPreferPathsEmitsRelativePathElseBasename() {
        let snap = ProjectIndexSnapshot(
            keyMap: ["exercise library tsx": "ExerciseLibrary.tsx",
                     "exercise library dot tsx": "ExerciseLibrary.tsx"],
            maxKeyTokens: 4,
            biasPhrases: [],
            pathMap: ["ExerciseLibrary.tsx": "Sources/Views/ExerciseLibrary.tsx"])

        let (editor, e) = SpokenFileMatcher.format("open exercise library dot tsx now", snapshot: snap)
        XCTAssertEqual(e, 1)
        XCTAssertTrue(editor.contains("ExerciseLibrary.tsx"), editor)
        XCTAssertFalse(editor.contains("Sources/Views"), "editor (default) keeps the bare basename: \(editor)")

        let (term, t) = SpokenFileMatcher.format("open exercise library dot tsx now", snapshot: snap,
                                                 preferPaths: true)
        XCTAssertEqual(t, 1)
        XCTAssertTrue(term.contains("Sources/Views/ExerciseLibrary.tsx"),
                      "terminal (preferPaths) inserts the repo-relative path: \(term)")
    }

    /// `preferPaths` with a match that has NO pathMap entry falls back to the basename —
    /// paths are an enrichment, never a way to drop a file we can't place.
    func testPreferPathsFallsBackToBasenameWhenNoPath() {
        let snap = ProjectIndexSnapshot(
            keyMap: ["app swift": "App.swift", "app dot swift": "App.swift"],
            maxKeyTokens: 3,
            biasPhrases: [],
            pathMap: [:])  // no relative path known for this basename
        let (out, n) = SpokenFileMatcher.format("edit app dot swift", snapshot: snap, preferPaths: true)
        XCTAssertEqual(n, 1)
        XCTAssertTrue(out.contains("App.swift"), "with no path, preferPaths keeps the basename: \(out)")
    }

    // MARK: - trailing punctuation carry (under preferPaths)

    /// Trailing punctuation on the spoken filename carries onto the emitted RELATIVE path,
    /// exactly as it carries onto a basename — so "…dot tsx." → "Sources/…/File.tsx.".
    func testPreferPathsCarriesTrailingPunctuation() {
        let snap = ProjectIndexSnapshot(
            keyMap: ["exercise library dot tsx": "ExerciseLibrary.tsx",
                     "exercise library tsx": "ExerciseLibrary.tsx"],
            maxKeyTokens: 4,
            biasPhrases: [],
            pathMap: ["ExerciseLibrary.tsx": "Sources/Views/ExerciseLibrary.tsx"])
        // Trailing comma then a period ending the sentence.
        let (out, n) = SpokenFileMatcher.format("check exercise library dot tsx, please.",
                                                snapshot: snap, preferPaths: true)
        XCTAssertEqual(n, 1)
        XCTAssertTrue(out.contains("Sources/Views/ExerciseLibrary.tsx,"),
                      "the trailing comma must ride on the relative path: \(out)")
        XCTAssertTrue(out.hasSuffix("please."), out)
    }

    // MARK: - byte-identical non-matches (under preferPaths too)

    /// Text with no filename match round-trips BYTE-IDENTICALLY, whether or not
    /// `preferPaths` is set — the path feature must never perturb ordinary prose.
    /// (Interior-dot tokens like "3.30" are covered by `testInteriorDotNonMatchRoundTrips`.)
    func testNonMatchRoundTripsByteIdenticalUnderPreferPaths() {
        let snap = ProjectIndexSnapshot(
            keyMap: ["exercise library dot tsx": "ExerciseLibrary.tsx"],
            maxKeyTokens: 4,
            biasPhrases: [],
            pathMap: ["ExerciseLibrary.tsx": "Sources/Views/ExerciseLibrary.tsx"])
        let prose = "let's meet later and talk about the plan, then head out to lunch."
        let (plain, p) = SpokenFileMatcher.format(prose, snapshot: snap)
        let (paths, q) = SpokenFileMatcher.format(prose, snapshot: snap, preferPaths: true)
        XCTAssertEqual(p, 0); XCTAssertEqual(q, 0)
        XCTAssertEqual(plain, prose, "non-match must round-trip unchanged (default): \(plain)")
        XCTAssertEqual(paths, prose, "non-match must round-trip unchanged (preferPaths): \(paths)")
    }

    /// A `word.word` token that isn't a project file must come back exactly as spoken.
    /// The tokenizer splits it into `word · dot · word` to find filenames, and used to
    /// glue a non-match back with the literal WORD "dot" — "iOS 26.5" was inserted as
    /// "iOS 26 dot 5" and "CLAUDE.md"-like mishearings as "iCloud dot m".
    func testInteriorDotNonMatchRoundTrips() {
        let snap = ProjectIndexSnapshot(
            keyMap: ["exercise library dot tsx": "ExerciseLibrary.tsx"],
            maxKeyTokens: 4,
            biasPhrases: [],
            pathMap: [:])
        for prose in [
            "mit iOS 26.5 hat Apple das Modell verbessert.",
            "Schau dir vorher noch iCloud.m an, damit du weißt.",
            "let's meet at 3.30 and grab file.unknownext on the way.",
            "Version (2.0.1), dann v1.2!",
        ] {
            let (out, n) = SpokenFileMatcher.format(prose, snapshot: snap)
            XCTAssertEqual(n, 0)
            XCTAssertEqual(out, prose, "non-match must round-trip unchanged")
        }
    }

    /// A real filename still snaps when the recognizer already wrote the dot, and the
    /// surrounding interior-dot words are left intact.
    func testInteriorDotMatchStillSnapsBesideUntouchedDots() {
        let snap = ProjectIndexSnapshot(
            keyMap: ["exercise library dot tsx": "ExerciseLibrary.tsx"],
            maxKeyTokens: 4,
            biasPhrases: [],
            pathMap: [:])
        let (out, n) = SpokenFileMatcher.format("in iOS 26.5 open exercise library.tsx, then 3.30", snapshot: snap)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(out, "in iOS 26.5 open ExerciseLibrary.tsx, then 3.30")
    }

    /// The core G10 invariant on the NON-match path: whatever the (pre-existing) tokenizer
    /// does to a string with no filename hit, `preferPaths` produces the IDENTICAL output as
    /// the default — turning paths on can only ever change a MATCH, never a non-match. Uses
    /// the "3.30" interior-dot case precisely because it exercises the tokenizer's rewrite,
    /// proving preferPaths rides alongside it without adding any divergence.
    func testPreferPathsNeverDivergesFromDefaultOnNonMatch() {
        let snap = ProjectIndexSnapshot(
            keyMap: ["exercise library dot tsx": "ExerciseLibrary.tsx"],
            maxKeyTokens: 4,
            biasPhrases: [],
            pathMap: ["ExerciseLibrary.tsx": "Sources/Views/ExerciseLibrary.tsx"])
        let prose = "let's meet at 3.30 and grab file.unknownext on the way."
        let (plain, _) = SpokenFileMatcher.format(prose, snapshot: snap)
        let (paths, _) = SpokenFileMatcher.format(prose, snapshot: snap, preferPaths: true)
        XCTAssertEqual(paths, plain,
                       "preferPaths must match the default output exactly when nothing matches")
    }

    /// An empty snapshot (no index) is a no-op in both modes — same as before G10.
    func testEmptySnapshotIsNoOp() {
        let (out, n) = SpokenFileMatcher.format("exercise library dot tsx", snapshot: .empty,
                                                preferPaths: true)
        XCTAssertEqual(n, 0)
        XCTAssertEqual(out, "exercise library dot tsx")
    }

    // MARK: - buildSnapshot wires pathMap by canonical basename

    /// `buildSnapshot` keys `pathMap` on the canonical basename `keyMap` emits (matched by
    /// lowercased basename against the supplied relative-path map), and leaves files with no
    /// path out of `pathMap` (so they fall back to the basename).
    func testBuildSnapshotPopulatesPathMapByCanonicalBasename() {
        let snap = SpokenFileMatcher.buildSnapshot(
            files: ["ExerciseLibrary.tsx", "Standalone.swift"],
            symbols: [],
            filePaths: ["exerciselibrary.tsx": "Sources/Views/ExerciseLibrary.tsx"])  // only one has a path
        XCTAssertEqual(snap.pathMap["ExerciseLibrary.tsx"], "Sources/Views/ExerciseLibrary.tsx")
        XCTAssertNil(snap.pathMap["Standalone.swift"],
                     "a file with no supplied relative path gets no pathMap entry (basename fallback)")
        // The bias phrases must NOT contain the path — paths are never fed to the recognizer.
        XCTAssertFalse(snap.biasPhrases.contains { $0.contains("Sources/Views") },
                       "relative paths must never leak into bias phrases: \(snap.biasPhrases)")
    }

    // MARK: - Store: per-root scoping + terminal path, editor basename

    /// Naming a UI element ("the settings view") must not tag a file just because
    /// one is called SettingsView — a file snaps only when its extension is spoken,
    /// and a same-named file of another type is never picked up.
    @MainActor
    func testBareBaseNameNeverTagsAFile() async throws {
        let repo = try makeTempDir("repo")
        try touch("SettingsView.swift", in: repo)
        try touch("user_profile.py", in: repo)

        let store = ProjectIndexStore(fileURL: try indexURL())
        store.addFolders([repo])
        try await waitUntil { !store.isScanning && store.fileCount >= 2 }
        let snap = try XCTUnwrap(store.snapshot(for: repo))

        for prose in ["Mach die settings view etwas heller.",
                      "Im user profile fehlt der Avatar.",
                      "the settings view needs a darker header"] {
            let (out, n) = SpokenFileMatcher.format(prose, snapshot: snap)
            XCTAssertEqual(n, 0, out)
            XCTAssertEqual(out, prose)
        }
        XCTAssertEqual(SpokenFileMatcher.format("open settings view dot swift", snapshot: snap).0,
                       "open SettingsView.swift")
        XCTAssertEqual(SpokenFileMatcher.format("check user profile dot py", snapshot: snap).0,
                       "check user_profile.py")
    }

    /// End-to-end through the store: the Talkie-shaped repo indexes, and dictating
    /// "settings view dot swift" yields the repo-relative path with `preferPaths` (a
    /// terminal) and the bare basename without it (an editor).
    @MainActor
    func testStoreScopedSnapshotTerminalPathEditorBasename() async throws {
        let repo = try makeTempDir("repo")
        let viewsDir = repo.appendingPathComponent("Sources/Talkie")
        try FileManager.default.createDirectory(at: viewsDir, withIntermediateDirectories: true)
        try touch("SettingsView.swift", in: viewsDir)

        let store = ProjectIndexStore(fileURL: try indexURL())
        store.addFolders([repo])
        try await waitUntil { !store.isScanning && store.fileCount >= 1 }

        let snap = try XCTUnwrap(store.snapshot(for: repo), "the pinned root should have a scoped snapshot")

        // Terminal → relative path.
        let (term, tReps) = SpokenFileMatcher.format("settings view dot swift", snapshot: snap,
                                                     preferPaths: true)
        XCTAssertEqual(tReps, 1, term)
        XCTAssertEqual(term, "Sources/Talkie/SettingsView.swift",
                       "a terminal inserts the repo-relative path: \(term)")

        // Editor → bare basename.
        let (editor, eReps) = SpokenFileMatcher.format("settings view dot swift", snapshot: snap)
        XCTAssertEqual(eReps, 1, editor)
        XCTAssertEqual(editor, "SettingsView.swift", "an editor inserts the bare basename: \(editor)")
    }

    // MARK: - Store: multi-root basename collision — first root wins

    /// Two pinned checkouts each hold `Config.swift` at different depths. The MERGED
    /// fallback snapshot's pathMap must resolve the colliding basename to the FIRST pinned
    /// root's relative path (first-folder-wins, the rule used everywhere else in the index).
    @MainActor
    func testMergedPathMapFirstRootWinsOnCollision() async throws {
        let a = try makeTempDir("collideA")
        let b = try makeTempDir("collideB")
        // Same basename, DIFFERENT relative depth in each checkout.
        let aDir = a.appendingPathComponent("Alpha")
        let bDir = b.appendingPathComponent("Beta/Nested")
        try FileManager.default.createDirectory(at: aDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bDir, withIntermediateDirectories: true)
        try touch("Config.swift", in: aDir)
        try touch("Config.swift", in: bDir)

        let store = ProjectIndexStore(fileURL: try indexURL())
        // Pin A first, then B — so A wins a colliding basename in the merged view.
        store.addFolders([a, b])
        try await waitUntil { !store.isScanning && store.fileCount >= 1 }

        // The merged snapshot (used when the active root is unknown) must map the collided
        // basename to A's relative path — first root wins.
        let (out, reps) = SpokenFileMatcher.format("config dot swift", snapshot: store.snapshot,
                                                   preferPaths: true)
        XCTAssertEqual(reps, 1, out)
        XCTAssertEqual(out, "Alpha/Config.swift",
                       "the first pinned root must win the colliding basename in the merged pathMap: \(out)")

        // And each scoped snapshot still resolves to its OWN copy's relative path.
        let (aOut, _) = SpokenFileMatcher.format("config dot swift",
                                                 snapshot: try XCTUnwrap(store.snapshot(for: a)),
                                                 preferPaths: true)
        XCTAssertEqual(aOut, "Alpha/Config.swift", aOut)
        let (bOut, _) = SpokenFileMatcher.format("config dot swift",
                                                 snapshot: try XCTUnwrap(store.snapshot(for: b)),
                                                 preferPaths: true)
        XCTAssertEqual(bOut, "Beta/Nested/Config.swift",
                       "root B's scoped snapshot resolves to B's own deeper relative path: \(bOut)")
    }

    // MARK: - Store: legacy index migration backfills paths

    /// A pre-A10 flat `project_index.json` (merged `filePaths`, no `roots` map) loads,
    /// snaps basenames immediately (no path yet), then AUTO-RESCANS ONCE so the per-root
    /// buckets — and thus the repo-relative paths — get backfilled. Before the rescan
    /// completes, `preferPaths` falls back to the basename; it never crashes.
    @MainActor
    func testLegacyFlatIndexMigratesAndBackfillsPaths() async throws {
        // A real on-disk repo the legacy folderPaths will point at, so the migration rescan
        // has something to walk.
        let repo = try makeTempDir("legacyRepo")
        let srcDir = repo.appendingPathComponent("Sources/Views")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try touch("ExerciseLibrary.tsx", in: srcDir)

        // Hand-write a legacy flat index (no `roots`) pointing at that repo. The legacy
        // filePaths carry an ABSOLUTE path; there's no per-root structure to derive a
        // relative path from until the migration rescan runs.
        let repoPath = repo.standardizedFileURL.path
        let legacyJSON = """
        {
          "folderPaths": ["\(repoPath)"],
          "scannedAtUnix": 1720000000,
          "files": ["ExerciseLibrary.tsx"],
          "symbols": ["ExerciseLibrary"],
          "docTerms": [],
          "filePaths": {"exerciselibrary.tsx": "\(repoPath)/Sources/Views/ExerciseLibrary.tsx"}
        }
        """
        let url = try indexURL()
        try legacyJSON.data(using: .utf8)!.write(to: url)

        let store = ProjectIndexStore(fileURL: url)
        // Immediately after load (before/around the migration rescan): matching still works
        // from the legacy blob, and preferPaths never crashes — it falls back to basename
        // until paths are backfilled.
        let (early, earlyReps) = SpokenFileMatcher.format("exercise library dot tsx",
                                                          snapshot: store.snapshot, preferPaths: true)
        XCTAssertEqual(earlyReps, 1, "a legacy index must still snap basenames pre-migration: \(early)")
        XCTAssertTrue(early.contains("ExerciseLibrary.tsx"), early)

        // The one-shot migration rescan repopulates per-root buckets → relative paths appear.
        try await waitUntil { store.snapshot.pathMap["ExerciseLibrary.tsx"] != nil }

        let (out, reps) = SpokenFileMatcher.format("exercise library dot tsx",
                                                   snapshot: store.snapshot, preferPaths: true)
        XCTAssertEqual(reps, 1, out)
        XCTAssertEqual(out, "Sources/Views/ExerciseLibrary.tsx",
                       "after the migration rescan a terminal gets the repo-relative path: \(out)")
    }

    // MARK: - Helpers

    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for r in tempRoots { try? FileManager.default.removeItem(at: r) }
        tempRoots = []
    }

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-matcher-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        return dir
    }

    private func indexURL() throws -> URL {
        let dir = try makeTempDir("index")
        return dir.appendingPathComponent("project_index.json")
    }

    private func touch(_ name: String, in dir: URL) throws {
        try Data().write(to: dir.appendingPathComponent(name))
    }

    /// Poll a main-actor condition with a timeout (the background scan is async).
    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
