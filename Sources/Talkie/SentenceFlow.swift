import Foundation

/// Reassembles the finalized recognizer segments into the text handed downstream,
/// neutralizing the *pause-induced* sentence boundaries Apple's `SpeechTranscriber`
/// bakes in.
///
/// The transcriber finalizes a segment — ending it with a period — every time the
/// speaker pauses ~2s to think, even mid-thought. We never want a pause to be the
/// thing that decides a sentence ends; grammar should. So before the text is
/// punctuated (by the on-device cleanup model, or — when that's unavailable — by a
/// conservative deterministic rule) we drop the punctuation sitting *at a segment
/// seam* (a pause), leaving the words on either side flowing together.
///
/// A "seam" is the join between two finalized segments. Punctuation *inside* a
/// segment is never touched — the speaker didn't pause there, so it's real.
enum SentenceFlow {
    /// Terminators Apple appends at a pause boundary.
    private static let seamTerminators: Set<Character> = [".", "!", "?", "…"]

    /// Capitalized words that, when they begin the fragment *after* a pause, almost
    /// always continue the previous thought rather than start a new sentence.
    /// Used only by the deterministic (no-AI) path to decide whether to drop a seam.
    private static let continuationWords: Set<String> = [
        "and", "but", "so", "or", "nor", "because", "which", "that",
        "then", "though", "although", "yet", "plus", "while", "whereas",
    ]

    /// **AI path.** Join the segments into ONE continuous stream with the pause-seam
    /// punctuation removed and the following fragment de-capitalized, so the cleanup
    /// model re-punctuates and re-capitalizes from scratch by grammar (its
    /// instructions already say pauses are not sentence boundaries). Leaving a stray
    /// terminal period — or a mid-stream capital — would re-anchor the model into
    /// reinstating the very boundary we're trying to remove. The model owns final
    /// casing, so de-capitalizing the seam is safe even before a proper noun.
    static func stripSeams(_ segments: [String]) -> String {
        let frags = normalize(segments)
        guard frags.count > 1 else { return frags.first ?? "" }

        let lastIndex = frags.count - 1
        var pieces: [String] = []
        pieces.reserveCapacity(frags.count)
        for (i, frag) in frags.enumerated() {
            // The final fragment's trailing punctuation is the genuine end of the
            // utterance, not a seam — keep it. Every earlier fragment ends at a pause.
            var f = (i == lastIndex) ? frag : stripTrailingTerminators(frag)
            if i > 0 { f = deCapitalizeLeading(f) }
            let trimmed = f.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { pieces.append(trimmed) }
        }
        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// **Deterministic floor (no AI / model unavailable).** Conservative: drop a seam
    /// period *only* when the next fragment clearly continues the thought (it starts
    /// lower-case, or with a known continuation word). Otherwise the seam is left as a
    /// real boundary. Never lower-cases anything, so capitalized nouns (e.g. German)
    /// survive when there's no model to re-case them. Never drops words.
    static func mergeContinuations(_ segments: [String]) -> String {
        let frags = normalize(segments)
        guard frags.count > 1 else { return frags.first ?? "" }

        var out = frags[0]
        for frag in frags.dropFirst() {
            let decision = mergeDecision(next: frag)
            if decision.merge {
                let lead = decision.lowercaseLead ? lowercaseFirst(frag) : frag
                out = stripTrailingTerminators(out) + " " + lead
            } else {
                out += " " + frag
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Internals

    private static func normalize(_ segments: [String]) -> [String] {
        segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Whether to drop the seam period before `next`, and whether the leading word
    /// is safe to lower-case (a capitalized conjunction like "But" is; a proper noun
    /// is not, so it falls through to `keep`).
    private static func mergeDecision(next: String) -> (merge: Bool, lowercaseLead: Bool) {
        guard let word = leadingWord(next) else { return (false, false) }
        if startsLowercase(word) { return (true, false) }
        if continuationWords.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            return (true, true) // capitalized conjunction → safe to lower-case on merge
        }
        return (false, false)
    }

    private static func lowercaseFirst(_ s: String) -> String {
        guard let first = s.first, first.isUppercase else { return s }
        return String(first).lowercased() + s.dropFirst()
    }

    /// Drop trailing seam terminators (and any trailing whitespace) from a fragment.
    private static func stripTrailingTerminators(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            let c = s[prev]
            if seamTerminators.contains(c) || c == " " || c == "\t" {
                end = prev
            } else {
                break
            }
        }
        return String(s[s.startIndex..<end])
    }

    /// Lower-case the first letter so a sentence-start capital doesn't re-anchor a
    /// new sentence — except the English pronoun "I"/"I'm"/… and all-caps acronyms.
    private static func deCapitalizeLeading(_ s: String) -> String {
        guard let first = s.first, first.isUppercase else { return s }
        let word = leadingWord(s) ?? ""
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return s }
        // Keep acronyms (API, US, NASA) — 2+ chars that are all uppercase letters.
        let letters = word.filter { $0.isLetter }
        if letters.count >= 2, letters.allSatisfy({ $0.isUppercase }) { return s }
        return String(first).lowercased() + s.dropFirst()
    }

    private static func leadingWord(_ s: String) -> String? {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first.map(String.init)
    }

    private static func startsLowercase(_ word: String) -> Bool {
        guard let f = word.first, f.isLetter else { return false }
        return f.isLowercase
    }
}
