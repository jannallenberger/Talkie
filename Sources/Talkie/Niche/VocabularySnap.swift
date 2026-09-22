import Foundation
import TalkieFileKit

/// Live vocabulary snap: swaps a word the recognizer was UNSURE about (confidence
/// below 0.75) for one of the user's terms when it is spelled or sounds almost the
/// same ("kloud.m" → "CLAUDE.md", "Worktory" → "worktree"). The logic lives in
/// `ConfidenceRepair` (TalkieFileKit), measured with `talkie-bench --repair`: on
/// 806 words of Jann's dictation it made 7 fixes, all correct, and never touched a
/// confident word — the failure that got the always-on `NicheCorrector` switched
/// off. `TalkieFileKit` is imported only here: its `TimedSegment` would otherwise
/// collide with the app's.
enum VocabularySnap {
    /// On by default. Opt out: `defaults write com.coralate.talkie VocabularySnapOff -bool YES`
    static let disabledKey = "VocabularySnapOff"

    static var isEnabled: Bool { !UserDefaults.standard.bool(forKey: disabledKey) }

    /// Snap targets: the user's own terms only — every vocabulary entry plus the
    /// targets of rules they made by hand. Auto-learned rules are excluded
    /// outright: a learned "XCloud → iCloud" turned a clipped "kloud." into
    /// "iCloud" in the first live test, and learned rules are also where
    /// "in → ein" came from. To make a learned target snappable, add it to the
    /// vocabulary.
    static func terms(vocabulary: [String], replacements: [Replacement]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let targets = replacements
            .filter { !($0.learned ?? false) }
            .map { $0.to.trimmingCharacters(in: .whitespaces) }
        for term in vocabulary + targets where !term.isEmpty && seen.insert(term.lowercased()).inserted {
            out.append(term)
        }
        return out
    }

    /// Apply the snap to `text` using this dictation's per-word confidences.
    static func apply(to text: String, confidences: [WordConfidence], terms: [String],
                      isOrdinaryWord: (String) -> Bool) -> (text: String, fixes: [NicheFix]) {
        guard !confidences.isEmpty, !terms.isEmpty else { return (text, []) }
        let words = confidences.map { RecognizedWord(text: $0.word, confidence: $0.confidence) }
        let result = ConfidenceRepair.snapVocabulary(in: text, words: words, vocabulary: terms,
                                                     isOrdinaryWord: isOrdinaryWord)
        return (result.text, result.fixes.map { NicheFix(from: $0.from, to: $0.to) })
    }
}
