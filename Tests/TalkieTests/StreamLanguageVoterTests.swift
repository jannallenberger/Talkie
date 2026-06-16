import XCTest
@testable import Talkie

final class StreamLanguageVoterTests: XCTestCase {
    typealias W = StreamLanguageVoter.TimedWord

    // Deterministic params: 0.1s frames, ±0.1s (1-frame) smoothing.
    private func merge(_ words: [W]) -> [StreamLanguageVoter.Span] {
        StreamLanguageVoter.mergeWords(words, frame: 0.1, smoothingWindow: 0.1)
    }

    /// A German sentence with a single embedded English word ("deployment"). Each
    /// lane transcribes the whole span; the English word scores high only in the
    /// English lane. Word-level voting must keep German around it and English for it.
    func testSingleEmbeddedForeignWordRoutesIndependently() {
        let words: [W] = [
            // German lane
            W(localeID: "de-DE", text: "ich", start: 0.0, end: 0.3, confidence: 0.90),
            W(localeID: "de-DE", text: "das", start: 0.3, end: 0.6, confidence: 0.90),
            W(localeID: "de-DE", text: "deploi", start: 0.6, end: 1.0, confidence: 0.40),
            W(localeID: "de-DE", text: "gemacht", start: 1.0, end: 1.3, confidence: 0.90),
            // English lane (same audio)
            W(localeID: "en-US", text: "ish", start: 0.0, end: 0.3, confidence: 0.30),
            W(localeID: "en-US", text: "dass", start: 0.3, end: 0.6, confidence: 0.30),
            W(localeID: "en-US", text: "deployment", start: 0.6, end: 1.0, confidence: 0.95),
            W(localeID: "en-US", text: "gemakt", start: 1.0, end: 1.3, confidence: 0.30),
        ]
        let spans = merge(words)
        XCTAssertEqual(spans.map(\.localeID), ["de-DE", "en-US", "de-DE"])
        XCTAssertEqual(spans.map(\.text), ["ich das", "deployment", "gemacht"])
    }

    /// Mid-sentence switch (English half, German half) routes each half correctly.
    func testMidSentenceSwitch() {
        let words: [W] = [
            W(localeID: "en-US", text: "let", start: 0.0, end: 0.3, confidence: 0.92),
            W(localeID: "en-US", text: "us", start: 0.3, end: 0.6, confidence: 0.92),
            W(localeID: "en-US", text: "go", start: 0.6, end: 0.9, confidence: 0.92),
            W(localeID: "en-US", text: "es", start: 0.9, end: 1.2, confidence: 0.30),
            W(localeID: "en-US", text: "ist", start: 1.2, end: 1.5, confidence: 0.30),
            W(localeID: "en-US", text: "goot", start: 1.5, end: 1.8, confidence: 0.30),
            W(localeID: "de-DE", text: "lett", start: 0.0, end: 0.3, confidence: 0.30),
            W(localeID: "de-DE", text: "as", start: 0.3, end: 0.6, confidence: 0.30),
            W(localeID: "de-DE", text: "go", start: 0.6, end: 0.9, confidence: 0.30),
            W(localeID: "de-DE", text: "es", start: 0.9, end: 1.2, confidence: 0.93),
            W(localeID: "de-DE", text: "ist", start: 1.2, end: 1.5, confidence: 0.93),
            W(localeID: "de-DE", text: "gut", start: 1.5, end: 1.8, confidence: 0.93),
        ]
        let spans = merge(words)
        XCTAssertEqual(spans.map(\.localeID), ["en-US", "de-DE"])
        XCTAssertEqual(spans[0].text, "let us go")
        XCTAssertEqual(spans[1].text, "es ist gut")
    }

    /// A confidently monolingual stream: the wrong lane's low-confidence gibberish
    /// never wins, so the output is the clean English unchanged.
    func testMonolingualUnchanged() {
        let words: [W] = [
            W(localeID: "en-US", text: "this", start: 0.0, end: 0.3, confidence: 0.94),
            W(localeID: "en-US", text: "is", start: 0.3, end: 0.6, confidence: 0.94),
            W(localeID: "en-US", text: "english", start: 0.6, end: 1.0, confidence: 0.94),
            W(localeID: "de-DE", text: "diss", start: 0.0, end: 0.3, confidence: 0.40),
            W(localeID: "de-DE", text: "is", start: 0.3, end: 0.6, confidence: 0.40),
            W(localeID: "de-DE", text: "inglisch", start: 0.6, end: 1.0, confidence: 0.40),
        ]
        XCTAssertEqual(StreamLanguageVoter.mergedText(words.map { $0 }), "this is english")
    }

    func testEmptyInput() {
        XCTAssertEqual(StreamLanguageVoter.mergeWords([]).count, 0)
        XCTAssertEqual(StreamLanguageVoter.mergedText([]), "")
    }
}
