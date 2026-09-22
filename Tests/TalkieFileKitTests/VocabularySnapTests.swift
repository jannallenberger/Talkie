import XCTest
@testable import TalkieFileKit

/// The instant, model-free vocabulary snap on uncertain spans. Cases are real
/// mishearings from Jann's dictations (2026-09-21/22) and the real words a first
/// calibration wrongly snapped.
final class VocabularySnapTests: XCTestCase {
    private let vocab = ["CLAUDE.md", "worktree", "Testflight-Build", "Pull Request", "Supabase",
                         "Higgsfield", "iCloud", "Prisma", "Anthropic", "Arno", "Next.js", "Talkie", "Claude"]
    /// Stand-in for the spell checker: the everyday words from the calibration.
    private let ordinary: Set<String> = ["Cloud", "Prima", "Arne", "Wörter", "jetzt", "nächsten", "anderes", "Talking", "Worte"]

    private func snap(_ text: String) -> String? {
        let span = UncertainSpan(id: 1, range: 0..<1, text: text)
        return ConfidenceRepair.vocabularySnaps([span], vocabulary: vocab,
                                                isOrdinaryWord: { self.ordinary.contains($0) })[1]
    }

    func testRealMishearingsSnapToTheTerm() {
        XCTAssertEqual(snap("CloudMD"), "CLAUDE.md")
        XCTAssertEqual(snap("Cloud MD"), "CLAUDE.md")
        XCTAssertEqual(snap("kloud.m"), "CLAUDE.md")
        XCTAssertEqual(snap("Cloud.m"), "CLAUDE.md")
        XCTAssertEqual(snap("Worktory"), "worktree")
        XCTAssertEqual(snap("Workree"), "worktree")
        XCTAssertEqual(snap("word tree"), "worktree")
        XCTAssertEqual(snap("Test-flight-Bild"), "Testflight-Build")
        XCTAssertEqual(snap("PullRquest"), "Pull Request")
        XCTAssertEqual(snap("Pool request"), "Pull Request")
        XCTAssertEqual(snap("Higgs field"), "Higgsfield")
    }

    func testEverydayWordsNeverSnap() {
        for word in ["Cloud", "Prima", "Arne", "Wörter", "jetzt", "nächsten", "anderes", "Talking", "Worte",
                     "Bild", "Build", "Lok", "Lock", "die", "von", "ein"] {
            XCTAssertNil(snap(word), word)
        }
    }

    /// Live regression (2026-09-22): the recognizer clipped "CLAUDE.md" to "kloud."
    /// and the snap picked "iCloud". A 5-letter span needs a near-exact match.
    func testClippedShortSpanDoesNotSnapToANeighbor() {
        XCTAssertNil(snap("kloud."))
        XCTAssertNil(snap("Kloud"))
    }

    func testShortAndIdenticalTokensAreLeftAlone() {
        XCTAssertNil(snap("Log"))
        XCTAssertNil(snap("Claude"), "already the term")
    }

    func testApplyingSnapsKeepsTrailingMarkAndConfidentNeighbors() {
        let words = [RecognizedWord(text: "die", confidence: 0.99),
                     RecognizedWord(text: "kloud.m,", confidence: 0.4),
                     RecognizedWord(text: "damit", confidence: 1)]
        let spans = ConfidenceRepair.spans(words, threshold: 0.75)
        let snaps = ConfidenceRepair.vocabularySnaps(spans, vocabulary: vocab)
        let out = ConfidenceRepair.applyingSnaps(words, spans: spans, snaps: snaps)
        XCTAssertEqual(out.map(\.text), ["die", "CLAUDE.md,", "damit"])
        XCTAssertTrue(out.allSatisfy { $0.confidence >= 0.75 }, "a snapped span is settled for the model pass")
    }

    // MARK: Text-level entry point (the live pipeline)

    private func w(_ pairs: [(String, Double)]) -> [RecognizedWord] {
        pairs.map { RecognizedWord(text: $0.0, confidence: $0.1) }
    }

    func testSnapsInFinalTextAndLeavesConfidentWords() {
        let words = w([("Schau", 0.96), ("dir", 1), ("vorher", 1), ("die", 0.99), ("Cloud.MD", 0.57),
                       ("an,", 0.97), ("im", 0.9), ("Worktory", 0.6), ("einen", 0.98), ("Branch", 0.89)])
        let text = "Schau dir vorher die Cloud.MD an, im Worktory einen Branch"
        let (out, fixes) = ConfidenceRepair.snapVocabulary(in: text, words: words, vocabulary: vocab,
                                                           isOrdinaryWord: { self.ordinary.contains($0) })
        XCTAssertEqual(out, "Schau dir vorher die CLAUDE.md an, im worktree einen Branch")
        XCTAssertEqual(fixes.map(\.to), ["CLAUDE.md", "worktree"])
    }

    func testToleratesSpacingChangedByEarlierStages() {
        // Recognizer tokens "Pull-Request" "?" were tightened to "Pull-Request?" upstream.
        let words = w([("einen", 0.99), ("Pull-Request", 0.63), ("?", 0.9)])
        let (out, _) = ConfidenceRepair.snapVocabulary(in: "einen Pull-Request?", words: words,
                                                       vocabulary: vocab, isOrdinaryWord: { _ in false })
        XCTAssertEqual(out, "einen Pull Request?")
    }

    func testNoOpWhenTextNoLongerContainsTheSpan() {
        let words = w([("die", 0.99), ("kloud.m", 0.4)])
        let (out, fixes) = ConfidenceRepair.snapVocabulary(in: "die Datei", words: words, vocabulary: vocab,
                                                           isOrdinaryWord: { _ in false })
        XCTAssertEqual(out, "die Datei")
        XCTAssertTrue(fixes.isEmpty)
    }

    func testOnlyTheUncertainOccurrenceIsReplaced() {
        // The same word appears twice; only the low-confidence one is a span.
        let words = w([("Worktory", 0.95), ("und", 1), ("Worktory", 0.5)])
        let (out, _) = ConfidenceRepair.snapVocabulary(in: "Worktory und Worktory", words: words,
                                                       vocabulary: vocab, isOrdinaryWord: { _ in false })
        XCTAssertEqual(out, "Worktory und worktree")
    }

    func testMatchesWholeWordsOnly() {
        let words = w([("Worktory", 0.5)])
        let (out, _) = ConfidenceRepair.snapVocabulary(in: "XWorktory Worktory", words: words,
                                                       vocabulary: vocab, isOrdinaryWord: { _ in false })
        XCTAssertEqual(out, "XWorktory worktree")
    }

    func testColognePhoneticKnownCodes() {
        // Reference values from the Kölner Phonetik definition.
        XCTAssertEqual(ConfidenceRepair.colognePhonetic("müller"), "657")
        XCTAssertEqual(ConfidenceRepair.colognePhonetic("wikipedia"), "3412")
    }
}
