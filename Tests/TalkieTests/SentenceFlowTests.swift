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
}
