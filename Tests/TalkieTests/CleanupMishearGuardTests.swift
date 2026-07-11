import XCTest
@testable import Talkie

/// WP5 — the `.faithful` novelty guard (`CleanupEngine.faithfulAddsContent`).
///
/// Context: `CleanupStyle.instructions`' shared prompt tail now carries a
/// MISHEARINGS license permitting every style to repair an obviously misheard
/// word (e.g. "does not make any sensor" → "does not make any sense"). That's a
/// welcome fix for the rewriting styles, which already tolerate rephrasing and
/// are gated by the existing refusal/translation/language/`looksLikeAnswer`
/// guards. But `.faithful` separately promises byte-for-byte verbatim output —
/// so `.faithful` alone additionally runs `faithfulAddsContent` (wired into
/// `CleanupEngine.generate()` immediately after the `looksLikeAnswer` guard, before
/// `return cleaned`) as a pure content-word-multiset subset check.
///
/// Everything here is PURE — no Foundation Models, no live model invocation — in
/// the `LLMJargonRepairTests` / `KeepStyleOfferTests` idiom.
final class CleanupMishearGuardTests: XCTestCase {

    // MARK: - The core contract: faithful rejects even a CORRECT mishear repair

    /// Documents the contract explicitly: `.faithful` mode's job is byte-for-byte
    /// verbatim output, so `faithfulAddsContent` rejects an output that introduces
    /// a new content word EVEN WHEN the substitution is a legitimate, well-intentioned
    /// mishear repair. "does not make any sensor" → "does not make any sense" swaps
    /// one plausible content word ("sensor") for a different one ("sense") — from the
    /// multiset's point of view "sense" is new content absent from the input, so this
    /// must be REJECTED for faithful, even though a rewriting style would rightly
    /// accept the very same fix. This is not a bug — verbatim beats "probably right"
    /// for `.faithful`.
    func testFaithfulRejectsEvenACorrectMishearRepair() {
        let input = "does not make any sensor to me"
        let output = "does not make any sense to me"
        XCTAssertTrue(CleanupEngine.faithfulAddsContent(input: input, output: output),
                      "faithful must reject a mishear repair that introduces a new content word — " +
                      "verbatim is the whole point of .faithful, so even a CORRECT fix is out of scope")
    }

    /// The other headline example from the licensing gap: "Texas translation" for
    /// "text-to-speech transcription". Any rewrite toward the intended phrase
    /// introduces content words absent from the mangled input and must be rejected
    /// in faithful mode.
    func testFaithfulRejectsMishearRepairIntroducingNewTerm() {
        let input = "please turn on Texas translation for this call"
        let output = "please turn on text-to-speech transcription for this call"
        XCTAssertTrue(CleanupEngine.faithfulAddsContent(input: input, output: output))
    }

    /// A plain unrelated invented word is rejected too — the general "adds content"
    /// case the guard exists to catch, independent of mishearings.
    func testOutputAddingANewContentWordIsRejected() {
        let input = "let's meet at the office tomorrow"
        let output = "let's meet at the office tomorrow around noon"
        XCTAssertTrue(CleanupEngine.faithfulAddsContent(input: input, output: output),
                      "noon' is a content word the speaker never said")
    }

    // MARK: - No-change output passes

    /// An identity rewrite (nothing changed) introduces no new content — passes.
    func testNoChangeOutputPasses() {
        let input = "run git status then git commit dash m fixed the bug"
        XCTAssertFalse(CleanupEngine.faithfulAddsContent(input: input, output: input))
    }

    /// The shipped `.faithful` few-shot example itself: filler words are removed,
    /// no content word is added — must round-trip through the guard unrejected.
    func testFaithfulExampleRoundTripsUnrejected() {
        let input = "um run git status then uh git commit dash m fixed the bug"
        let output = "run git status then git commit -m fixed the bug"
        XCTAssertFalse(CleanupEngine.faithfulAddsContent(input: input, output: output),
                       "removing fillers/hyphenating a flag introduces no new content word")
    }

    /// Dropping a word (pure deletion, e.g. a retracted self-correction) is not
    /// "adding content" — only ADDITIONS are guarded here; the answer-guard and
    /// other checks are what police invented content more broadly upstream.
    func testDroppingAWordPasses() {
        let input = "send it to Sarah I mean Sam"
        let output = "send it to Sam"
        XCTAssertFalse(CleanupEngine.faithfulAddsContent(input: input, output: output))
    }

    // MARK: - Multiset semantics (not a plain set-subset check)

    /// A word repeated MORE often in the output than it appeared in the input counts
    /// as new content, even though the word itself already existed in the input —
    /// this is why the guard compares multisets, not sets.
    func testRepeatingAWordMoreOftenThanInputIsRejected() {
        let input = "review review the document"           // "review" appears twice
        let output = "review review review the document"    // now three times
        XCTAssertTrue(CleanupEngine.faithfulAddsContent(input: input, output: output),
                      "an extra repetition beyond what the input actually said is new content")
    }

    /// The mirror case: repeating a word exactly as many times as the input said it
    /// (in a different order) is fine — same multiset count, nothing new.
    func testRepeatingAWordTheSameNumberOfTimesPasses() {
        let input = "review review the document"
        let reordered = "the document review review"
        XCTAssertFalse(CleanupEngine.faithfulAddsContent(input: input, output: reordered))
    }

    /// A word genuinely absent from the input ("again") is new content regardless of
    /// how many times an already-spoken word is repeated alongside it.
    func testAddingAnUnrelatedWordAlongsideARepeatIsRejected() {
        let input = "review review the document"
        let output = "review review the document again"
        XCTAssertTrue(CleanupEngine.faithfulAddsContent(input: input, output: output),
                      "'again' is new content independent of the repeated word")
    }

    // MARK: - Guard-chain ordering (documented at the call site; see comment note)

    /// `faithfulAddsContent` only makes sense to run AFTER `looksLikeAnswer` has
    /// already had a chance to reject a hallucinated answer — this pins that a
    /// faithful-mode "answer" (which also adds unrelated content) is caught by
    /// `looksLikeAnswer` first, independent of whether the newer novelty guard would
    /// also have caught it. `CleanupEngine.generate()` wires the two in exactly this
    /// order (looksLikeAnswer, then faithfulAddsContent, right before returning
    /// `cleaned`) — see the "Guard chain" comment directly above the empty-output
    /// check in `generate()`.
    func testLooksLikeAnswerAndFaithfulGuardBothRejectAHallucinatedAnswer() {
        let input = "whats the tallest mountain in the world"
        let output = "Mount Everest"
        XCTAssertTrue(CleanupEngine.looksLikeAnswer(input: input, output: output),
                      "precondition: the answer guard alone already rejects this")
        XCTAssertTrue(CleanupEngine.faithfulAddsContent(input: input, output: output),
                      "the novelty guard independently rejects the same output too — belt and suspenders")
    }
}
