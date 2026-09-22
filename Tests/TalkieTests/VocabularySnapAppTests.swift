import XCTest
@testable import Talkie

/// App-side wiring of the vocabulary snap: which terms are eligible, and that it
/// runs on Talkie's own `WordConfidence` stream.
final class VocabularySnapAppTests: XCTestCase {
    func testTermsAreVocabularyPlusHandMadeRulesOnly() {
        let rules = [
            Replacement(from: "XCloud", to: "iCloud", learned: true),       // learned → never a target
            Replacement(from: "Istio", to: "ist die", learned: true),       // learned → never a target
            Replacement(from: "word tree", to: "worktree", learned: false), // hand-made → target
            Replacement(from: "get hub", to: "GitHub"),                     // legacy (no flag) → target
        ]
        let terms = VocabularySnap.terms(vocabulary: ["Supabase", "supabase", "CLAUDE.md"], replacements: rules)
        XCTAssertEqual(terms, ["Supabase", "CLAUDE.md", "worktree", "GitHub"])
    }

    func testAppliesOnlyToLowConfidenceWords() {
        let confidences = [
            WordConfidence(word: "Schau", confidence: 0.96), WordConfidence(word: "dir", confidence: 1),
            WordConfidence(word: "die", confidence: 0.99), WordConfidence(word: "kloud.m", confidence: 0.5),
            WordConfidence(word: "an,", confidence: 0.97), WordConfidence(word: "Cloud", confidence: 0.99),
        ]
        let (text, fixes) = VocabularySnap.apply(
            to: "Schau dir die kloud.m an, Cloud", confidences: confidences,
            terms: ["CLAUDE.md", "iCloud"], isOrdinaryWord: { _ in false })
        XCTAssertEqual(text, "Schau dir die CLAUDE.md an, Cloud", "the confident 'Cloud' is never touched")
        XCTAssertEqual(fixes, [NicheFix(from: "kloud.m", to: "CLAUDE.md")])
    }

    func testNoConfidencesMeansNoChange() {
        let (text, fixes) = VocabularySnap.apply(to: "die kloud.m", confidences: [], terms: ["CLAUDE.md"],
                                                 isOrdinaryWord: { _ in false })
        XCTAssertEqual(text, "die kloud.m")
        XCTAssertTrue(fixes.isEmpty)
    }
}
