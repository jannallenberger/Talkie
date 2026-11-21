import XCTest
@testable import Talkie

/// Order versus the cleanup model: the decision is taken on the recognizer's text, the
/// model only ever sees the characters, and a model that loses or duplicates one is
/// overruled. Fake models only; nothing touches Application Support.
final class SpokenPunctuationPipelineTests: XCTestCase {

    /// What the Neutral prompt licenses: re-derive punctuation (drop the recognizer's
    /// commas), "fix grammar". Here: drop every comma.
    private let neutralLike: @Sendable (String) async -> String? = { $0.replacingOccurrences(of: ",", with: "") }

    func testDecisionIsTakenOnTheRecognizersTextBeforeTheModel() async {
        let seen = Recorder()
        let out = await SpokenPunctuation.aroundModel("Hallo, Doppelpunkt, das ist ein Test.", languageCode: "de",
                                                      structural: true) { text in
            await seen.record(text)
            return text
        }
        let input = await seen.values
        XCTAssertEqual(input, ["Hallo: das ist ein Test."])   // the model never sees the word
        XCTAssertEqual(out, "Hallo: das ist ein Test.")
    }

    func testAModelThatDropsTheCommasCannotChangeTheDecision() async {
        // Raw: the commas say "on its own" -> colon. The model would have erased that signal
        // ("Hallo Doppelpunkt das" is still a command, but "neue Zeile" without its commas
        // is not); because the decision came first, the result is the same.
        let out = await SpokenPunctuation.aroundModel("Erste Zeile, neue Zeile, zweite Zeile, Doppelpunkt, ende",
                                                      languageCode: "de", structural: true, model: neutralLike)
        XCTAssertEqual(out, "Erste Zeile\nzweite Zeile: ende")
    }

    func testNothingReDecidesOnTheModelsText() async {
        // A literal sentence; the model adds commas around the word. The pipeline result is
        // the model's text: no second pass turns its commas into a command.
        let raw = "Setz bitte einen Doppelpunkt hinter Hallo"
        let out = await SpokenPunctuation.aroundModel(raw, languageCode: "de", structural: true) { _ in
            "Setz bitte, Doppelpunkt, hinter Hallo."
        }
        XCTAssertEqual(out, "Setz bitte, Doppelpunkt, hinter Hallo.")
    }

    func testAModelThatLosesAnInsertedCharacterIsOverruled() async {
        let out = await SpokenPunctuation.aroundModel("Dann Klammer auf wie gesagt Klammer zu geht das.",
                                                      languageCode: "de", structural: true) { text in
            text.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        }
        XCTAssertEqual(out, "Dann (wie gesagt) geht das.")
    }

    func testAModelThatDuplicatesAnInsertedCharacterIsOverruled() async {
        let out = await SpokenPunctuation.aroundModel("Hallo Doppelpunkt das ist ein Test", languageCode: "de",
                                                      structural: true) { text in
            text.replacingOccurrences(of: ":", with: "::")
        }
        XCTAssertEqual(out, "Hallo: das ist ein Test")
    }

    func testAModelThatJoinsTheLinesIsOverruled() async {
        let out = await SpokenPunctuation.aroundModel("First part, new paragraph, second part.", languageCode: "en",
                                                      structural: true) { $0.replacingOccurrences(of: "\n", with: " ") }
        XCTAssertEqual(out, "First part\n\nsecond part.")
    }

    func testAModelRewriteThatKeepsTheCharactersIsUsed() async {
        let out = await SpokenPunctuation.aroundModel("hallo Doppelpunkt das ist ein test", languageCode: "de",
                                                      structural: true) { _ in "Hallo: Das ist ein Test." }
        XCTAssertEqual(out, "Hallo: Das ist ein Test.")
    }

    func testNoModelOrAFailedModelKeepsTheConvertedText() async {
        let out = await SpokenPunctuation.aroundModel("sicher, Fragezeichen, ja", languageCode: "de",
                                                      structural: true) { _ in nil }
        XCTAssertEqual(out, "sicher? Ja")
    }

    func testWithoutAnyTriggerTheModelIsUnconstrained() async {
        // No inserted character: the guard never rejects an ordinary rewrite.
        let out = await SpokenPunctuation.aroundModel("ich glaube wir sollten gehen", languageCode: "de",
                                                      structural: true) { _ in "Ich glaube, wir sollten gehen: jetzt!" }
        XCTAssertEqual(out, "Ich glaube, wir sollten gehen: jetzt!")
    }

    func testBatchesShareTheWholeTextsDecision() async {
        // Long dictations are split into batches after the decision: each batch is only
        // checked, never converted again.
        let raw = "Hallo, Doppelpunkt, eins. Und dann noch mehr Text."
        let converted = SpokenPunctuation.beforeModel(raw, languageCode: "de", structural: true)
        let marks = SpokenPunctuation.inserted(raw: raw, converted: converted)
        XCTAssertEqual(marks, [":"])
        let batch2 = await SpokenPunctuation.guardedModel("Und dann noch mehr Text.", marks: marks) { _ in "Und dann: mehr Text." }
        XCTAssertEqual(batch2, "Und dann noch mehr Text.")   // the model invented a ":" -> overruled
    }

    func testFormatSpansUseTheSameOrderThroughTheCleanupSeam() async {
        // The format assembler's cleanup seam with a comma-dropping fake model, wrapped the
        // way AppDelegate.formatPlan wraps it.
        let seg = TimedSegment(text: "note alles groß hallo, doppelpunkt, wichtig", start: 0, end: 4, words: [
            SegmentWord(text: "note", start: 0, end: 0.4),
            SegmentWord(text: " alles", start: 1.0, end: 1.3),
            SegmentWord(text: " groß", start: 1.35, end: 1.7),
            SegmentWord(text: " hallo,", start: 2.2, end: 2.6),
            SegmentWord(text: " doppelpunkt,", start: 2.7, end: 3.2),
            SegmentWord(text: " wichtig", start: 3.3, end: 3.7),
        ])
        let fake = neutralLike
        let plan = await FormatDictationAssembler.assemble(
            segments: [seg], marks: [.span(start: 0.9, end: 1.8)],
            clean: { text in await SpokenPunctuation.aroundModel(text, languageCode: "de", structural: false, model: fake) },
            postProcessFormatted: { $0 },
            languageCode: "de", userName: "", model: { _, _, _ in nil })
        XCTAssertEqual(plan.parts.last, .formatted(.init(text: "HALLO: WICHTIG", isBlock: false)))
    }
}

private actor Recorder {
    var values: [String] = []
    func record(_ s: String) { values.append(s) }
}
