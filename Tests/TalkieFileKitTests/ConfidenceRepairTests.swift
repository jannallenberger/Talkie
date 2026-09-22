import XCTest
@testable import TalkieFileKit

final class ConfidenceRepairTests: XCTestCase {
    private func words(_ pairs: [(String, Double)]) -> [RecognizedWord] {
        pairs.map { RecognizedWord(text: $0.0, confidence: $0.1) }
    }

    // "im Worky einen neuen Branch" — only "Worky" is uncertain.
    private let sample: [(String, Double)] = [
        ("Kannst", 0.99), ("du", 1.0), ("im", 0.90), ("Worky", 0.71), ("einen", 0.98),
        ("neuen", 0.99), ("Branch", 0.89), ("anlegen", 0.91), (".", 0.99),
    ]

    func testSpansGroupOnlyLowConfidenceWords() {
        let spans = ConfidenceRepair.spans(words(sample), threshold: 0.75)
        XCTAssertEqual(spans.map(\.text), ["Worky"])
        XCTAssertEqual(spans.first?.range, 3..<4)
    }

    func testAdjacentUncertainWordsFormOneSpan() {
        let w = words([("wie", 0.87), ("wir", 0.85), ("die", 0.51), ("Wörter.", 0.64), ("nachträglich", 0.98)])
        XCTAssertEqual(ConfidenceRepair.spans(w, threshold: 0.75).map(\.text), ["die Wörter."])
    }

    func testPunctuationAloneNeverStartsASpan() {
        let w = words([("raus", 0.99), (".", 0.60), ("Und", 0.90)])
        XCTAssertTrue(ConfidenceRepair.spans(w, threshold: 0.75).isEmpty)
    }

    /// The core guarantee: whatever the model answers, only span tokens change.
    func testApplyNeverTouchesConfidentWords() {
        let w = words(sample)
        let spans = ConfidenceRepair.spans(w, threshold: 0.75)
        let out = ConfidenceRepair.apply(w, spans: spans, replacements: [1: "worktree"])
        XCTAssertEqual(out, "Kannst du im worktree einen neuen Branch anlegen.")
        XCTAssertEqual(ConfidenceRepair.apply(w, spans: spans, replacements: [:]),
                       "Kannst du im Worky einen neuen Branch anlegen.")
    }

    func testDeletionAndExtension() {
        let w = words([("you", 0.51), ("Okay,", 0.95), ("das", 0.98), ("von", 0.63), ("korrigiere.", 0.98)])
        let spans = ConfidenceRepair.spans(w, threshold: 0.75)
        XCTAssertEqual(ConfidenceRepair.apply(w, spans: spans, replacements: [1: "", 2: "von Hand"]),
                       "Okay, das von Hand korrigiere.")
    }

    func testPlausibilityRejectsTranslationsAndRewrites() {
        let vocab = ["CLAUDE.md", "worktree"]
        XCTAssertTrue(ConfidenceRepair.isPlausibleRepair(span: "die Wörter.", replacement: "die Wörter", vocabulary: vocab))
        XCTAssertTrue(ConfidenceRepair.isPlausibleRepair(span: "von", replacement: "von Hand", vocabulary: vocab))
        XCTAssertTrue(ConfidenceRepair.isPlausibleRepair(span: "ein", replacement: "einen", vocabulary: vocab))
        XCTAssertTrue(ConfidenceRepair.isPlausibleRepair(span: "CloudMD", replacement: "CLAUDE.md", vocabulary: vocab))
        XCTAssertTrue(ConfidenceRepair.isPlausibleRepair(span: "Lok", replacement: "Log", vocabulary: vocab))
        XCTAssertTrue(ConfidenceRepair.isPlausibleRepair(span: "you", replacement: "", vocabulary: vocab))
        // Translations and unrelated rewrites are refused.
        XCTAssertFalse(ConfidenceRepair.isPlausibleRepair(span: "von", replacement: "of", vocabulary: vocab))
        XCTAssertFalse(ConfidenceRepair.isPlausibleRepair(span: "ein", replacement: "a", vocabulary: vocab))
        XCTAssertFalse(ConfidenceRepair.isPlausibleRepair(span: "you", replacement: "also", vocabulary: vocab))
        XCTAssertFalse(ConfidenceRepair.isPlausibleRepair(span: "die Wörter.", replacement: "the words", vocabulary: vocab))
        // A multi-word span is never deleted wholesale.
        XCTAssertFalse(ConfidenceRepair.isPlausibleRepair(span: "die Wörter.", replacement: "", vocabulary: vocab))
    }

    /// Model habits measured on Jann's free recordings (2026-09-22).
    func testRefusesJargonifyingRealWordsCaseOnlyAndDroppedWords() {
        let vocab = ["Claude", "/loop", "worktree"]
        let ordinary: Set<String> = ["glaube", "Lock", "jetzt"]
        XCTAssertFalse(ConfidenceRepair.isPlausibleRepair(span: "glaube,", replacement: "Claude",
                                                          vocabulary: vocab, ordinaryWords: ordinary))
        XCTAssertFalse(ConfidenceRepair.isPlausibleRepair(span: "Lock", replacement: "/loop",
                                                          vocabulary: vocab, ordinaryWords: ordinary))
        XCTAssertFalse(ConfidenceRepair.isPlausibleRepair(span: "jetzt,", replacement: "Jetzt",
                                                          vocabulary: vocab, ordinaryWords: ordinary))
        XCTAssertFalse(ConfidenceRepair.isPlausibleRepair(span: "oder MD D", replacement: "oder",
                                                          vocabulary: vocab, ordinaryWords: ordinary))
        // A non-dictionary mishearing may still become a term.
        XCTAssertTrue(ConfidenceRepair.isPlausibleRepair(span: "Worray", replacement: "worktree",
                                                         vocabulary: vocab, ordinaryWords: ordinary))
        XCTAssertTrue(ConfidenceRepair.isPlausibleRepair(span: "Clau Claude", replacement: "Claude",
                                                         vocabulary: vocab, ordinaryWords: ordinary) == false,
                      "a stutter collapse shrinks the span — refused under the no-shrink rule")
    }

    func testParseDropsUnknownIdsAndBalloonedAnswers() {
        let w = words(sample)
        let spans = ConfidenceRepair.spans(w, threshold: 0.75)
        let parsed = ConfidenceRepair.parseReplacements(
            "1: worktree\n9: something\n", spans: spans, vocabulary: ["worktree"])
        XCTAssertEqual(parsed, [1: "worktree"])
        let ballooned = ConfidenceRepair.parseReplacements(
            "1: work tree in the new repo", spans: spans, vocabulary: [])
        XCTAssertTrue(ballooned.isEmpty)
    }

    func testCandidateHint() {
        XCTAssertEqual(ConfidenceRepair.candidate(for: "CloudMD", in: ["CLAUDE.md", "Supabase"]), "CLAUDE.md")
        XCTAssertNil(ConfidenceRepair.candidate(for: "Haus", in: ["CLAUDE.md", "Supabase"]))
        XCTAssertNil(ConfidenceRepair.candidate(for: "CLAUDE.md", in: ["CLAUDE.md"]), "no hint when already equal")
    }
}
