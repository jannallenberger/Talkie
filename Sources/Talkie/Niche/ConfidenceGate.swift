import Foundation

/// One recognized word paired with the recognizer's per-word
/// `transcriptionConfidence`. Sendable so the `TranscriptionEngine` actor can
/// hand the finalized session's confidences across the isolation boundary to the
/// main-actor gate without copying a store or a non-Sendable `AttributedString`.
///
/// `confidence` is Apple's `SpeechTranscriber` per-run confidence — its
/// calibration at the low end is not documented, which is exactly why the gate
/// below is deliberately conservative and its floor is a single tunable constant.
struct WordConfidence: Sendable, Equatable {
    let word: String
    let confidence: Double
}

/// The **low-confidence review gate** (A12): a pure decision that answers one
/// question — "was the recognizer visibly unsure about a small number of jargon-
/// like words, such that offering a tap-to-fix chip would help more than it
/// nags?" It is the shippable heart of the feature; the HUD chip and the engine
/// plumbing are wiring around this function.
///
/// Design stance: a chip that fires on ordinary speech is worse than no chip at
/// all, so every rule here errs toward *not* firing. The floor value that
/// separates "unsure" from "fine" cannot be calibrated headless — it needs
/// Jann's real dictations — so it lives in one named constant
/// (`ConfidenceGate.floor`) marked `// TUNE:` and starts conservative.
///
/// Pure and synchronous: no disk, no clock, no recognizer. That is what
/// `ConfidenceGateTests` pins exhaustively.
enum ConfidenceGate {
    /// Confidence below which a word counts as "the recognizer was unsure".
    ///
    /// TUNE: 0.35 is a conservative starting floor, NOT a calibrated value.
    /// `SpeechTranscriber`'s per-word confidence calibration at the low end is
    /// undocumented, and the true floor depends on how often it dips on words the
    /// user actually got right. It must be tuned against a day of Jann's real
    /// sessions (the acceptance target: the chip fires on < 10% of ordinary
    /// dictations) before this feature's chip should be considered load-bearing.
    /// Raising it makes the chip fire more; lowering it makes it fire less.
    static let floor: Double = 0.35

    /// A flagged word must be at least this many letters — shorter tokens are
    /// function words / fillers where a low confidence is noise, not jargon.
    static let minWordLength = 4

    /// The dictation must be at least this many words for the chip to fire. Below
    /// this it's almost always a command or a one-liner, where a review chip is
    /// pure interruption.
    static let minDictationWords = 6

    /// Fire only when a *small* number of words are unsure. Many low-confidence
    /// words means the whole utterance was mumbled/mis-mic'd — not a spot-fix
    /// situation, and flagging five words is a wall, not a nudge.
    static let maxFlagged = 3

    /// The outcome of evaluating one finalized dictation.
    struct Decision: Equatable {
        /// The words to offer for review, in transcript order, capped at
        /// `maxFlagged`. Empty iff `shouldShowChip` is false.
        let flaggedWords: [String]
        /// Whether the HUD should actually surface the review chip.
        var shouldShowChip: Bool { !flaggedWords.isEmpty }
    }

    /// Decide whether — and for which words — to offer the review chip.
    ///
    /// - Parameters:
    ///   - wordConfidences: the finalized session's per-word confidences, in
    ///     spoken order (what the recognizer heard, before cleanup/dictionary).
    ///   - alreadyFixed: canonical spellings the niche corrector (or dictionary)
    ///     already swapped in THIS session. A heard word whose fix is among these
    ///     is suppressed — the correction path already did its job, so nagging to
    ///     "fix" it would be wrong. Compared case-insensitively against both the
    ///     heard word and (defensively) itself.
    ///   - commonWords: high-frequency words that should never be flagged even at
    ///     low confidence (defaults to the shared `NicheTermGuard` basis) — the
    ///     model nails these, so a confidence dip on one is a calibration artifact.
    static func evaluate(
        wordConfidences: [WordConfidence],
        alreadyFixed: [String] = [],
        commonWords: Set<String> = NicheTermGuard.default.commonWords
    ) -> Decision {
        // Total spoken length gates everything: never offer review on a command or
        // a terse one-liner. Uses the confidence count as the word count — it is
        // exactly the recognizer's own tokenization of what it heard.
        guard wordConfidences.count >= minDictationWords else { return Decision(flaggedWords: []) }

        let fixedSet = Set(alreadyFixed.map { normalized($0) })

        var flagged: [String] = []
        var seen = Set<String>()
        for wc in wordConfidences {
            let word = wc.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isWordLike(word) else { continue }
            guard word.count >= minWordLength else { continue }
            guard wc.confidence < floor else { continue }
            let key = normalized(word)
            // A common word the recognizer nails — a low confidence on it is a
            // calibration artifact, not jargon. Never review it.
            guard !commonWords.contains(key) else { continue }
            // Suppress words the corrector already fixed this session, and any
            // whose canonical fix equals this heard token.
            guard !fixedSet.contains(key) else { continue }
            // De-dup: the same unsure word twice is still one thing to review.
            guard seen.insert(key).inserted else { continue }
            flagged.append(word)
        }

        // A *small* number of unsure words is a spot-fix; a large number means the
        // whole utterance was off — not a chip situation. Firing nothing here is
        // the safe default the feature is tuned around.
        guard !flagged.isEmpty, flagged.count <= maxFlagged else {
            return Decision(flaggedWords: [])
        }
        return Decision(flaggedWords: flagged)
    }

    // MARK: Pure helpers

    /// Lowercased, whitespace-trimmed — the single normalization used for
    /// de-duplication and already-fixed comparison so callers never disagree.
    static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True if `word` is a plausible lexical token worth reviewing: it must carry
    /// at least one letter and contain only letters, digits, or the joiners that
    /// show up inside real jargon (`-`, `_`, `.`, `/`). This rejects bare
    /// punctuation and number-only tokens (a low-confidence "2024" is not a
    /// spelling the dictionary can help with).
    static func isWordLike(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        var hasLetter = false
        for scalar in word.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                hasLetter = true
            } else if CharacterSet.decimalDigits.contains(scalar) {
                continue
            } else if scalar == "-" || scalar == "_" || scalar == "." || scalar == "/" {
                continue
            } else {
                return false
            }
        }
        return hasLetter
    }
}
