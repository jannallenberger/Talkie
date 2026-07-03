import XCTest
@testable import Talkie

/// The curation gate for the bundled profession starter packs (A6). This suite IS
/// the package's safety net: it guarantees that no matter how a pack's word list is
/// edited, every shipped `.talkiepack` still
///
///   1. decodes through the real `TalkiePack` reader,
///   2. carries ≤ 300 vocabulary terms (the corrector's per-word sweep is bounded),
///   3. is 100% `NicheTermGuard.isSafeToInject`-safe (no term collides with a
///      common word, so installing a pack can't crowd/override ordinary speech), and
///   4. produces ZERO fixes on the false-positive prose corpus (the same ~200
///      ordinary-English sentences `NicheLoopTests` guards the live loop with) — so
///      a well-meaning pack addition can never regress recognition of plain speech.
///
/// SwiftPM unit tests run without the assembled app bundle, so we validate the
/// curated SOURCE files under `Resources/Packs/` directly (located relative to this
/// file), which is exactly what `scripts/build_app.sh` copies into the bundle.
final class StarterPackTests: XCTestCase {

    /// The false-positive corpus, reused from `NicheLoopTests` so both gates hold
    /// the corrector to the same "leave plain prose alone" bar.
    private var falsePositiveCorpus: [String] { NicheLoopTests.plainProse }

    // `DictionaryStore` reads/writes a fixed `dictionary.json` under Application
    // Support, and the install test calls `merge` (which persists). Snapshot that
    // file first and restore it on teardown — exactly like `DictionaryStoreLoadTests`
    // — so running this suite never clobbers a developer's own curated dictionary.
    private var dictionaryURL: URL {
        AppPaths.supportDirectory().appendingPathComponent("dictionary.json")
    }
    private var savedDictionary: Data?

    override func setUp() {
        super.setUp()
        savedDictionary = try? Data(contentsOf: dictionaryURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dictionaryURL)
        if let d = savedDictionary { try? d.write(to: dictionaryURL) }
        super.tearDown()
    }

    /// `Resources/Packs/` in the repo, resolved from this test's own path
    /// (`…/Tests/TalkieTests/StarterPackTests.swift` → repo root is three parents up).
    /// Loading the source files keeps the gate honest even in a plain `swift test`
    /// run where no `.app` bundle exists.
    private func packsDirectory() -> URL {
        URL(fileURLWithPath: #filePath)                 // …/Tests/TalkieTests/StarterPackTests.swift
            .deletingLastPathComponent()                // …/Tests/TalkieTests
            .deletingLastPathComponent()                // …/Tests
            .deletingLastPathComponent()                // repo root
            .appendingPathComponent("Resources/Packs", isDirectory: true)
    }

    private func loadSourcePack(_ pack: StarterPack) throws -> TalkiePack {
        let url = packsDirectory().appendingPathComponent("\(pack.fileBaseName).talkiepack")
        let data = try Data(contentsOf: url)
        return try StarterPack.decode(data)
    }

    // MARK: The gate (runs for every bundled pack)

    /// Every case in the `StarterPack` catalog must have a source file that decodes.
    /// A missing/renamed file fails here — the catalog and the shipped files can't drift.
    func testEveryBundledPackDecodes() throws {
        for pack in StarterPack.allCases {
            let url = packsDirectory().appendingPathComponent("\(pack.fileBaseName).talkiepack")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "missing bundled pack file: \(url.lastPathComponent)")
            XCTAssertNoThrow(try loadSourcePack(pack),
                             "\(pack.rawValue).talkiepack must decode through TalkiePack")
        }
    }

    /// Each pack's vocabulary is ≤ 300 terms. The live corrector caps its target set
    /// at 300 (`AppDelegate` union) precisely because its cost is O(words × targets);
    /// a pack that exceeded the cap would be silently truncated, so we forbid it.
    func testEveryPackIsWithinTheTermCap() throws {
        for pack in StarterPack.allCases {
            let loaded = try loadSourcePack(pack)
            XCTAssertLessThanOrEqual(loaded.vocabulary.count, 300,
                                     "\(pack.rawValue) has \(loaded.vocabulary.count) vocab terms; cap is 300")
        }
    }

    /// EVERY vocabulary term in EVERY pack must pass the guard. A term the guard would
    /// reject could never help (it'd be filtered before reaching the corrector) and
    /// would signal a curation mistake that risks a common word — so the gate is 100%,
    /// not "most".
    func testEveryVocabularyTermIsGuardSafe() throws {
        let termGuard = NicheTermGuard.default
        for pack in StarterPack.allCases {
            let loaded = try loadSourcePack(pack)
            for term in loaded.vocabulary {
                XCTAssertTrue(termGuard.isSafeToInject(term),
                              "\(pack.rawValue): vocabulary term \"\(term)\" is not guard-safe")
            }
        }
    }

    /// THE headline gate: running the false-positive prose through the corrector with
    /// a pack's vocabulary must change NOTHING — zero fixes, byte-identical output.
    /// This is what stops a curation edit from regressing recognition of ordinary
    /// speech (e.g. a term that phonetically collides with "kettle" or "water").
    func testEveryPackProducesZeroFalsePositives() throws {
        for pack in StarterPack.allCases {
            let loaded = try loadSourcePack(pack)
            var offenders: [(sentence: String, fixes: [NicheFix])] = []
            for sentence in falsePositiveCorpus {
                let result = NicheCorrector.correct(sentence, terms: loaded.vocabulary)
                if !result.fixes.isEmpty { offenders.append((sentence, result.fixes)) }
                XCTAssertEqual(result.text, sentence,
                               "\(pack.rawValue): plain prose changed: \"\(sentence)\"")
            }
            XCTAssertTrue(offenders.isEmpty,
                          "\(pack.rawValue): expected ZERO fixes on plain prose. Offenders: " +
                          offenders.map { "\($0.sentence) → \($0.fixes)" }.joined(separator: " | "))
        }
    }

    /// A pack's replacement-rule `from` phrases must ALSO be false-positive-safe:
    /// `TextProcessor` applies them by whole-word match, so a `from` that appears in
    /// ordinary prose would rewrite real speech. None of the corpus sentences may
    /// contain any rule's `from`.
    func testReplacementRuleTriggersDoNotAppearInPlainProse() throws {
        for pack in StarterPack.allCases {
            let loaded = try loadSourcePack(pack)
            let rules = loaded.replacements
            guard !rules.isEmpty else { continue }
            for sentence in falsePositiveCorpus {
                let processed = TextProcessor.apply(
                    replacements: rules.map {
                        Replacement(from: $0.from, to: $0.to,
                                    caseSensitive: $0.resolvedCaseSensitive,
                                    wholeWord: $0.resolvedWholeWord)
                    },
                    removeFillers: false, autoCapitalize: false, to: sentence)
                XCTAssertEqual(processed.text, sentence,
                               "\(pack.rawValue): a replacement rule rewrote plain prose: \"\(sentence)\"")
                XCTAssertEqual(processed.replacementHits, 0,
                               "\(pack.rawValue): a replacement rule fired on plain prose: \"\(sentence)\"")
            }
        }
    }

    // MARK: Developer pack — the must-have close-miss demonstrations

    /// The acceptance criterion, proven end-to-end against the real corrector: a
    /// genuine close miss of a Developer-pack term is rescued. "swift PM" is what the
    /// recognizer produces for "SwiftPM"; the corrector rejoins it (phonetic skeleton
    /// identical), so installing the pack fixes it on the next dictation.
    func testDeveloperPackRescuesSwiftPMCloseMiss() throws {
        let dev = try loadSourcePack(.developer)
        let r = NicheCorrector.correct("we ran swift PM to build the app", terms: dev.vocabulary)
        XCTAssertTrue(r.text.contains("SwiftPM"),
                      "expected 'swift PM' → 'SwiftPM', got: \(r.text)")
    }

    /// The same for the recognizer's habitual mangle of "Kubernetes" ("cubernets"),
    /// which the Developer pack's `Kubernetes` vocab term rescues.
    func testDeveloperPackRescuesKubernetesCloseMiss() throws {
        let dev = try loadSourcePack(.developer)
        let r = NicheCorrector.correct("deployed the cubernets cluster", terms: dev.vocabulary)
        XCTAssertTrue(r.text.contains("Kubernetes"),
                      "expected 'cubernets' → 'Kubernetes', got: \(r.text)")
    }

    /// The `kubectl` case is the reason rules exist: its spoken form ("cube control")
    /// diverges from the written form at phonetic-skeleton distance 2, BEYOND the
    /// corrector's ≤ 1 reach — so vocabulary can't rescue it and it must ship as a
    /// replacement rule. This test proves (a) the corrector genuinely can't do it and
    /// (b) the bundled rule does.
    func testKubectlNeedsARuleAndTheDeveloperPackShipsOne() throws {
        let dev = try loadSourcePack(.developer)

        // (a) Vocabulary alone can't rescue "cube control" → the divergence is too great.
        let vocabOnly = NicheCorrector.correct("run cube control get pods", terms: dev.vocabulary)
        XCTAssertFalse(vocabOnly.text.contains("kubectl"),
                       "vocabulary should NOT be able to rescue the distance-2 'cube control'; got: \(vocabOnly.text)")

        // (b) The pack ships an explicit replacement rule that does the job.
        let rule = dev.replacements.first { $0.to == "kubectl" && $0.from.lowercased() == "cube control" }
        XCTAssertNotNil(rule, "developer pack must ship a 'cube control' → 'kubectl' replacement rule")

        let processed = TextProcessor.apply(
            replacements: dev.replacements.map {
                Replacement(from: $0.from, to: $0.to,
                            caseSensitive: $0.resolvedCaseSensitive, wholeWord: $0.resolvedWholeWord)
            },
            removeFillers: false, autoCapitalize: false, to: "run cube control get pods")
        XCTAssertTrue(processed.text.contains("kubectl"),
                      "the bundled rule should turn 'cube control' into 'kubectl'; got: \(processed.text)")
    }

    // MARK: Install semantics (reuses A4's merge, so this is a thin sanity check)

    /// Installing a pack into an empty dictionary adds its vocabulary and rules, and
    /// re-installing the same pack is a no-op (A4's merge is add-if-absent). Confirms
    /// the card's install path actually populates what the corrector reads.
    @MainActor
    func testInstallingDeveloperPackPopulatesDictionaryAndIsIdempotent() throws {
        let dev = try loadSourcePack(.developer)
        let store = DictionaryStore()
        // Start from a known-clean slate (the store seeds one illustrative rule on
        // first run; clear it so the counts below are unambiguous).
        store.vocabulary = []
        store.replacements = []

        let first = store.merge(pack: dev)
        XCTAssertEqual(first.vocabularyAdded, dev.vocabulary.count,
                       "install should add all \(dev.vocabulary.count) vocab terms")
        XCTAssertEqual(first.replacementsAdded, dev.replacements.count,
                       "install should add all \(dev.replacements.count) rules")
        XCTAssertTrue(store.vocabulary.contains("SwiftPM"))

        let second = store.merge(pack: dev)
        XCTAssertTrue(second.isEmpty, "re-installing the same pack must add nothing")
    }
}
