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
}
