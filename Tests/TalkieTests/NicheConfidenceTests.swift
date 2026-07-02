import XCTest
@testable import Talkie

/// Pure-logic tests for the confidence-based niche vocabulary: the confidence
/// model (seed / raise / decay / graduate), the false-boost guard, and the bias
/// selection surface. No disk, no recognizer, no clock — `nowUnix` is passed in.
final class NicheConfidenceTests: XCTestCase {
    private let now = 1_000_000_000.0
    private let day = 86_400.0

    private func term(_ s: String, occ: Int = 0, confirmed: Int = 0, rejections: Int = 0,
                      last: Double? = nil) -> NicheTerm {
        let t = last ?? now
        return NicheTerm(term: s, nicheKey: NicheID.default.key, occurrences: occ,
                         userConfirmed: confirmed, rejections: rejections, rarenessZ: 0,
                         firstSeenUnix: t, lastSeenUnix: t, provenance: [])
    }

    // MARK: Confidence model

    /// A brand-new single-occurrence candidate is tracked but NOT boosted — unproven
    /// guesses must never reach the recognizer.
    func testSingleOccurrenceIsCandidateNotBoosted() {
        let t = term("idempotent", occ: 1)
        XCTAssertLessThan(NicheConfidence.score(t, nowUnix: now), NicheTuning.graduationThreshold)
        XCTAssertFalse(NicheConfidence.isBoosted(t, nowUnix: now))
    }

    /// Repetition raises confidence until the term graduates to boosted.
    func testRepetitionGraduates() {
        let one = term("kubelet", occ: 1)
        let four = term("kubelet", occ: 4)
        XCTAssertGreaterThan(NicheConfidence.score(four, nowUnix: now),
                             NicheConfidence.score(one, nowUnix: now))
        XCTAssertFalse(NicheConfidence.isBoosted(one, nowUnix: now))
        XCTAssertTrue(NicheConfidence.isBoosted(four, nowUnix: now))
    }

    /// The occurrence floor (A1's graduation-math tightening): a harvest-only term
    /// must be heard at least `minOccurrencesForBoost` times before it can boost,
    /// even if its raw confidence would otherwise clear the threshold. Two harvests
    /// alone (`log2(1+2) ≈ 1.58 > midpoint 1.5`) would have graduated under the old
    /// rule — this is exactly the looseness the false-positive corpus test guards.
    func testHarvestOnlyNeedsOccurrenceFloor() {
        XCTAssertEqual(NicheTuning.minOccurrencesForBoost, 3,
                       "settled against the false-positive corpus: occurrence-only graduates at 3")
        XCTAssertFalse(NicheConfidence.isBoosted(term("widget", occ: 2), nowUnix: now),
                       "two harvests stay a tracked candidate, not boosted")
        XCTAssertTrue(NicheConfidence.isBoosted(term("widget", occ: 3), nowUnix: now),
                      "three harvests graduate a harvest-only term")
    }

    /// A confirmed term graduates immediately, but a later rejection must be able to
    /// demote it — one confirm then one reject nets to not-boosted (the HUD-Undo
    /// path). Otherwise a single confirmation would pin a term boosted forever.
    func testConfirmThenRejectDemotes() {
        XCTAssertTrue(NicheConfidence.isBoosted(term("Talkie", confirmed: 1), nowUnix: now))
        XCTAssertFalse(NicheConfidence.isBoosted(term("Talkie", confirmed: 1, rejections: 1), nowUnix: now),
                       "an undone/rejected confirmation demotes the term")
        XCTAssertTrue(NicheConfidence.isBoosted(term("Talkie", confirmed: 2, rejections: 1), nowUnix: now),
                      "net-positive confirmations keep it boosted")
    }

    /// One explicit user confirmation graduates a term immediately, even with zero
    /// harvested occurrences — it's the strongest signal.
    func testUserConfirmGraduatesImmediately() {
        let t = term("Talkie", occ: 0, confirmed: 1)
        XCTAssertTrue(NicheConfidence.isBoosted(t, nowUnix: now))
    }

    /// Disuse decays confidence: the same term seen 90 days ago scores far lower
    /// than freshly seen, and falls back below graduation.
    func testTimeDecay() {
        let fresh = term("retval", occ: 4, last: now)
        let stale = term("retval", occ: 4, last: now - 90 * day)
        XCTAssertGreaterThan(NicheConfidence.score(fresh, nowUnix: now),
                             NicheConfidence.score(stale, nowUnix: now))
        XCTAssertTrue(NicheConfidence.isBoosted(fresh, nowUnix: now))
        XCTAssertFalse(NicheConfidence.isBoosted(stale, nowUnix: now))
    }

    /// Rejections (the user corrected away from a term) drive confidence down.
    func testRejectionsLowerConfidence() {
        let clean = term("foobar", occ: 4)
        let rejected = term("foobar", occ: 4, rejections: 2)
        XCTAssertGreaterThan(NicheConfidence.score(clean, nowUnix: now),
                             NicheConfidence.score(rejected, nowUnix: now))
        XCTAssertFalse(NicheConfidence.isBoosted(rejected, nowUnix: now))
    }

    // MARK: False-boost guard

    func testGuardRejectsCommonWordCollision() {
        let g = NicheTermGuard.default
        XCTAssertFalse(g.isSafeToInject("kube"))        // edit-distance 1 of "cube"
        XCTAssertFalse(g.isSafeToInject("code"))        // is itself a common word
        XCTAssertFalse(g.isSafeToInject("ml"))          // too short to be distinctive
        XCTAssertTrue(g.isSafeToInject("kubernetes"))   // genuinely rare, no collision
        XCTAssertTrue(g.isSafeToInject("idempotent"))
        XCTAssertTrue(g.isSafeToInject("context graph")) // multi-word phrase, low risk
    }

    func testEditDistanceWithin1() {
        XCTAssertTrue(NicheTermGuard.isWithinEditDistance1("cube", "kube"))   // substitution
        XCTAssertTrue(NicheTermGuard.isWithinEditDistance1("cat", "cart"))    // insertion
        XCTAssertTrue(NicheTermGuard.isWithinEditDistance1("cats", "cat"))    // deletion
        XCTAssertTrue(NicheTermGuard.isWithinEditDistance1("node", "node"))   // identical
        XCTAssertFalse(NicheTermGuard.isWithinEditDistance1("cat", "dog"))    // 3 substitutions
        XCTAssertFalse(NicheTermGuard.isWithinEditDistance1("graph", "graf")) // 2 edits
    }

    // MARK: Bias selection surface

    /// `biasPhrases` must (1) include only graduated, guard-safe terms, (2) exclude
    /// candidates and unsafe terms even when their counts are high, (3) rank by
    /// confidence, and (4) honor the cap.
    func testBiasPhrasesGatesAndRanks() {
        let terms = [
            term("Kubernetes", occ: 5),    // boosted + safe  → included
            term("idempotent", confirmed: 1), // boosted (confirmed) + safe → included, top conf
            term("widget", occ: 1),        // candidate (not boosted) → excluded
            term("kube", occ: 9),          // boosted but UNSAFE (collides "cube") → excluded
            term("code", occ: 9),          // boosted but common word → excluded
        ]
        let snap = NicheVocabSnapshot(niches: [], termsByNiche: [NicheID.default.key: terms],
                                      termGuard: .default, nowUnix: now)

        // `correctorTerms` is the live surface (feeds the post-hoc NicheCorrector);
        // `biasPhrases` delegates to it. Both must gate + rank + cap identically.
        let terms2 = snap.correctorTerms(forNiche: NicheID.default.key, limit: 10)
        XCTAssertEqual(terms2, ["idempotent", "Kubernetes"])
        XCTAssertEqual(snap.biasPhrases(forNiche: NicheID.default.key, limit: 10), terms2)
        XCTAssertFalse(terms2.contains("widget"))
        XCTAssertFalse(terms2.contains("kube"))
        XCTAssertFalse(terms2.contains("code"))

        // Cap is honored.
        XCTAssertEqual(snap.correctorTerms(forNiche: NicheID.default.key, limit: 1), ["idempotent"])
        // Unknown niche → empty, never a crash.
        XCTAssertEqual(snap.correctorTerms(forNiche: "nope", limit: 10), [])
    }
}
