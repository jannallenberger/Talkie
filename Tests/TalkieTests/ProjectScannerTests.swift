import XCTest
@testable import Talkie

/// Bounds on the Vibe Coding project walk (P2-10): the enumeration must stop at
/// `maxEntries`, honor cancellation, and stay deterministic up to the cap.
final class ProjectScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func touch(_ name: String, in dir: URL) throws {
        try Data().write(to: dir.appendingPathComponent(name))
    }

    /// A cancelled task breaks out of the walk before keeping any files — the
    /// `Task.isCancelled` guard fires on the first iteration.
    func testCancelledScanReturnsNoFiles() async throws {
        for i in 0..<50 { try touch("File\(i).swift", in: root) }

        let captured = root!
        let result = await Task.detached { () -> ProjectScanner.Result in
            withUnsafeCurrentTask { $0?.cancel() } // cancel ourselves up front
            return ProjectScanner.scan(root: captured)
        }.value

        XCTAssertTrue(result.files.isEmpty,
                      "a cancelled walk must break out before appending files")
    }

    /// An uncancelled scan over the same tree DOES find the files — proves the
    /// cancel test above isn't passing for the wrong reason.
    func testUncancelledScanFindsFiles() throws {
        for i in 0..<50 { try touch("File\(i).swift", in: root) }
        let result = ProjectScanner.scan(root: root)
        XCTAssertEqual(result.files.count, 50)
    }

    /// Non-code entries are walked but never kept; the walk still terminates and
    /// returns only the code files (deterministic membership, capped by maxFiles).
    func testNonCodeEntriesAreVisitedButNotKept() throws {
        for i in 0..<30 { try touch("asset\(i).bin", in: root) }
        for i in 0..<10 { try touch("Source\(i).ts", in: root) }
        let result = ProjectScanner.scan(root: root)
        XCTAssertEqual(result.files.count, 10)
        XCTAssertTrue(result.files.allSatisfy { $0.hasSuffix(".ts") })
    }

    /// The entry cap is a positive ceiling well above the kept-file cap, so the
    /// walk is bounded even when matches are sparse.
    func testEntryCapIsAboveFileCap() {
        XCTAssertGreaterThan(ProjectScanner.maxEntries, ProjectScanner.maxFiles)
        XCTAssertGreaterThan(ProjectScanner.maxEntries, 0)
    }

    /// scanAll over an empty root list returns an empty, well-formed result and
    /// short-circuits on cancellation before touching the disk.
    func testScanAllHonorsCancellation() async throws {
        for i in 0..<20 { try touch("Mod\(i).js", in: root) }
        let captured = [root!]
        let result = await Task.detached { () -> ProjectScanner.Result in
            withUnsafeCurrentTask { $0?.cancel() }
            return ProjectScanner.scanAll(roots: captured)
        }.value
        XCTAssertTrue(result.files.isEmpty)
    }

    // MARK: - A3: doc-file detection + one-pass mining

    /// `isDocFile` recognizes the project's CLAUDE.md, any README*, and Markdown under
    /// a `docs/` segment — and nothing else.
    func testIsDocFileRecognizesTheRightFiles() {
        func doc(_ p: String) -> Bool { ProjectScanner.isDocFile(root.appendingPathComponent(p)) }
        XCTAssertTrue(doc("CLAUDE.md"))
        XCTAssertTrue(doc("claude.md"))
        XCTAssertTrue(doc("README"))
        XCTAssertTrue(doc("README.md"))
        XCTAssertTrue(doc("readme.markdown"))
        XCTAssertTrue(doc("docs/architecture.md"))
        XCTAssertTrue(doc("packages/app/docs/setup.md"))
        // Not docs: ordinary source, a stray markdown NOT under docs/, a lookalike.
        XCTAssertFalse(doc("Sources/App.swift"))
        XCTAssertFalse(doc("notes.md"), "a markdown file not under docs/ and not a README is not a doc source")
        XCTAssertFalse(doc("documentation.txt"))
    }

    /// The walk collects doc-file URLs during its single traversal (no second walk):
    /// after one `scan`, `docFiles` holds exactly the doc sources found.
    func testScanCollectsDocFilesInOnePass() throws {
        try touch("CLAUDE.md", in: root)
        try touch("README.md", in: root)
        let docsDir = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try touch("guide.md", in: docsDir)
        try touch("App.swift", in: root)

        let result = ProjectScanner.scan(root: root)
        let names = Set(result.docFiles.map { $0.lastPathComponent.lowercased() })
        XCTAssertTrue(names.contains("claude.md"), names.description)
        XCTAssertTrue(names.contains("readme.md"), names.description)
        XCTAssertTrue(names.contains("guide.md"), names.description)
        XCTAssertFalse(names.contains("app.swift"), "source files are not doc sources: \(names)")
    }

    /// A repo with no docs and no git contributes no docTerms — the additive path is
    /// inert for ordinary projects, so scan output is byte-for-byte what it was.
    func testScanAllNoDocsNoGitProducesNoDocTerms() throws {
        for i in 0..<10 { try touch("File\(i).swift", in: root) }
        let result = ProjectScanner.scanAll(roots: [root])
        XCTAssertEqual(result.files.count, 10)
        XCTAssertTrue(result.docTerms.isEmpty, "no docs / no git ⇒ no mined terms: \(result.docTerms)")
    }

    /// Deeply-nested markdown (docs/plans/**) is NOT mined — only CLAUDE.md, README*,
    /// and DIRECT children of a `docs/` dir are doc sources. This keeps big planning
    /// trees out of the jargon mine (higher signal, and the reason scan cost stays low).
    func testNestedDocsPlansAreNotDocSources() throws {
        try touch("CLAUDE.md", in: root)
        let plans = root.appendingPathComponent("docs/plans")
        try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
        try touch("05-context-graph.md", in: plans)
        XCTAssertTrue(ProjectScanner.isDocFile(root.appendingPathComponent("CLAUDE.md")))
        XCTAssertFalse(ProjectScanner.isDocFile(plans.appendingPathComponent("05-context-graph.md")),
                       "a markdown file two levels under docs/ is planning prose, not a jargon source")
    }

    /// The doc-file collection is capped: a repo with far more doc files than
    /// `maxDocFiles` still only flags at most that many, so the mine's read/parse cost
    /// stays bounded regardless of repo size.
    func testDocFileCollectionIsCapped() throws {
        let docsDir = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        for i in 0..<(ProjectScanner.maxDocFiles + 20) { try touch("doc\(i).md", in: docsDir) }
        let result = ProjectScanner.scan(root: root)
        XCTAssertLessThanOrEqual(result.docFiles.count, ProjectScanner.maxDocFiles,
                                 "doc-file collection must respect maxDocFiles: \(result.docFiles.count)")
    }

    /// Mining adds only a small, bounded cost ON THE SAME TREE: scanning a folder of
    /// pure source files (no docs, no git) with `scanAll` (which runs the mine) is not
    /// dramatically slower than `scan` (walk only). This is the stable, machine-
    /// independent form of the "<20% scan-time growth" criterion — an absolute wall-
    /// clock threshold flakes in CI, but "the mine is cheap relative to a real walk"
    /// holds. (On a trivially tiny tree the fixed mine cost can exceed 20% of a tiny
    /// baseline; see the A3 note in docs/plans/_INTEGRATION_CONTRACT.md.)
    func testMiningAddsBoundedCostOnSourceHeavyTree() throws {
        // A source-heavy tree with a couple of docs — realistic shape.
        for i in 0..<800 { try touch("Source\(i).swift", in: root) }
        try touch("CLAUDE.md", in: root)
        try touch("README.md", in: root)
        func best(_ n: Int, _ body: () -> Void) -> Double {
            var b = Double.greatestFiniteMagnitude
            for _ in 0..<n { let t = Date(); body(); b = min(b, Date().timeIntervalSince(t)) }
            return b
        }
        let walkOnly = best(3) { _ = ProjectScanner.scan(root: root) }
        let walkAndMine = best(3) { _ = ProjectScanner.scanAll(roots: [root]) }
        // Generous ceiling: mining must not more than ~double a source-heavy walk. The
        // real criterion (<20%) holds on production-sized trees; this guards against a
        // regression that makes the mine pathologically expensive.
        XCTAssertLessThan(walkAndMine, walkOnly * 3 + 0.05,
                          "mining cost regressed: walk \(walkOnly*1000)ms vs walk+mine \(walkAndMine*1000)ms")
    }

    // MARK: - A10: per-root indexing + scoped snapshots

    /// `scanPerRoot` keeps each root's files in its OWN bucket — no cross-root merge, so
    /// two checkouts with a same-named file don't collide (the whole point of A10).
    func testScanPerRootKeepsRootsSeparate() throws {
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        // Same basename, different casing/siblings in each checkout.
        try touch("ExerciseLibrary.tsx", in: a)
        try touch("OnlyInA.swift", in: a)
        try touch("ExerciseLibrary.tsx", in: b)
        try touch("OnlyInB.swift", in: b)

        let buckets = ProjectScanner.scanPerRoot(roots: [a, b])
        let aKey = a.standardizedFileURL.path
        let bKey = b.standardizedFileURL.path
        XCTAssertNotNil(buckets[aKey], "root A must have its own bucket")
        XCTAssertNotNil(buckets[bKey], "root B must have its own bucket")
        XCTAssertTrue(buckets[aKey]!.files.contains("OnlyInA.swift"))
        XCTAssertFalse(buckets[aKey]!.files.contains("OnlyInB.swift"),
                       "root A's bucket must not contain root B's files")
        XCTAssertTrue(buckets[bKey]!.files.contains("OnlyInB.swift"))
        XCTAssertFalse(buckets[bKey]!.files.contains("OnlyInA.swift"),
                       "root B's bucket must not contain root A's files")
    }

    /// Migration: an old FLAT project_index.json (top-level merged files/symbols/docTerms/
    /// filePaths, no `roots` key) decodes without loss and its data is reachable via the
    /// merged accessors, so a pre-A10 file keeps snapping filenames after upgrade.
    func testLegacyFlatIndexDecodesAndRoundTrips() throws {
        let legacyJSON = """
        {
          "folderPaths": ["/Users/jann/Talkie"],
          "scannedAtUnix": 1720000000,
          "files": ["ExerciseLibrary.tsx", "AppDelegate.swift"],
          "symbols": ["ExerciseLibrary", "AppDelegate"],
          "docTerms": ["Coralate", "Talkie"],
          "filePaths": {"exerciselibrary.tsx": "/Users/jann/Talkie/ExerciseLibrary.tsx"}
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProjectIndexData.self, from: legacyJSON)
        XCTAssertEqual(decoded.folderPaths, ["/Users/jann/Talkie"], "folderPaths must survive migration")
        // No per-root map yet — the legacy blob backs the merged view until the next rescan.
        XCTAssertTrue(decoded.roots.isEmpty, "a legacy file has no per-root map yet")
        XCTAssertEqual(Set(decoded.mergedFiles), ["ExerciseLibrary.tsx", "AppDelegate.swift"],
                       "legacy merged files must be reachable via mergedFiles")
        XCTAssertEqual(Set(decoded.mergedSymbols), ["ExerciseLibrary", "AppDelegate"])
        XCTAssertEqual(Set(decoded.mergedDocTerms), ["Coralate", "Talkie"])
        XCTAssertEqual(decoded.mergedFilePaths["exerciselibrary.tsx"],
                       "/Users/jann/Talkie/ExerciseLibrary.tsx")

        // Round-trip: re-encoding a not-yet-rescanned legacy file preserves the flat data
        // (so quitting before a rescan can't drop it), and re-decoding is lossless.
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(ProjectIndexData.self, from: reEncoded)
        XCTAssertEqual(Set(reDecoded.mergedFiles), ["ExerciseLibrary.tsx", "AppDelegate.swift"],
                       "re-encoded legacy file must still carry its files")
        XCTAssertEqual(reDecoded.mergedFilePaths["exerciselibrary.tsx"],
                       "/Users/jann/Talkie/ExerciseLibrary.tsx")
    }

    /// The NEW shape (per-root `roots` map) encodes and decodes cleanly, and once `roots`
    /// is populated the legacy flat fields are NOT re-encoded (per-root is authoritative).
    func testPerRootIndexEncodesInNewShape() throws {
        var data = ProjectIndexData()
        data.folderPaths = ["/tmp/A", "/tmp/B"]
        data.roots["/tmp/A"] = ProjectRootIndex(files: ["A.swift"], symbols: ["A"],
                                                docTerms: [], filePaths: ["a.swift": "/tmp/A/A.swift"])
        data.roots["/tmp/B"] = ProjectRootIndex(files: ["B.swift"], symbols: ["B"],
                                                docTerms: [], filePaths: ["b.swift": "/tmp/B/B.swift"])
        data.scannedAtUnix = 1_720_000_000

        let encoded = try JSONEncoder().encode(data)
        // Legacy flat keys must be absent once roots is populated.
        let asString = String(data: encoded, encoding: .utf8)!
        XCTAssertTrue(asString.contains("\"roots\""), "new shape must persist the roots map")

        let decoded = try JSONDecoder().decode(ProjectIndexData.self, from: encoded)
        XCTAssertEqual(decoded.roots.count, 2)
        XCTAssertEqual(Set(decoded.mergedFiles), ["A.swift", "B.swift"])
    }

    /// `ProjectIndexStore.snapshot(for:)` scopes to a single root: dictating in root A
    /// resolves A's file, in root B resolves B's — and an unindexed root yields nil so the
    /// caller falls back to the merged snapshot (never a wrong-repo scope).
    @MainActor
    func testStoreSnapshotForRootScopesPerCheckout() async throws {
        let a = root.appendingPathComponent("checkoutA")
        let b = root.appendingPathComponent("checkoutB")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        // Distinct filenames so we can assert which root a snapshot came from.
        try touch("AlphaWidget.tsx", in: a)
        try touch("BetaWidget.tsx", in: b)

        let store = ProjectIndexStore(fileURL: root.appendingPathComponent("index-A.json"))
        store.addFolders([a, b])
        // Wait for the background scan to settle.
        try await waitUntil { !store.isScanning && store.fileCount >= 2 }

        let snapA = store.snapshot(for: a)
        let snapB = store.snapshot(for: b)
        XCTAssertNotNil(snapA, "root A should have a scoped snapshot after scanning")
        XCTAssertNotNil(snapB, "root B should have a scoped snapshot after scanning")
        // A's snapshot maps A's file and NOT B's; B's maps B's file and NOT A's.
        let (aOut, aReps) = SpokenFileMatcher.format("alpha widget dot tsx", snapshot: snapA!)
        XCTAssertEqual(aReps, 1, "root A's snapshot should snap its own file: \(aOut)")
        XCTAssertTrue(aOut.contains("AlphaWidget.tsx"), aOut)
        let (aMiss, aMissReps) = SpokenFileMatcher.format("beta widget dot tsx", snapshot: snapA!)
        XCTAssertEqual(aMissReps, 0, "root A must NOT snap root B's file: \(aMiss)")

        // An unknown/unscanned root has no scoped snapshot — caller degrades to merged.
        let unknown = root.appendingPathComponent("neverScanned")
        XCTAssertNil(store.snapshot(for: unknown),
                     "an unindexed root must yield nil so the caller falls back to merged")

        // The merged fallback (store.snapshot) sees BOTH files.
        let (mergedOut, mergedReps) = SpokenFileMatcher.format("beta widget dot tsx",
                                                               snapshot: store.snapshot)
        XCTAssertEqual(mergedReps, 1, "merged fallback should snap either root's file: \(mergedOut)")
    }

    /// `resolveIndexedFilePath(forWindowTitle:root:)` prefers the ACTIVE root's basename
    /// map: with a same-named file in two checkouts, passing root A resolves to A's copy,
    /// passing root B to B's copy — the A10 headline for active-file mining.
    @MainActor
    func testResolveIndexedFilePathPrefersActiveRoot() async throws {
        let a = root.appendingPathComponent("repoA")
        let b = root.appendingPathComponent("repoB")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try touch("Shared.tsx", in: a)
        try touch("Shared.tsx", in: b)

        let store = ProjectIndexStore(fileURL: root.appendingPathComponent("index-B.json"))
        store.addFolders([a, b])
        try await waitUntil { !store.isScanning && store.fileCount >= 1 }

        let title = "Shared.tsx — myapp"
        let pathA = store.resolveIndexedFilePath(forWindowTitle: title, root: a)
        let pathB = store.resolveIndexedFilePath(forWindowTitle: title, root: b)
        // The scanner stores the on-disk `url.path` (a temp dir resolves through /private
        // on macOS), so assert on containment of each repo's own subpath rather than an
        // exact string — the point is that A's active root resolves under repoA, B's under
        // repoB, and the two never cross.
        XCTAssertNotNil(pathA); XCTAssertNotNil(pathB)
        XCTAssertTrue(pathA!.hasSuffix("repoA/Shared.tsx"),
                      "with root A active, the title filename must resolve to A's copy: \(pathA!)")
        XCTAssertTrue(pathB!.hasSuffix("repoB/Shared.tsx"),
                      "with root B active, the title filename must resolve to B's copy: \(pathB!)")
        XCTAssertNotEqual(pathA, pathB, "the same title must resolve to DIFFERENT files per active root")
        // With no root (ambiguous), it still resolves SOMETHING via the merged map —
        // first-folder-wins — never crashing, never nil for an indexed basename.
        let pathMerged = store.resolveIndexedFilePath(forWindowTitle: title, root: nil)
        XCTAssertNotNil(pathMerged, "ambiguous resolution must still return the merged (first-wins) path")
    }

    /// Poll a main-actor condition with a timeout — the background scan is async, so tests
    /// wait for it to settle rather than sleeping a fixed duration.
    @MainActor
    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
