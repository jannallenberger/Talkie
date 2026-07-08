import XCTest
@testable import Talkie

/// Pure-logic tests for `SentenceFlow` — the de-seaming that stops Apple's
/// pause-induced periods from forcing sentence boundaries. No audio / model I/O.
final class SentenceFlowTests: XCTestCase {
    private func wordCount(_ s: String) -> Int {
        s.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }

    // MARK: stripSeams (AI path)

    func testStripSeamsDropsMidThoughtPeriodAndLowercasesContinuation() {
        let out = SentenceFlow.stripSeams(["I went to the store.", "And then I bought milk."])
        // The pause-seam period is gone; the genuine final period stays.
        XCTAssertEqual(out, "I went to the store and then I bought milk.")
    }

    func testStripSeamsKeepsSingleSegmentVerbatim() {
        XCTAssertEqual(SentenceFlow.stripSeams(["Hello there."]), "Hello there.")
    }

    func testStripSeamsEmpty() {
        XCTAssertEqual(SentenceFlow.stripSeams([]), "")
        XCTAssertEqual(SentenceFlow.stripSeams(["   ", ""]), "")
    }

    func testStripSeamsPreservesPronounI() {
        let out = SentenceFlow.stripSeams(["I think.", "I will go now."])
        XCTAssertEqual(out, "I think I will go now.")
    }

    func testStripSeamsPreservesAcronym() {
        let out = SentenceFlow.stripSeams(["Call the endpoint.", "API calls work."])
        // "API" stays uppercase; no period stranded mid-stream.
        XCTAssertEqual(out, "Call the endpoint API calls work.")
    }

    func testStripSeamsNeverDropsWords() {
        let segs = ["The quick brown fox.", "Jumps over.", "The lazy dog."]
        let out = SentenceFlow.stripSeams(segs)
        let inputWords = segs.flatMap { $0.split(separator: " ") }.count
        XCTAssertEqual(wordCount(out), inputWords, "no word may be lost while de-seaming")
        XCTAssertFalse(out.contains(". "), "no mid-stream sentence break should survive")
    }

    func testStripSeamsSkipsStrayPunctuationOnlySegment() {
        let out = SentenceFlow.stripSeams(["Hello.", ".", "world."])
        XCTAssertEqual(out, "Hello world.")
    }

    // MARK: mergeContinuations (deterministic, no-AI floor)

    func testMergeContinuationsMergesLowercaseContinuation() {
        let out = SentenceFlow.mergeContinuations(["I went to the store.", "and then I bought milk."])
        XCTAssertEqual(out, "I went to the store and then I bought milk.")
    }

    func testMergeContinuationsLowercasesCapitalizedConjunction() {
        let out = SentenceFlow.mergeContinuations(["I tried.", "But it failed."])
        XCTAssertEqual(out, "I tried but it failed.")
    }

    func testMergeContinuationsKeepsRealBoundary() {
        let out = SentenceFlow.mergeContinuations(["I went home.", "She was already there."])
        XCTAssertEqual(out, "I went home. She was already there.")
    }

    func testMergeContinuationsPreservesProperNounCasing() {
        // German: a real boundary before a capitalized noun must keep the noun cased.
        let out = SentenceFlow.mergeContinuations(["Ich ging zum Laden.", "Dann kaufte ich Milch."])
        XCTAssertTrue(out.contains("Milch"), "capitalized noun must survive (no model to re-case)")
        XCTAssertTrue(out.contains("Laden. Dann") || out.contains("Laden Dann"))
    }

    func testMergeContinuationsNeverDropsWords() {
        let segs = ["First part.", "and second.", "Third part."]
        let out = SentenceFlow.mergeContinuations(segs)
        let inputWords = segs.flatMap { $0.split(separator: " ") }.count
        XCTAssertEqual(wordCount(out), inputWords)
    }

    // A pause right after a lone "I" is the case Jann reported: the recognizer
    // finalizes "…I." and capitalizes the next word, but a bare "I" never ends a
    // sentence — so the deterministic floor (used when Apple Intelligence is off)
    // must drop the seam and lower-case the continuation.
    func testMergeContinuationsMergesDanglingPronounI() {
        let out = SentenceFlow.mergeContinuations(["I.", "Want to make a couple of changes."])
        XCTAssertEqual(out, "I want to make a couple of changes.")
    }

    func testMergeContinuationsMergesDanglingPronounIMidFragment() {
        let out = SentenceFlow.mergeContinuations(["So I", "Really need this."])
        XCTAssertEqual(out, "So I really need this.")
    }

    // A sentence can't end on an article, so the seam merges — but the word after
    // an article is often a (proper) noun, so its casing is preserved.
    func testMergeContinuationsMergesDanglingArticleKeepingCase() {
        let out = SentenceFlow.mergeContinuations(["I visited the.", "New York office."])
        XCTAssertEqual(out, "I visited the New York office.")
    }

    // The dangling-word rule must not clobber a genuine boundary: "me" (unlike "I")
    // can legitimately end a sentence, so "Call me. Now …" stays two sentences.
    func testMergeContinuationsKeepsBoundaryAfterObjectPronoun() {
        let out = SentenceFlow.mergeContinuations(["Call me.", "Now go home."])
        XCTAssertEqual(out, "Call me. Now go home.")
    }

    // "a" is intentionally NOT a dangling article: a sentence CAN end on it (the
    // letter/grade "A"), so two genuine sentences must not be welded together.
    func testMergeContinuationsKeepsBoundaryAfterLetterA() {
        let out = SentenceFlow.mergeContinuations(["I got an A.", "It was great."])
        XCTAssertEqual(out, "I got an A. It was great.")
    }

    // A dangling-"I" merge must still protect an acronym after it (never "aPI").
    func testMergeContinuationsProtectsAcronymAfterDanglingI() {
        let out = SentenceFlow.mergeContinuations(["I.", "API calls fail."])
        XCTAssertEqual(out, "I API calls fail.")
    }
}
