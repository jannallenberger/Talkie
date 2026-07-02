import XCTest
@testable import Talkie

/// Tests for repo-aware jargon mining (A3): Markdown term extraction, git plumbing
/// parsing over fixture repos (normal `.git` dir, worktree `gitdir:` file, packed-refs,
/// missing git), the corrector-term safety filter, and — the package's GATE — a
/// false-positive prose corpus that must still produce ZERO niche fixes when a real
/// repo's mined terms are loaded into `NicheCorrector`.
final class RepoTermMinerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repominer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ text: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: url)
    }

    // MARK: - Markdown mining

    /// Backticked code spans are the highest-signal source: the literal terms an
    /// author asked us to spell right, admitted even when they look prose-ish
    /// (lowercase filename, hyphenated slug).
    func testMineMarkdownExtractsCodeSpans() {
        let md = """
        # Talkie
        Run `talkie-bench` to benchmark. Config lives in `CLAUDE.md`.
        The `ProjectIndexStore` owns the scan.
        """
        let terms = RepoTermMiner.mineMarkdown(md)
        XCTAssertTrue(terms.contains("talkie-bench"), "hyphenated slug in a code span should be admitted whole: \(terms)")
        XCTAssertTrue(terms.contains("CLAUDE.md"), "filename in a code span should be admitted: \(terms)")
        XCTAssertTrue(terms.contains("ProjectIndexStore"), "CamelCase identifier should be admitted: \(terms)")
    }

    /// Identifier-shaped tokens (CamelCase, snake_case, filename-ish) in running prose
    /// are extracted; ordinary words are not.
    func testMineMarkdownExtractsIdentifierShapes() {
        let md = "We wire the context_graph and the NicheCorrector into AppDelegate.swift during launch."
        let terms = RepoTermMiner.mineMarkdown(md)
        XCTAssertTrue(terms.contains("context_graph"), terms.description)
        XCTAssertTrue(terms.contains("NicheCorrector"), terms.description)
        XCTAssertTrue(terms.contains("AppDelegate.swift"), terms.description)
        XCTAssertFalse(terms.contains("during"), "plain prose must not be mined: \(terms)")
        XCTAssertFalse(terms.contains("launch"), "plain prose must not be mined: \(terms)")
    }

    /// A Capitalized proper noun is admitted from a BACKTICK SPAN (author intent), but
    /// a bare capitalized word in running PROSE is not — prose is full of Capitalized
    /// sentence-starters ("This", "Getting", "Runtime") that are the dominant false-
    /// positive source on real docs, so only spans admit bare proper nouns.
    func testMineMarkdownProperNounsFromSpansNotProse() {
        // Backticked → admitted.
        let spanned = RepoTermMiner.mineMarkdown("Deploy `Kubernetes` and use `Coralate`.")
        XCTAssertTrue(spanned.contains("Kubernetes"), spanned.description)
        XCTAssertTrue(spanned.contains("Coralate"), spanned.description)
        // Bare in prose → NOT admitted (neither the terms nor the sentence-starters).
        let prose = RepoTermMiner.mineMarkdown("Kubernetes is the target. This project uses Coralate. Getting started is easy.")
        XCTAssertFalse(prose.contains("Kubernetes"), "bare prose proper noun must not be mined: \(prose)")
        XCTAssertFalse(prose.contains("Coralate"), prose.description)
        XCTAssertFalse(prose.contains("This"), prose.description)
        XCTAssertFalse(prose.contains("Getting"), prose.description)
    }

    /// The byte bound is honored: content past the cap is not mined.
    func testMineMarkdownRespectsByteBound() {
        let filler = String(repeating: "just some ordinary prose words here. ", count: 4000)
        let md = filler + " `ZzTerminalMarkerToken`"
        let terms = RepoTermMiner.mineMarkdown(md, maxBytes: 1_000)
        XCTAssertFalse(terms.contains("ZzTerminalMarkerToken"),
                       "a term past the byte bound must not be mined: \(terms.count) terms")
    }

    func testMineMarkdownEmptyInput() {
        XCTAssertTrue(RepoTermMiner.mineMarkdown("").isEmpty)
        XCTAssertTrue(RepoTermMiner.mineMarkdown("the and for with from this that").isEmpty,
                      "a pure-stopword doc yields no terms")
    }

    // MARK: - Git plumbing: normal .git directory

    /// A normal `.git` directory: HEAD symref + loose branch refs + reflog subjects
    /// all contribute terms; the git-verb prefix ("commit:") is stripped.
    func testMineGitNormalRepo() throws {
        try write("ref: refs/heads/feat/meeting-far-audio\n", to: ".git/HEAD")
        try write("0000000000000000000000000000000000000000\n", to: ".git/refs/heads/feat/meeting-far-audio")
        try write("0000000000000000000000000000000000000000\n", to: ".git/refs/heads/fix/dictionary-delete-rule")
        // Reflog: "<old> <new> <name> <email> <time> <tz>\t<verb>: <subject>"
        let reflog = """
        0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 Dev <d@e.com> 1700000000 +0000\tcommit: wire NicheCorrector into AppDelegate
        1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 Dev <d@e.com> 1700000100 +0000\tcommit: map-reduce MeetingSummarizer for long meetings
        """
        try write(reflog + "\n", to: ".git/logs/HEAD")

        let terms = RepoTermMiner.mineGit(root: root)
        // Branch leaves (the codename you'd dictate).
        XCTAssertTrue(terms.contains { $0.lowercased() == "meeting" }, terms.description)
        XCTAssertTrue(terms.contains { $0.lowercased() == "audio" }, terms.description)
        XCTAssertTrue(terms.contains { $0.lowercased() == "dictionary" }, terms.description)
        // Commit-message identifiers.
        XCTAssertTrue(terms.contains("NicheCorrector"), terms.description)
        XCTAssertTrue(terms.contains("AppDelegate"), terms.description)
        XCTAssertTrue(terms.contains("MeetingSummarizer"), terms.description)
        // The git verb itself is not a term.
        XCTAssertFalse(terms.contains { $0.lowercased() == "commit" }, "the reflog verb must be stripped: \(terms)")
    }

    // MARK: - Git plumbing: worktree gitdir FILE

    /// The worktree/submodule case: `<root>/.git` is a FILE containing `gitdir: <path>`
    /// pointing at the real git dir. The miner must resolve it and read HEAD/refs there.
    func testMineGitWorktreeGitdirFile() throws {
        // Real git data lives in a sibling directory.
        let realGit = root.appendingPathComponent("realgitdir", isDirectory: true)
        try write("ref: refs/heads/claude/agitated-merkle\n", to: "realgitdir/HEAD")
        try write("0000000000000000000000000000000000000000\n", to: "realgitdir/refs/heads/claude/agitated-merkle")
        // The working root's `.git` is a FILE with an absolute gitdir pointer.
        try write("gitdir: \(realGit.path)\n", to: ".git")

        let terms = RepoTermMiner.mineGit(root: root)
        XCTAssertTrue(terms.contains { $0.lowercased() == "agitated" },
                      "worktree gitdir: file must be resolved and its branch mined: \(terms)")
        XCTAssertTrue(terms.contains { $0.lowercased() == "merkle" }, terms.description)
    }

    /// A relative `gitdir:` path resolves against the working root.
    func testMineGitWorktreeRelativeGitdir() throws {
        try write("ref: refs/heads/feature-nightshade\n", to: "nested/realgit/HEAD")
        try write("gitdir: ./nested/realgit\n", to: ".git")
        let terms = RepoTermMiner.mineGit(root: root)
        XCTAssertTrue(terms.contains { $0.lowercased() == "nightshade" },
                      "a relative gitdir: must resolve against root: \(terms)")
    }

    // MARK: - Git plumbing: packed-refs

    /// Branch names that live only in `packed-refs` (not as loose files) are mined.
    func testMineGitPackedRefs() throws {
        try write("ref: refs/heads/main\n", to: ".git/HEAD")
        let packed = """
        # pack-refs with: peeled fully-peeled sorted
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/perf/quicksilver-index
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/tags/v1.0.0
        """
        try write(packed + "\n", to: ".git/packed-refs")
        let terms = RepoTermMiner.mineGit(root: root)
        XCTAssertTrue(terms.contains { $0.lowercased() == "quicksilver" },
                      "packed-refs branch must be mined: \(terms)")
        // A tag ref is NOT a branch — must not leak in as a branch term.
        XCTAssertFalse(terms.contains("v1.0.0"), terms.description)
    }

    // MARK: - Git plumbing: missing / broken

    /// No `.git` at all → empty, no throw.
    func testMineGitMissingRepo() {
        let terms = RepoTermMiner.mineGit(root: root)
        XCTAssertTrue(terms.isEmpty, "a non-repo must yield no terms and not crash")
    }

    /// A `.git` file with garbage contents (no `gitdir:`) → empty, no throw. Mirrors a
    /// half-written / mid-rebase state that must never crash the scan.
    func testMineGitBrokenGitdirFile() throws {
        try write("this is not a valid gitdir pointer\n", to: ".git")
        XCTAssertTrue(RepoTermMiner.mineGit(root: root).isEmpty)
    }

    /// A `.git` dir that exists but has no HEAD/refs/logs → empty, no throw.
    func testMineGitEmptyGitDir() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertTrue(RepoTermMiner.mineGit(root: root).isEmpty)
    }

    // MARK: - Corrector-term safety filter

    /// `SpokenFileMatcher.correctorTerms` drops common-word collisions and sub-4-letter
    /// terms, keeping distinctive jargon. This is the guard that stands between mined
    /// prose and the corrector.
    func testCorrectorTermsFilter() {
        let mined = ["CLAUDE.md", "talkie-bench", "code", "data", "the", "Kubernetes", "idempotent", "PR", "go"]
        let safe = SpokenFileMatcher.correctorTerms(from: mined)
        XCTAssertTrue(safe.contains("CLAUDE.md"), safe.description)
        XCTAssertTrue(safe.contains("Kubernetes"), safe.description)
        XCTAssertTrue(safe.contains("idempotent"), safe.description)
        // Common words / too-short must be rejected.
        XCTAssertFalse(safe.contains("code"), "common word must be filtered: \(safe)")
        XCTAssertFalse(safe.contains("data"), "common word must be filtered: \(safe)")
        XCTAssertFalse(safe.contains("the"), safe.description)
        XCTAssertFalse(safe.contains("go"), "sub-4-letter must be filtered: \(safe)")
        XCTAssertFalse(safe.contains("PR"), "sub-4-letter must be filtered: \(safe)")
    }

    func testCorrectorTermsDedupsAndCaps() {
        let mined = ["Kubernetes", "kubernetes", "KUBERNETES"] + (0..<300).map { "TermNumber\($0)" }
        let safe = SpokenFileMatcher.correctorTerms(from: mined, limit: 200)
        XCTAssertLessThanOrEqual(safe.count, 200, "must respect the cap")
        let kubes = safe.filter { $0.lowercased() == "kubernetes" }
        XCTAssertEqual(kubes.count, 1, "case-insensitive dedup: \(kubes)")
    }

    // MARK: - End-to-end over a fixture project (scanAll)

    /// A realistic small project: CLAUDE.md + README + docs/*.md + a code file + a
    /// `.git` dir. `scanAll` collects doc files during the walk and mines them plus
    /// git, all in one pass, producing deduped docTerms.
    func testScanAllMinesDocsAndGit() throws {
        try write("# Project\nUse `talkie-bench` and read `CLAUDE.md`. We deploy `Kubernetes`.\n", to: "CLAUDE.md")
        try write("# Readme\nThe ProjectIndexStore owns scanning.\n", to: "README.md")
        try write("# Architecture\nThe context_graph is the spine. See NicheCorrector.\n", to: "docs/architecture.md")
        try write("import Foundation\n", to: "Sources/App.swift")
        try write("ref: refs/heads/feat/repo-jargon-mining\n", to: ".git/HEAD")
        try write("0\n", to: ".git/refs/heads/feat/repo-jargon-mining")

        let result = ProjectScanner.scanAll(roots: [root])
        let lowered = Set(result.docTerms.map { $0.lowercased() })
        XCTAssertTrue(lowered.contains("talkie-bench"), result.docTerms.description)
        XCTAssertTrue(lowered.contains("claude.md"), result.docTerms.description)
        XCTAssertTrue(lowered.contains("kubernetes"), result.docTerms.description)
        XCTAssertTrue(lowered.contains("projectindexstore"), result.docTerms.description)
        XCTAssertTrue(lowered.contains("context_graph"), result.docTerms.description)
        XCTAssertTrue(lowered.contains("nichecorrector"), result.docTerms.description)
        XCTAssertTrue(lowered.contains("jargon"), "branch-leaf word should be mined: \(result.docTerms)")
        // The code file is still indexed the ordinary way.
        XCTAssertTrue(result.files.contains("App.swift"), result.files.description)
    }

    /// The snapshot the dictation path reads exposes filtered corrector terms.
    func testSnapshotExposesCorrectorTerms() {
        let snap = SpokenFileMatcher.buildSnapshot(
            files: ["App.swift"], symbols: ["App"],
            docTerms: ["Kubernetes", "code", "CLAUDE.md"])
        XCTAssertTrue(snap.correctorTerms.contains("Kubernetes"), snap.correctorTerms.description)
        XCTAssertTrue(snap.correctorTerms.contains("CLAUDE.md"), snap.correctorTerms.description)
        XCTAssertFalse(snap.correctorTerms.contains("code"), snap.correctorTerms.description)
    }

    // MARK: - THE GATE: false-positive prose corpus with mined terms loaded

    /// A3-specific EXTENSION of A1's `plainProse` corpus: extra clean sentences whose
    /// words sit acoustically or lexically NEXT to the terms a *repo* mines (cloud,
    /// code, cube, correlate, data, graph, model, note, index, query, store, field,
    /// token, state, place, bench) — without any word actually BEING a mined term. A1's
    /// corpus stresses synthetic pseudo-jargon; these stress the collisions that only
    /// appear once real project vocabulary (CLAUDE.md, talkie-bench, ContextGraph…) is
    /// the term set. The gate runs A1's corpus AND these.
    private let repoNearMissProse: [String] = [
        "We need to take the data from the survey and turn it into a chart.",
        "The graph on the wall showed the rainfall over the past decade.",
        "We tried to correlate the two events but found no real connection.",
        "The field behind the barn was covered in tall grass and wildflowers.",
        "He gave a token of his thanks to everyone who helped with the move.",
        "The index at the back of the book made it easy to find the topic.",
        "I need to query the office about when the new schedule will be ready.",
        "The cube of ice slowly melted in the warm glass of lemonade.",
        "They watched the clouds drift across the sky as the plane took off.",
        "The plane climbed slowly through the thick layer of gray clouds.",
        "She works at a store that sells fabric and sewing supplies downtown.",
        "The new model of the car gets much better mileage on the highway.",
        "I want to place an order for two large pizzas and a side salad.",
        "The state fair comes to town during the last week of every August.",
        "He sat on the bench in the park and watched the ducks on the pond.",
        "She wrote a quick note and left it on the counter before she went out.",
    ]

    /// THE GATE (A3's deliverable). Terms mined from a fixture repo shaped like Talkie's
    /// own — its `CLAUDE.md`/README/docs plus git branches & commit words — loaded into
    /// `NicheCorrector`, run over A1's canonical false-positive corpus (`plainProse`)
    /// PLUS the repo-near-miss extension above. Result must be ZERO fixes. If any clean
    /// sentence changes, a mined term is bleeding into ordinary speech — the same failure
    /// mode that killed `contextualStrings` biasing, and the package fails.
    ///
    /// Reuses A1's fixtures per the A3 spec ("REUSE/EXTEND those fixtures rather than
    /// inventing a new corpus") — the corpus is `NicheLoopTests.plainProse`; A3 only adds
    /// the repo-mined term set and the near-miss sentences targeting it.
    func testFalsePositiveCorpusWithMinedTermsProducesZeroFixes() throws {
        // A fixture repo shaped like Talkie's own — the terms most likely to collide
        // with ordinary prose (identifiers, a filename, a hyphenated tool name, git).
        try write("""
        # Talkie
        Run `talkie-bench`. Config in `CLAUDE.md`. We wire `NicheCorrector`,
        `ContextGraph`, `ProjectIndexStore`, `SpokenFileMatcher`, and `MeetingSummarizer`.
        We deploy `Kubernetes` and keep things `idempotent`. Project `Coralate` and `Higgsfield`.
        """, to: "CLAUDE.md")
        try write("# Readme\nSee docs. Uses AppDelegate.swift and the context_graph spine.\n", to: "README.md")
        try write("# Architecture\nThe context_graph is the spine. TranscriptionEngine feeds it.\n",
                  to: "docs/architecture.md")
        try write("ref: refs/heads/feat/repo-jargon-mining\n", to: ".git/HEAD")
        try write("0\n", to: ".git/refs/heads/feat/repo-jargon-mining")
        try write("0\n", to: ".git/refs/heads/claude/agitated-merkle")
        let reflog = "0 1 Dev <d@e.com> 1700000000 +0000\tcommit: wire NicheCorrector and MeetingSummarizer\n"
        try write(reflog, to: ".git/logs/HEAD")

        let result = ProjectScanner.scanAll(roots: [root])
        // Exactly what the live path feeds the corrector: the guard-filtered snapshot set.
        let snapshot = SpokenFileMatcher.buildSnapshot(
            files: result.files, symbols: result.symbols, docTerms: result.docTerms)
        let minedTerms = snapshot.correctorTerms
        XCTAssertFalse(minedTerms.isEmpty, "the fixture must actually produce mined terms to make this a real test")
        XCTAssertTrue(minedTerms.contains("Kubernetes"),
                      "sanity: the corpus's jargon really is loaded — \(minedTerms)")
        XCTAssertTrue(minedTerms.contains("ContextGraph"), minedTerms.description)

        // Reuse A1's canonical corpus, then extend with the repo-near-miss sentences.
        let corpus = NicheLoopTests.plainProse + repoNearMissProse
        var offenders: [(String, String)] = []
        for sentence in corpus {
            let corrected = NicheCorrector.correct(sentence, terms: minedTerms)
            if !corrected.fixes.isEmpty || corrected.text != sentence {
                offenders.append((sentence, corrected.text))
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "mined repo terms rewrote \(offenders.count)/\(corpus.count) clean sentences "
            + "(false positives) — the A3 gate FAILS:\n"
            + offenders.map { "  • \($0.0)\n    → \($0.1)" }.joined(separator: "\n"))
    }

    /// The gate, doubled: A1's real synthetic 300-term set UNIONED with our repo-mined
    /// terms — the worst case for the live path, where the corrector carries the full
    /// niche vocabulary AND this project's jargon at once — still zero fixes over A1's
    /// prose. Proves A3's additions don't destabilize A1's already-passing gate.
    func testCombinedNicheAndRepoTermsStillZeroFixes() throws {
        try write("Run `talkie-bench`. Read `CLAUDE.md`. We wire `ContextGraph`. Deploy Kubernetes.\n",
                  to: "CLAUDE.md")
        let result = ProjectScanner.scanAll(roots: [root])
        let repoTerms = SpokenFileMatcher.buildSnapshot(
            files: result.files, symbols: result.symbols, docTerms: result.docTerms).correctorTerms

        // The union the live corrector would actually hold, capped at 300 like A1.
        var combined = NicheLoopTests.syntheticGraduatedTerms
        var seen = Set(combined.map { $0.lowercased() })
        for t in repoTerms where combined.count < 300 {
            if seen.insert(t.lowercased()).inserted { combined.append(t) }
        }

        var offenders: [(String, String)] = []
        for sentence in NicheLoopTests.plainProse {
            let corrected = NicheCorrector.correct(sentence, terms: combined)
            if corrected.text != sentence { offenders.append((sentence, corrected.text)) }
        }
        XCTAssertTrue(offenders.isEmpty,
            "niche + repo terms combined produced false positives — gate FAILS:\n"
            + offenders.map { "  • \($0.0)\n    → \($0.1)" }.joined(separator: "\n"))
    }

    /// The complement of the gate: with those same mined terms loaded, a genuine
    /// close-miss IS rescued — so the zero-false-positive result above isn't just the
    /// corrector doing nothing. "cloud MD" → "CLAUDE.md", "talky bench" → "talkie-bench".
    func testMinedTermsStillRescueGenuineCloseMisses() throws {
        try write("Run `talkie-bench`. Read `CLAUDE.md`. Deploy Kubernetes.\n", to: "CLAUDE.md")
        let result = ProjectScanner.scanAll(roots: [root])
        let snapshot = SpokenFileMatcher.buildSnapshot(
            files: result.files, symbols: result.symbols, docTerms: result.docTerms)
        let minedTerms = snapshot.correctorTerms

        let cloudMd = NicheCorrector.correct("looking at the cloud MD file", terms: minedTerms).text
        XCTAssertEqual(cloudMd, "looking at the CLAUDE.md file",
                       "a real close-miss of CLAUDE.md must still be rescued by mined terms")

        let talkyBench = NicheCorrector.correct("run the talky bench suite", terms: minedTerms).text
        XCTAssertEqual(talkyBench, "run the talkie-bench suite",
                       "a real close-miss of talkie-bench must still be rescued by mined terms")

        // Honest boundary (spec: "close-miss rescue, honest expectations — mangled-beyond-
        // recognition stays wrong"): "cubernets" is a ~2-edit miss of "Kubernetes", beyond the
        // corrector's deliberate skeleton-distance-1 close-miss range, so it is correctly LEFT
        // UNTOUCHED. Rescuing a miss this far is exactly the false-positive pressure the gate
        // above exists to prevent. The two rescues above already prove mined terms DO rescue
        // genuine close misses, so the zero-false-positive result isn't the corrector doing nothing.
        let kube = NicheCorrector.correct("we deployed the cubernets cluster", terms: minedTerms).text
        XCTAssertEqual(kube, "we deployed the cubernets cluster",
                       "a term mangled beyond distance-1 stays wrong — honest close-miss-only design")
    }
}
