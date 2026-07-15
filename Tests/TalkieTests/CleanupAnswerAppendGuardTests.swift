import XCTest
@testable import Talkie

/// Regression tests for the (C) content-growth shape in
/// `CleanupEngine.looksLikeAnswer(input:output:)`.
///
/// Bug this locks down: the user dictated an *imperative request* addressed to an
/// assistant ("Please investigate why this is happening… then rewrite it so I can
/// paste it"). The on-device model rewrote the dictation AND appended a fabricated
/// multi-section reply with invented fence headers ("<<<Investigation of the
/// Issue>>> I will now investigate…"), which got pasted as if the user had said it.
///
/// Every existing shape missed it:
///  • (Q)/(B) only fire when the input is a literal QUESTION — an imperative isn't.
///  • (A) needs novelRatio ≥ 0.6 — but the genuine rewrite in front of the invented
///    answer, plus the answer reusing the speaker's own vocabulary, drags the ratio
///    far below that.
final class CleanupAnswerAppendGuardTests: XCTestCase {

    /// What the user actually dictated: an imperative request, no question mark.
    private let dictatedRequest = """
    The following transcription is what Talkie just output to me. Please investigate \
    why this is happening, but before you do that, please understand the core message \
    of that last one because there was a prompt and I want to fire up that prompt in a \
    different chat. I therefore need you to understand what this actually said and then \
    rewrite it in order for me to paste it. After that, investigate why this is still \
    happening.
    """

    /// The exact reported failure: a faithful rewrite with a fabricated reply bolted
    /// on. Must be rejected so the caller keeps the raw transcript.
    func testRejectsRewritePlusAppendedFabricatedAnswer() {
        let output = dictatedRequest + """
         <<<Investigation of the Issue>>> I will now investigate why this is happening. \
        It seems that there might be a misunderstanding or a glitch in the system that is \
        causing the output to be incorrect. I will try to reproduce the issue and see if I \
        can identify the root cause. <<<Conclusion>>> I will continue to investigate the \
        issue and provide a solution as soon as possible. I will also make sure that the \
        system is functioning properly and that there are no other issues that might be \
        causing problems.
        """
        XCTAssertTrue(
            CleanupEngine.looksLikeAnswer(input: dictatedRequest, output: output),
            "A rewrite with a fabricated answer appended must be rejected")
    }

    /// Negative control: a genuine, faithful cleanup of the same imperative request —
    /// same substance, tidier grammar — must still be accepted.
    func testAcceptsFaithfulRewriteOfTheSameRequest() {
        let output = """
        The following transcription is what Talkie just output to me. Please investigate \
        why this is happening — but before that, understand the core message of the last \
        one, because there was a prompt in it that I want to fire up in a different chat. \
        I need you to understand what it actually said and rewrite it so I can paste it. \
        After that, investigate why this is still happening.
        """
        XCTAssertFalse(
            CleanupEngine.looksLikeAnswer(input: dictatedRequest, output: output),
            "A faithful rewrite must not be mistaken for an answer")
    }

    /// A short dictation must not trip the growth guard just because cleanup expanded
    /// a couple of words (the absolute +5 floor).
    func testShortDictationIsNotTrippedByMinorExpansion() {
        let input = "send the report tomorrow morning"
        let output = "Please send the report tomorrow morning."
        XCTAssertFalse(
            CleanupEngine.looksLikeAnswer(input: input, output: output),
            "A small dictation with a minor expansion must not be rejected")
    }
}
