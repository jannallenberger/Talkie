import XCTest
@testable import Talkie

/// Tests for post-hoc niche correction — phonetic matching, bigram merges,
/// punctuation preservation, and the safety cases (don't touch clean words or
/// already-correct terms).
final class NicheCorrectorTests: XCTestCase {
    private let terms = ["Kubernetes", "idempotent", "Coralate"]

    /// Real misrecognitions of "Claude.md" captured from the dictation log, run
    /// against the user's ACTUAL vocabulary. Maps which variants the corrector
    /// catches vs misses. (Post-hoc, on the transcript, so it works in every app.)
    func testClaudeMdFromLog() {
        let vocab = ["Coralate", "Claude.md", "Talkie", "Higgsfield", "Github", "Artifacts"]
        func fixed(_ s: String) -> String { NicheCorrector.correct(s, terms: vocab).text }
        // Adjacent "cloud MD" / "clouded MD" — phonetic bigram should catch these.
        XCTAssertEqual(fixed("looking at the cloud MD file"), "looking at the Claude.md file")
        XCTAssertEqual(fixed("use the clouded MD file"), "use the Claude.md file")
        // "cloud of MD" — a filler word splits the term (the real log case).
        XCTAssertEqual(fixed("looking at the cloud of MD file"), "looking at the Claude.md file")
    }

    /// The exact failure from the live test: the recognizer's mistakes get fixed,
    /// punctuation and surrounding words are preserved.
    func testFixesTheLiveTestSentence() {
        let raw = "Yeah, so we deployed the new Cubernets cluster for correlate and fixed the item patent retry back. Let's try and test this."
        let r = NicheCorrector.correct(raw, terms: terms)
        XCTAssertTrue(r.text.contains("Kubernetes"), r.text)
        XCTAssertTrue(r.text.contains("idempotent"), r.text)
        XCTAssertFalse(r.text.contains("Cubernets"), r.text)
        XCTAssertFalse(r.text.contains("item patent"), r.text)
        XCTAssertTrue(r.text.hasPrefix("Yeah, so we deployed the new Kubernetes cluster"), r.text)
        XCTAssertTrue(r.text.contains("retry back."), r.text)   // punctuation kept
        XCTAssertGreaterThanOrEqual(r.fixes.count, 2)
    }

    /// A single mis-spelled word is swapped for the canonical term.
    func testSingleWordPhoneticFix() {
        let r = NicheCorrector.correct("the cubernets cluster", terms: ["Kubernetes"])
        XCTAssertEqual(r.text, "the Kubernetes cluster")
        XCTAssertEqual(r.fixes, [NicheFix(from: "cubernets", to: "Kubernetes")])
    }

    /// The recognizer splitting one unknown word into two common ones is recovered.
    func testBigramFix() {
        let r = NicheCorrector.correct("fixed the item patent bug", terms: ["idempotent"])
        XCTAssertEqual(r.text, "fixed the idempotent bug")
        XCTAssertEqual(r.fixes.first?.to, "idempotent")
    }

    /// A one-word niche term the recognizer split into two REAL words that happen to
    /// spell it exactly ("Higgs field" → "Higgsfield") is joined back. Regression for
    /// the gap where `core == target.core` short-circuited to "already correct" and
    /// left the two words unmerged.
    func testJoinsTwoRealWordsThatSpellATerm() {
        let r = NicheCorrector.correct("scan the Higgs field button", terms: ["Higgsfield"])
        XCTAssertEqual(r.text, "scan the Higgsfield button")
        XCTAssertEqual(r.fixes.first?.to, "Higgsfield")
    }

    /// A clean sentence with no jargon is left exactly as-is.
    func testLeavesCleanSentenceAlone() {
        let raw = "we shipped the new feature today"
        let r = NicheCorrector.correct(raw, terms: terms)
        XCTAssertEqual(r.text, raw)
        XCTAssertTrue(r.fixes.isEmpty)
    }

    /// An already-correct term is not touched (no needless replacement).
    func testDoesNotTouchAlreadyCorrectTerm() {
        let raw = "we use Kubernetes daily"
        let r = NicheCorrector.correct(raw, terms: ["Kubernetes"])
        XCTAssertEqual(r.text, raw)
        XCTAssertTrue(r.fixes.isEmpty)
    }

    func testEmptyInputs() {
        XCTAssertEqual(NicheCorrector.correct("", terms: terms).text, "")
        XCTAssertEqual(NicheCorrector.correct("hello world", terms: []).text, "hello world")
    }

    /// Words that sound alike collapse to the same phonetic key — the basis of the
    /// whole match.
    func testPhoneticSkeletonCollapsesSpelling() {
        XCTAssertEqual(NichePhonetics.skeleton("Kubernetes"), NichePhonetics.skeleton("cubernets"))
        XCTAssertNotEqual(NichePhonetics.skeleton("Kubernetes"), NichePhonetics.skeleton("elephant"))
    }
}
