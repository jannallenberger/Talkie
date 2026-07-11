import XCTest
@testable import Talkie

/// The corrector's defense-in-depth against self-poisoning (WP4/4f): `ordinaryWords`
/// carries every ≥4-letter word the recognizer actually produced that is itself an
/// ordinary EN/DE word (built on the MainActor at the `endDictation` call site via
/// `DictionaryStore.isOrdinaryDictionaryWord`, never inside the corrector itself).
/// An AUTO-graduated (untrusted) term must never rewrite one of those words — this
/// is exactly the defense that would have stopped a learned poll→pull rule from
/// rewriting the correctly-heard "pill" to "pull" even if it had somehow slipped
/// past the trusted-fold gate. A TRUSTED term (explicit dictionary intent) may still
/// rewrite an ordinary word, but only on an identical-sounding match.
final class NicheCorrectorOrdinaryGuardTests: XCTestCase {
    // Deliberately a bare single word (rather than embedded in a sentence with a
    // short neighbor like "a"/"the") so only the single-word match path runs —
    // embedding it next to a ≤3-letter word would also exercise the corrector's
    // bigram-joining heuristics (for a recognizer split like "Higgs field" →
    // "Higgsfield"), which is a different mechanism than the one under test here.

    func testUntrustedTargetDoesNotRewriteOrdinaryWord() {
        let result = NicheCorrector.correct("pill", terms: ["pull"], ordinaryWords: ["pill"])
        XCTAssertEqual(result.text, "pill",
                       "an untrusted auto-graduated term must never rewrite a real word the user said")
        XCTAssertTrue(result.fixes.isEmpty)
    }

    func testTrustedTargetStillRewritesOnIdenticalSkeleton() {
        let result = NicheCorrector.correct("pill", terms: ["pull"],
                                            trusted: ["pull"], ordinaryWords: ["pill"])
        XCTAssertEqual(result.text, "pull",
                       "a trusted (explicit) term may still rescue an identical-sounding ordinary word")
        XCTAssertEqual(result.fixes, [NicheFix(from: "pill", to: "pull")])
    }

    /// Without `ordinaryWords` supplied (the default, matching every existing call
    /// site that predates this guard), behavior is unchanged — this is opt-in
    /// defense-in-depth, not a new default restriction.
    func testOrdinaryWordsDefaultsToEmptyAndDoesNotBlock() {
        let result = NicheCorrector.correct("pill", terms: ["pull"], trusted: ["pull"])
        XCTAssertEqual(result.text, "pull",
                       "with no ordinaryWords set, the guard must not fire")
    }
}
