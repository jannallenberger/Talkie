import XCTest
@testable import Talkie

/// Tests for active-file identifier biasing (A11): identifier extraction across
/// languages, the honest ≤2-spoken-word rescue window, the three safety gates,
/// frequency ranking + cap, window-title→file resolution, mtime cache invalidation,
/// the bounded read — and, the package's GATE, A1's false-positive prose corpus with
/// 80 real in-file identifiers loaded into `NicheCorrector` must still produce ZERO
/// fixes (the same discipline A1/A3 hold).
final class FileIdentifierMinerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fileident-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    @discardableResult
    private func write(_ text: String, to name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - Extraction shapes

    /// camelCase, PascalCase, and snake_case identifiers are all extracted; bare
    /// lowercase prose words are not (they're indistinguishable from speech).
    func testExtractsIdentifierShapes() {
        let src = """
        const exerciseFilter = makeFilter();
        function ExerciseLibrary() { return null; }
        let workout_plan = loadPlan();
        // ordinary prose comment describing the module goes right here
        """
        let terms = FileIdentifierMiner.identifiers(in: src)
        XCTAssertTrue(terms.contains("exerciseFilter"), "camelCase must be mined: \(terms)")
        XCTAssertTrue(terms.contains("ExerciseLibrary"), "PascalCase must be mined: \(terms)")
        XCTAssertTrue(terms.contains("workout_plan"), "snake_case must be mined: \(terms)")
        // Bare lowercase words in the comment are prose-shaped and must NOT be mined.
        XCTAssertFalse(terms.contains(where: { $0.lowercased() == "ordinary" }), terms.description)
        XCTAssertFalse(terms.contains(where: { $0.lowercased() == "module" }), terms.description)
        XCTAssertFalse(terms.contains(where: { $0.lowercased() == "describing" }), terms.description)
    }

    /// A digit-led run is never a token; a trailing/internal digit extends one. Uses a
    /// distinctive-lead identifier so it survives the leading-common-word gate.
    func testDigitHandling() {
        let terms = FileIdentifierMiner.identifiers(in: "let zephyr2Layout = 0; let v = 42px; const 3d = x;")
        XCTAssertTrue(terms.contains("zephyr2Layout"), "internal digit is fine: \(terms)")
        XCTAssertFalse(terms.contains(where: { $0.hasPrefix("42") }), "digit-led run must not be a token: \(terms)")
    }

    // MARK: - The honest rescue window (≤ 2 spoken words)

    /// An identifier that a speaker renders as ≤2 words is rescuable; one that splits
    /// into 3+ spoken words is beyond the corrector's window and is dropped at mine time.
    func testRescueWindowKeepsTwoWordDropsThreeWord() {
        XCTAssertTrue(FileIdentifierMiner.isRescuable("useState"), "'use state' = 2 words")
        XCTAssertTrue(FileIdentifierMiner.isRescuable("exerciseFilter"), "'exercise filter' = 2 words")
        XCTAssertTrue(FileIdentifierMiner.isRescuable("ExerciseLibrary"), "'exercise library' = 2 words")
        XCTAssertFalse(FileIdentifierMiner.isRescuable("useExerciseFilter"),
                       "'use exercise filter' = 3 spoken words — beyond rescue, must be dropped")
        XCTAssertFalse(FileIdentifierMiner.isRescuable("loadWorkoutPlanFromDisk"),
                       "4 spoken words — dropped")
    }

    /// The rescue window is enforced end-to-end through `identifiers`: a 3-word symbol
    /// present in the file never appears in the mined term set.
    func testThreeWordIdentifierExcludedFromMine() {
        let src = "const useExerciseFilter = 1; const exerciseFilter = 2; const useExerciseFilter2 = 3;"
        let terms = FileIdentifierMiner.identifiers(in: src)
        XCTAssertTrue(terms.contains("exerciseFilter"), terms.description)
        XCTAssertFalse(terms.contains("useExerciseFilter"),
                       "a 3-spoken-word identifier must not be mined even if frequent: \(terms)")
    }

    // MARK: - Safety gates

    /// An identifier whose FIRST spoken word is ordinary English is rejected even with
    /// identifier shape — a common leading word lets prose that merely contains it get
    /// fused into the symbol by the corrector's bigram join. This is what keeps mined
    /// terms out of ordinary prose (the false-positive corpus is the full proof).
    func testSafetyGatesRejectLeadingCommonWord() {
        let src = """
        let dataModel = 0
        let contextGraph = 1
        let benchSeat = 2
        let grassField = 3
        let exerciseFilter = 4
        """
        let terms = FileIdentifierMiner.identifiers(in: src)
        // A distinctive leading word anchors the match to intent → kept.
        XCTAssertTrue(terms.contains("contextGraph"), "distinctive lead 'context' passes: \(terms)")
        XCTAssertTrue(terms.contains("exerciseFilter"), "distinctive lead 'exercise' passes: \(terms)")
        // A common leading word (data/bench/grass) is prose-triggerable → dropped.
        XCTAssertFalse(terms.contains("dataModel"), "leads with common 'data' → dropped: \(terms)")
        XCTAssertFalse(terms.contains("benchSeat"), "leads with common 'bench' → dropped: \(terms)")
        XCTAssertFalse(terms.contains("grassField"), "leads with common 'grass' → dropped: \(terms)")
    }

    /// Bare common words with no compound shape are never mined at all.
    func testBareCommonWordsNeverMined() {
        let terms = FileIdentifierMiner.identifiers(in: "let code = 1; let data = 2; let node = 3;")
        XCTAssertFalse(terms.contains(where: { ["code", "data", "node"].contains($0.lowercased()) }),
                       "bare common words are never mined: \(terms)")
    }

    /// The 4-letter floor: a distinctively-shaped but tiny identifier is dropped.
    func testShortIdentifiersDropped() {
        let terms = FileIdentifierMiner.identifiers(in: "let aB = 0; let iX = 1; let goFn = 2;")
        XCTAssertFalse(terms.contains("aB"), "sub-4-letter dropped: \(terms)")
        XCTAssertFalse(terms.contains("iX"), terms.description)
    }

    // MARK: - Ranking + cap

    /// Frequency ranking: a symbol used many times outranks a one-off, and the cap is
    /// honored. Uses 100 distinctive two-word identifiers (a made-up domain prefix + a
    /// role) so they clear every gate and the cap actually bites.
    func testFrequencyRankingAndCap() {
        var src = "const zephyrHandler = 0;\n"
        for _ in 0..<20 { src += "zephyrHandler();\n" }   // make it the most frequent
        for i in 0..<100 { src += "const quanexWidget\(i) = \(i);\n" }
        let terms = FileIdentifierMiner.identifiers(in: src)
        XCTAssertEqual(terms.count, FileIdentifierMiner.maxTerms,
                       "the cap must bite when far more than maxTerms survive: \(terms.count)")
        XCTAssertEqual(terms.first, "zephyrHandler",
                       "the most-frequent identifier must rank first: \(terms.prefix(3))")
    }

    /// Ranking is deterministic across runs (no reliance on Dictionary iteration order).
    func testRankingIsDeterministic() {
        let src = (0..<50).map { "const zephyrWidget\($0) = \($0);" }.joined(separator: "\n")
        let a = FileIdentifierMiner.identifiers(in: src)
        let b = FileIdentifierMiner.identifiers(in: src)
        XCTAssertEqual(a, b, "identical input must yield identical ordered output")
    }

    // MARK: - Per-language fixtures (read from disk)

    func testMinesTypeScriptFile() throws {
        let url = try write("""
        import { useState } from "react";
        export function ExerciseLibrary() {
          const [exerciseFilter, setExerciseFilter] = useState("");
          const workoutPlan = buildWorkoutPlan(exerciseFilter);
          return renderExercises(workoutPlan);
        }
        """, to: "ExerciseLibrary.tsx")
        let terms = FileIdentifierMiner.mine(path: url.path)
        XCTAssertTrue(terms.contains("exerciseFilter"), terms.description)
        XCTAssertTrue(terms.contains("ExerciseLibrary"), terms.description)
        XCTAssertTrue(terms.contains("workoutPlan"), terms.description)
    }

    func testMinesSwiftFile() throws {
        let url = try write("""
        struct ZephyrSummarizer {
            let contextGraph: ContextGraph
            func summarizeMeeting(_ transcript: String) -> String {
                let cleaned = transcriptCleaner.clean(transcript)
                return cleaned
            }
        }
        """, to: "ZephyrSummarizer.swift")
        let terms = FileIdentifierMiner.mine(path: url.path)
        // All lead with a distinctive word (Zephyr / context / summarize), so all survive
        // the leading-common-word gate. ("MeetingSummarizer" would NOT — a common lead.)
        XCTAssertTrue(terms.contains("ZephyrSummarizer"), terms.description)
        XCTAssertTrue(terms.contains("contextGraph"), terms.description)
        XCTAssertTrue(terms.contains("summarizeMeeting"), terms.description)
    }

    func testMinesPythonFile() throws {
        let url = try write("""
        def workout_plan(exercise_filter):
            builder = ZephyrBuilder()
            return builder.assemble(exercise_filter)
        """, to: "planner.py")
        let terms = FileIdentifierMiner.mine(path: url.path)
        // "exercise_filter" (exercise is distinctive) and "ZephyrBuilder" (both distinctive)
        // are ≤2 spoken words and pass every gate. "workout_plan" splits to workout+plan —
        // "plan" is common, "workout" is not, so it survives the compound gate too.
        XCTAssertTrue(terms.contains("exercise_filter"), terms.description)
        XCTAssertTrue(terms.contains("ZephyrBuilder"), terms.description)
        XCTAssertTrue(terms.contains("workout_plan"), terms.description)
    }

    /// An unreadable / non-existent path degrades to an empty result, never a crash.
    func testMissingFileDegradesSilently() {
        XCTAssertTrue(FileIdentifierMiner.mine(path: dir.appendingPathComponent("nope.ts").path).isEmpty)
    }

    /// A directory path is never opened as a file.
    func testDirectoryPathYieldsNothing() {
        XCTAssertTrue(FileIdentifierMiner.mine(path: dir.path).isEmpty)
    }

    // MARK: - Window-title → indexed-file resolution

    func testResolvePathFromWindowTitle() {
        let map = ["exerciselibrary.tsx": "/repo/src/ExerciseLibrary.tsx",
                   "app.swift": "/repo/App.swift"]
        // Editor title with a trailing repo/label.
        XCTAssertEqual(
            FileIdentifierMiner.resolvePath(fromWindowTitle: "ExerciseLibrary.tsx — myapp", filePaths: map),
            "/repo/src/ExerciseLibrary.tsx")
        // A full path in the title still surfaces the basename.
        XCTAssertEqual(
            FileIdentifierMiner.resolvePath(fromWindowTitle: "~/dev/myapp/App.swift", filePaths: map),
            "/repo/App.swift")
        // Case-insensitive on the filename.
        XCTAssertEqual(
            FileIdentifierMiner.resolvePath(fromWindowTitle: "EXERCISELIBRARY.TSX — x", filePaths: map),
            "/repo/src/ExerciseLibrary.tsx")
    }

    func testResolvePathMissesWhenNotIndexedOrNoFilename() {
        let map = ["app.swift": "/repo/App.swift"]
        XCTAssertNil(FileIdentifierMiner.resolvePath(fromWindowTitle: "Other.tsx — x", filePaths: map),
                     "a filename we didn't index must miss")
        XCTAssertNil(FileIdentifierMiner.resolvePath(fromWindowTitle: "Inbox — Mail", filePaths: map),
                     "a title with no filename token must miss")
        XCTAssertNil(FileIdentifierMiner.resolvePath(fromWindowTitle: nil, filePaths: map))
        XCTAssertNil(FileIdentifierMiner.resolvePath(fromWindowTitle: "App.swift", filePaths: [:]),
                     "an empty index always misses")
    }

    /// Filename detection is strict on the extension: a sentence-ending word or a version
    /// number is not a filename candidate.
    func testFilenameCandidatesAreStrict() {
        XCTAssertEqual(FileIdentifierMiner.filenameCandidates(in: "index.ts"), ["index.ts"])
        XCTAssertTrue(FileIdentifierMiner.filenameCandidates(in: "we are done. version 1.2 shipped").isEmpty,
                      "a period-terminated word and a version number are not filenames")
        XCTAssertEqual(FileIdentifierMiner.filenameCandidates(in: "vite.config.ts — repo"), ["vite.config.ts"],
                       "a dotted config filename is one candidate")
    }

    // MARK: - Cache invalidation by mtime

    func testCacheInvalidatesOnModification() async throws {
        // Two-word identifiers, both with a distinctive (non-common) half, so they clear
        // every gate and sit in the rescue window.
        let url = try write("const zephyrHandler = 1;", to: "Cached.ts")
        let first = await FileIdentifierCache.shared.terms(forPath: url.path)
        XCTAssertTrue(first.contains("zephyrHandler"), first.description)

        // Rewrite with a different identifier AND bump the mtime forward so the change is
        // unambiguous even on a coarse-resolution filesystem clock.
        try "const quanexHandler = 2;".data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: url.path)
        let second = await FileIdentifierCache.shared.terms(forPath: url.path)
        XCTAssertTrue(second.contains("quanexHandler"),
                      "a changed mtime must re-mine the file: \(second)")
        XCTAssertFalse(second.contains("zephyrHandler"),
                       "the stale cached term must be gone after re-mine: \(second)")
    }

    /// An unchanged file returns the same terms on a second call (cache hit path is
    /// observable only by equality — the important guarantee is correctness, not timing).
    func testCacheHitReturnsSameTerms() async throws {
        let url = try write("const zephyrStable = 1;", to: "Stable.ts")
        let a = await FileIdentifierCache.shared.terms(forPath: url.path)
        let b = await FileIdentifierCache.shared.terms(forPath: url.path)
        XCTAssertEqual(a, b)
    }

    // MARK: - Bounded read

    /// Content past the byte bound is not mined. The marker is a valid, in-window,
    /// gate-passing identifier, so its absence is due to the byte bound alone (not the
    /// rescue-window or a safety gate filtering it for another reason).
    func testRespectsByteBound() throws {
        let filler = String(repeating: "const zephyrPadding = 0;\n", count: 20_000)
        let url = try write(filler + "const quanexMarker = 1;\n", to: "Big.ts")
        // File is > maxBytes; the terminal marker sits past the cap and must not be mined.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, FileIdentifierMiner.maxBytes, "fixture must exceed the read bound")
        let terms = FileIdentifierMiner.mine(path: url.path)
        XCTAssertTrue(terms.contains("zephyrPadding"), "an in-bound identifier IS mined: \(terms.prefix(3))")
        XCTAssertFalse(terms.contains("quanexMarker"),
                       "an identifier past the byte bound must not be mined")
    }

    // MARK: - THE GATE: false-positive corpus with 80 real-file identifiers loaded

    /// A realistic source file whose mined identifier set is large (≥ 80 after the cap),
    /// standing in for "the file you're looking at." Shaped like real TS/Swift: exported
    /// components, hooks, handlers, model types, snake_case helpers. Every identifier is
    /// distinctive and inside the ≤2-spoken-word window so the miner actually admits it.
    private func makeEightyIdentifierSource() -> String {
        // 90 identifiers where at least ONE half is distinctive jargon (a made-up domain
        // word or an unambiguous technical noun), so each survives every safety gate —
        // including the compound-of-common-words gate that (correctly) drops things like
        // "benchSeat". This mirrors real code: a symbol pairs a domain noun with a role
        // ("exerciseFilter", "kubeletConfig"). Two-word (or one-word) so all are inside
        // the rescue window.
        let camel = [
            "exerciseFilter", "kubeletConfig", "zephyrIndex", "quanexBuffer", "voraxHandler",
            "merkleProof", "coralateStore", "higgsField", "talkieBench", "nicheCorrector",
            "zephyrParser", "quanexLayer", "voraxFrame", "merkleRoot", "coralateGraph",
            "shardexNode", "glyphardMap", "brontexQueue", "cindelToken", "dravexField",
            "esperonModel", "fenwixTrack", "goliathBuffer", "harlexShape", "ixnayStyle",
            "jorvexTopic", "klaxonWidget", "lumexRadius", "morvexLabel", "norvexSlot",
        ]
        let pascal = [
            "ExerciseLibrary", "KubeletManager", "ZephyrEngine", "QuanexExtractor", "VoraxParser",
            "MerkleVerifier", "CoralateUploader", "HiggsRenderer", "TalkieRecorder", "NicheRegistry",
            "ZephyrCollector", "QuanexDrawer", "VoraxPicker", "MerkleTimer", "CoralateWidget",
            "ShardexBalancer", "GlyphardFactory", "BrontexClassifier", "CindelController", "DravexDecoder",
            "EsperonKeeper", "FenwixSimulator", "GoliathAssembler", "HarlexGardener", "IxnayEncoder",
            "JorvexResolver", "KlaxonBuilder", "LumexCharter", "MorvexScanner", "NorvexIndexer",
        ]
        let snake = [
            "exercise_filter", "kubelet_config", "zephyr_index", "quanex_buffer", "vorax_handler",
            "merkle_proof", "coralate_store", "higgs_field", "talkie_bench", "niche_corrector",
            "zephyr_parser", "quanex_layer", "vorax_frame", "merkle_root", "coralate_graph",
            "shardex_node", "glyphard_map", "brontex_queue", "cindel_token", "dravex_field",
            "esperon_model", "fenwix_track", "goliath_buffer", "harlex_shape", "ixnay_style",
            "jorvex_topic", "klaxon_widget", "lumex_radius", "morvex_label", "norvex_slot",
        ]
        var lines: [String] = []
        for id in camel { lines.append("const \(id) = compute();") }
        for id in pascal { lines.append("class \(id) {}") }
        for id in snake { lines.append("let \(id) = 0") }
        return lines.joined(separator: "\n")
    }

    /// THE GATE (A11's deliverable). 80+ real in-file identifiers, mined exactly as the
    /// live path mines them, loaded into `NicheCorrector` and run over A1's canonical
    /// false-positive prose corpus (`NicheLoopTests.plainProse`). Result MUST be ZERO
    /// fixes. If any clean sentence changes, an active-file identifier is bleeding into
    /// ordinary speech — the same failure mode that killed `contextualStrings` biasing,
    /// and the package fails. Reuses A1's fixtures per the spec.
    func testFalsePositiveCorpusWithEightyIdentifiersProducesZeroFixes() {
        let mined = FileIdentifierMiner.identifiers(in: makeEightyIdentifierSource())
        XCTAssertGreaterThanOrEqual(mined.count, 80,
            "the fixture must yield ≥80 mined identifiers to make this a real 80-term gate: \(mined.count)")
        // Sanity: the identifiers really are loaded (a couple of representative ones).
        XCTAssertTrue(mined.contains("exerciseFilter"), mined.description)
        XCTAssertTrue(mined.contains("ExerciseLibrary"), mined.description)

        var offenders: [(String, String)] = []
        for sentence in NicheLoopTests.plainProse {
            let corrected = NicheCorrector.correct(sentence, terms: mined)
            if !corrected.fixes.isEmpty || corrected.text != sentence {
                offenders.append((sentence, corrected.text))
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "active-file identifiers rewrote \(offenders.count)/\(NicheLoopTests.plainProse.count) clean "
            + "sentences (false positives) — the A11 gate FAILS:\n"
            + offenders.map { "  • \($0.0)\n    → \($0.1)" }.joined(separator: "\n"))
    }

    /// The gate, unioned with A1's full 300-term synthetic set AND capped at 300 like the
    /// live path — the worst case where the corrector carries the graduated niche
    /// vocabulary AND the file's identifiers at once — still zero fixes over A1's prose.
    func testCombinedNicheAndActiveFileTermsStillZeroFixes() {
        let mined = FileIdentifierMiner.identifiers(in: makeEightyIdentifierSource())
        var combined = NicheLoopTests.syntheticGraduatedTerms
        var seen = Set(combined.map { $0.lowercased() })
        for t in mined where combined.count < 300 {
            if seen.insert(t.lowercased()).inserted { combined.append(t) }
        }
        var offenders: [(String, String)] = []
        for sentence in NicheLoopTests.plainProse {
            let corrected = NicheCorrector.correct(sentence, terms: combined)
            if corrected.text != sentence { offenders.append((sentence, corrected.text)) }
        }
        XCTAssertTrue(offenders.isEmpty,
            "niche + active-file terms combined produced false positives — gate FAILS:\n"
            + offenders.map { "  • \($0.0)\n    → \($0.1)" }.joined(separator: "\n"))
    }

    /// The complement of the gate: with active-file identifiers loaded, a genuine
    /// two-spoken-word close-miss IS rescued — so the zero-false-positive result above
    /// isn't the corrector doing nothing. This is the acceptance criterion: focused on
    /// ExerciseLibrary.tsx, "exercise filter" snaps to the real `exerciseFilter`.
    func testActiveFileIdentifiersRescueGenuineCloseMiss() throws {
        let url = try write("""
        export function ExerciseLibrary() {
          const [exerciseFilter, setExerciseFilter] = useState("");
          return renderExercises(exerciseFilter);
        }
        """, to: "ExerciseLibrary.tsx")
        let mined = FileIdentifierMiner.mine(path: url.path)
        XCTAssertTrue(mined.contains("exerciseFilter"), mined.description)

        // The recognizer split the camelCase symbol into two ordinary words — the exact
        // case A11 rescues. (No connector; adjacent two-word join.)
        let rescued = NicheCorrector.correct("update the exercise filter now", terms: mined).text
        XCTAssertEqual(rescued, "update the exerciseFilter now",
                       "a two-spoken-word close-miss of an in-file identifier must be rescued")
    }
}
