import XCTest
@testable import Talkie

/// The self-learning loop that wires `NicheVocabStore` into the live
/// `NicheCorrector`: the confirm / reject / harvest signals, the corrector-term
/// union (dedup + cap), and — the gate that makes the whole package safe to ship —
/// the false-positive corpus test. That last one is A1's real deliverable: with a
/// large set of graduated terms present, ordinary prose that contains no jargon
/// misrecognition must come out of `NicheCorrector.correct` completely untouched.
/// This is the same discipline that killed `contextualStrings` biasing — a loose
/// corrector that "helpfully" rewrites clean words is worse than no corrector.
final class NicheLoopTests: XCTestCase {
    /// A "now" anchored to the real wall clock. The store's `prune()` (called on
    /// every save) measures term age against `Date()`, so store-level tests must use
    /// timestamps near the present or fresh occurrence-only terms get pruned as
    /// decades-stale before we can read them back. Confidence is otherwise evaluated
    /// against this same instant, so recency is 1.0 and the math matches the pure
    /// `NicheConfidenceTests`.
    private let now = Date().timeIntervalSince1970

    @MainActor
    private func makeStore() -> NicheVocabStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("niche-loop-test-\(UUID().uuidString)", isDirectory: true)
        return NicheVocabStore(directory: dir)
    }

    private func prov(_ id: String? = "d1", _ date: Double? = nil) -> Provenance {
        Provenance(source: .dictation, sourceID: id, dateUnix: date ?? now, snippet: nil)
    }

    // MARK: - Signal wiring

    /// The confirm signal: one explicit user confirmation graduates a term
    /// immediately, so it enters the corrector's term list without any Dictionary
    /// entry. This is the "dictate → type a correction → rescued next time" path.
    @MainActor
    func testUserConfirmGraduatesIntoCorrectorTerms() {
        let store = makeStore()
        XCTAssertFalse(store.snapshot(now: Date(timeIntervalSince1970: now))
            .correctorTerms(forNiche: NicheID.default.key, limit: 300)
            .contains("Higgsfield"),
            "term is unknown before any signal")

        store.recordUserConfirmed("Higgsfield", provenance: prov())

        let terms = store.snapshot(now: Date(timeIntervalSince1970: now))
            .correctorTerms(forNiche: NicheID.default.key, limit: 300)
        XCTAssertTrue(terms.contains("Higgsfield"),
                      "one confirmation must graduate the term into the corrector list")
    }

    /// End-to-end confirm: after a confirmation, the live `NicheCorrector` (fed the
    /// snapshot's corrector terms) rescues a close phonetic miss of that term — the
    /// headline acceptance criterion, exercised through the real correction path.
    @MainActor
    func testConfirmedTermRescuesCloseMiss() {
        let store = makeStore()
        store.recordUserConfirmed("Higgsfield", provenance: prov())
        let terms = store.snapshot(now: Date(timeIntervalSince1970: now))
            .correctorTerms(forNiche: NicheID.default.key, limit: 300)

        // The recognizer split the one-word term into two real words.
        let fixed = NicheCorrector.correct("open the Higgs field panel", terms: terms).text
        XCTAssertEqual(fixed, "open the Higgsfield panel",
                       "a graduated, confirmed term must be rescued by the corrector")
    }

    /// The harvest signal: terms merely mined from prose accumulate as occurrences
    /// and graduate only after enough repetition — never on a single sighting. Two
    /// harvests stay a candidate (the tuning tightening); the third graduates.
    @MainActor
    func testHarvestGraduatesOnlyAfterRepetition() {
        let store = makeStore()
        func corrector() -> [String] {
            store.snapshot(now: Date(timeIntervalSince1970: now))
                .correctorTerms(forNiche: NicheID.default.key, limit: 300)
        }
        store.ingest(["Zephyrium"], provenance: prov())
        XCTAssertFalse(corrector().contains("Zephyrium"), "one harvest → candidate, not boosted")
        store.ingest(["Zephyrium"], provenance: prov())
        XCTAssertFalse(corrector().contains("Zephyrium"),
                       "two harvests must still be a candidate (occurrence floor)")
        store.ingest(["Zephyrium"], provenance: prov())
        XCTAssertTrue(corrector().contains("Zephyrium"),
                      "three harvests graduate a repeated, guard-safe term")
    }

    /// The reject signal demotes: a graduated (confirmed) term that the user then
    /// corrects away drops out of the corrector list — the HUD-Undo path. One
    /// confirmation then one rejection nets to not-boosted.
    @MainActor
    func testRejectionDemotesConfirmedTerm() {
        let store = makeStore()
        store.recordUserConfirmed("Coralate", provenance: prov())
        XCTAssertTrue(store.snapshot(now: Date(timeIntervalSince1970: now))
            .correctorTerms(forNiche: NicheID.default.key, limit: 300).contains("Coralate"))

        store.recordRejection("Coralate")
        XCTAssertFalse(store.snapshot(now: Date(timeIntervalSince1970: now))
            .correctorTerms(forNiche: NicheID.default.key, limit: 300).contains("Coralate"),
            "an undone/rejected learn must demote the term until re-confirmed")
    }

    /// Persistence: writes land in `niche/vocab.json`, are inspectable, and survive a
    /// reload (the acceptance criterion that the file exists and round-trips).
    @MainActor
    func testPersistsToInspectableJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("niche-persist-\(UUID().uuidString)", isDirectory: true)
        do {
            let store = NicheVocabStore(directory: dir)
            store.recordUserConfirmed("Kubernetes", provenance: prov())
        }
        let fileURL = dir.appendingPathComponent("vocab.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "vocab.json must exist after a write")
        // Human-inspectable JSON containing the term.
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("Kubernetes"), "the term is present in the on-disk JSON")

        // A fresh store over the same directory sees the graduated term.
        let reloaded = NicheVocabStore(directory: dir)
        XCTAssertTrue(reloaded.snapshot(now: Date(timeIntervalSince1970: now))
            .correctorTerms(forNiche: NicheID.default.key, limit: 300).contains("Kubernetes"),
            "graduated terms survive a reload")
    }

    // MARK: - Union: dedup + cap (the AppDelegate corrector-union contract)

    /// The union that `endDictation` builds — `dictionary.vocabulary` +
    /// `correctorTerms`, deduped case-insensitively with the curated spelling
    /// winning — replicated here as the pure operation it is.
    private func union(dictionary: [String], niche: [String]) -> [String] {
        var out = dictionary
        var seen = Set(dictionary.map { $0.lowercased() })
        for term in niche where seen.insert(term.lowercased()).inserted { out.append(term) }
        return out
    }

    @MainActor
    func testUnionDedupesAgainstDictionaryCaseInsensitively() {
        let store = makeStore()
        store.recordUserConfirmed("kubernetes", provenance: prov())   // lowercased learn
        store.recordUserConfirmed("Idempotent", provenance: prov())
        let niche = store.snapshot(now: Date(timeIntervalSince1970: now))
            .correctorTerms(forNiche: NicheID.default.key, limit: 300)

        // Dictionary already has "Kubernetes" (different case) — must not duplicate.
        let merged = union(dictionary: ["Kubernetes", "Coralate"], niche: niche)
        let kubeCount = merged.filter { $0.lowercased() == "kubernetes" }.count
        XCTAssertEqual(kubeCount, 1, "a term already curated by hand is not duplicated by the niche union")
        XCTAssertTrue(merged.contains("Kubernetes"), "the curated (dictionary) spelling wins")
        XCTAssertFalse(merged.contains("kubernetes"), "the lowercased niche variant is dropped as a dupe")
        XCTAssertTrue(merged.contains("Idempotent"), "a genuinely new niche term is added")
    }

    /// The cap bounds the corrector's O(words × targets) cost: `correctorTerms`
    /// never returns more than `limit`, highest-confidence first.
    @MainActor
    func testCorrectorTermsHonorCap() {
        let store = makeStore()
        // Graduate 20 distinct guard-safe terms via confirmation.
        for i in 0..<20 { store.recordUserConfirmed("Xylophone\(letters(i))", provenance: prov()) }
        let capped = store.snapshot(now: Date(timeIntervalSince1970: now))
            .correctorTerms(forNiche: NicheID.default.key, limit: 5)
        XCTAssertEqual(capped.count, 5, "the cap is honored")
    }

    // MARK: - THE GATE: false-positive corpus

    /// ~200 plain-prose sentences run through `NicheCorrector.correct` with 300
    /// synthetic graduated terms must produce ZERO fixes. If any ordinary sentence
    /// comes back changed, a graduated jargon spelling has been forced onto a word
    /// the user actually said — the exact failure that sank `contextualStrings`
    /// biasing. This test is the package's ship gate.
    func testFalsePositiveCorpusProducesZeroFixes() {
        let terms = Self.syntheticGraduatedTerms
        XCTAssertEqual(terms.count, 300, "the corpus must exercise a realistic 300-term corrector set")
        // Sanity: every synthetic term is guard-safe, i.e. it is the kind of term
        // that would actually be allowed to graduate (no common-word collisions). A
        // term the guard would reject could never reach the live corrector, so
        // including it would weaken the test.
        let guardHolder = NicheTermGuard.default
        for t in terms {
            XCTAssertTrue(guardHolder.isSafeToInject(t),
                          "synthetic term \(t) must be guard-safe to be a fair corpus member")
        }

        var offenders: [(sentence: String, fixes: [NicheFix])] = []
        for sentence in Self.plainProse {
            let result = NicheCorrector.correct(sentence, terms: terms)
            if !result.fixes.isEmpty {
                offenders.append((sentence, result.fixes))
            }
            // The text must also be byte-identical, not merely "no reported fixes".
            XCTAssertEqual(result.text, sentence,
                           "plain prose must pass through unchanged; changed: \(sentence)")
        }
        XCTAssertTrue(offenders.isEmpty,
                      "ZERO fixes expected on plain prose. Offenders: " +
                      offenders.map { "\($0.sentence) → \($0.fixes)" }.joined(separator: " | "))
    }

    /// The corpus is genuine plain prose — it must be big enough to be a real test.
    func testCorpusSizeIsAdequate() {
        XCTAssertGreaterThanOrEqual(Self.plainProse.count, 200,
                                    "need ~200 plain-prose sentences for a meaningful gate")
    }

    // MARK: - Fixtures

    /// A short base-26-ish suffix so a loop can mint distinct guard-safe terms.
    private func letters(_ n: Int) -> String {
        let a = Array("abcdefghijklmnopqrstuvwxyz")
        return String(a[n % 26]) + String(a[(n / 26) % 26])
    }
}
