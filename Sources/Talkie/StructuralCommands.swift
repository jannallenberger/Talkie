import Foundation

/// Deterministic structural-dictation commands: saying "new line" or "new
/// paragraph" mid-dictation produces an actual line break / blank line in the
/// inserted text, instead of the words landing literally. Dragon-parity, with
/// zero UI.
///
/// A sibling of `NumberNormalizer` — a deterministic, always-on, bilingual
/// (English + German) post-cleanup pass with its own test file. It runs in every
/// cleanup mode (cleanup on or off, model available or not), because a
/// structural command is the user's explicit intent about layout and must not
/// depend on whether the on-device model happened to run.
///
/// EXACTLY two commands, by design (resisting tab/bullet/"cap that" sprawl):
///   - "new line" / "newline"  → "\n"   (EN);  "neue Zeile"  → "\n"   (DE)
///   - "new paragraph"         → "\n\n"  (EN);  "neuer Absatz" → "\n\n" (DE)
///
/// ## The trigger rule (why this is a false-positive-safe pass)
/// The phrase fires ONLY when it is a *free-standing* utterance fragment — i.e.
/// it is delimited by a **hard boundary on both sides**. A hard boundary is
/// either the start/end of the whole text, or sentence punctuation sitting right
/// next to the phrase (`.` `!` `?` `…`, and the `,` `;` `:` a cleanup pass tends
/// to sprinkle in). A bare adjacent *word* on either side is a soft boundary and
/// disqualifies the match — so the phrase stays literal inside a noun phrase:
///
///   - "the new line manager approved"      → unchanged (word "the" before, "manager" after)
///   - "a new paragraph of the contract"    → unchanged (word "a" before, "of" after)
///   - "please add a new line here"         → unchanged (word "a" before, "here" after)
///   - "world. New line. Hello"             → "world\nHello"  (period on both sides)
///   - "New paragraph. Then sign it."       → "\nThen sign it." (utterance start + period)
///
/// This is deliberately conservative: a bare "new line here" with NO surrounding
/// punctuation does not trigger, because that is exactly where a false positive
/// would be most costly. In real use a spoken structural command arrives with a
/// pause, so cleanup renders it as its own sentence ("… . New line. …") — the
/// both-hard-boundary shape this pass is tuned for.
///
/// ## Swallowing cleanup punctuation + capitalization
/// When a sentence terminator is consumed as (part of) the boundary, the break
/// replaces it and the *following* word is capitalized, so "world. New line.
/// hello" reads as "world\nHello" rather than leaving an orphaned lowercase
/// start. Commas/colons that merely abutted the phrase are swallowed too, so no
/// stray ", " survives around the break.
///
/// ## Idempotency
/// The pass keys off the literal words "new line" / "new paragraph". If cleanup
/// already turned the spoken command into an actual break (leaving no literal
/// phrase behind), there is nothing to match and no second break is inserted —
/// running the pass twice yields the same result.
enum StructuralCommands {

    /// The replacement a matched phrase expands to.
    private enum Break {
        case line       // "\n"
        case paragraph  // "\n\n"

        var text: String { self == .line ? "\n" : "\n\n" }
    }

    /// Sentence punctuation that counts as a "hard" boundary next to a phrase.
    /// Includes the terminators a real sentence end carries (`.!?…`) plus the
    /// separators a cleanup pass adds around a parenthetical command (`,;:`).
    private static let boundaryPunctuation: Set<Character> = [
        ".", "!", "?", "…", ",", ";", ":",
    ]

    /// Terminators whose consumption implies the break started a *new* sentence,
    /// so the following word should be capitalized. A comma/colon does not.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]

    /// Apply the structural-command pass.
    ///
    /// - Parameters:
    ///   - text: the (already cleaned + dictionary-processed) transcript.
    ///   - languageCode: the base language code in scope at the call site
    ///     (`"en"`, `"de"`, …) or `nil` when unknown. German phrases fire only
    ///     for `"de"`; English phrases fire for `"en"` and for `nil`/unknown,
    ///     because the app is English-primary and the English phrases are
    ///     distinctive enough to be safe as the default.
    static func apply(_ text: String, languageCode: String?) -> String {
        guard !text.isEmpty else { return text }

        let allowGerman = (languageCode == "de")
        // English is the default for nil/unknown; German is additive when the
        // language is actually German. (In practice a transcript is one language,
        // so the two phrase sets never collide.)
        let allowEnglish = !allowGerman || languageCode == "en"

        let (gaps, words) = tokenize(text)
        guard !words.isEmpty else { return text }

        // Rebuild the string left to right. When a phrase matches at word `i`,
        // emit the break (having decided, from the surrounding gaps, whether the
        // boundary was hard) and skip the phrase's words; otherwise copy the word
        // and its trailing gap through unchanged.
        var out = ""
        // Whether the previous emission ended by opening a fresh sentence (a break
        // that consumed a terminator, or the very start of the text), so the next
        // word inherits a capital.
        var capitalizeNext = false
        // The gap text still owed to the output — deferred so a following match can
        // decide to swallow it as part of its leading boundary.
        var pendingGap = gaps[0]

        var i = 0
        while i < words.count {
            if let match = matchPhrase(at: i, words: words, allowEnglish: allowEnglish, allowGerman: allowGerman) {
                let phraseEnd = i + match.wordCount            // one past the last phrase word
                let leadingGap = pendingGap                    // gap before the phrase
                let trailingGap = gaps[phraseEnd]              // gap after the phrase

                let atStart = isEffectivelyStart(out: out, leadingGap: leadingGap)
                let atEnd = (phraseEnd == words.count) && isBlankOrPunctuation(trailingGap)

                let (beforeHard, beforeTerminator) = boundaryBefore(leadingGap, atStart: atStart)
                let (afterHard, afterTerminator) = boundaryAfter(trailingGap, atEnd: atEnd)

                if beforeHard && afterHard {
                    // Command fires: drop the surrounding punctuation/whitespace and
                    // emit the break in its place.
                    out = trimTrailingBoundary(out)
                    out += match.kind.text
                    // Capitalize the next word when EITHER side consumed a real
                    // sentence terminator (a break that starts a new sentence).
                    capitalizeNext = beforeTerminator || afterTerminator
                    // The trailing gap is absorbed into the boundary — start the
                    // next iteration with a clean owed gap.
                    pendingGap = whitespaceOnly(trailingGap)
                    i = phraseEnd
                    continue
                }
                // Not a free-standing command — fall through and copy it literally.
            }

            // Copy this word (and any owed gap) through verbatim.
            out += pendingGap
            var word = words[i]
            if capitalizeNext {
                word = capitalizeFirst(word)
                capitalizeNext = false
            }
            out += word
            pendingGap = gaps[i + 1]
            i += 1
        }
        // Flush the final owed gap (unless it was a punctuation boundary already
        // consumed by a trailing command, in which case it's whitespace-only).
        out += pendingGap
        return out
    }

    // MARK: - Phrase matching

    private struct Match {
        let kind: Break
        let wordCount: Int  // how many word tokens the phrase spans
    }

    /// Does a structural phrase begin exactly at word `start`? Matches the
    /// single-word forms ("newline") and the two-word forms ("new line", "new
    /// paragraph", "neue Zeile", "neuer Absatz"), requiring the interior gap of a
    /// two-word phrase to be a plain space (not punctuation), so "new. line" is
    /// never fused.
    private static func matchPhrase(at start: Int, words: [String],
                                    allowEnglish: Bool, allowGerman: Bool) -> Match? {
        let w0 = words[start].lowercased()

        // Single-word English "newline".
        if allowEnglish, w0 == "newline" { return Match(kind: .line, wordCount: 1) }

        guard start + 1 < words.count else { return nil }
        let w1 = words[start + 1].lowercased()

        if allowEnglish {
            if w0 == "new" && w1 == "line" { return Match(kind: .line, wordCount: 2) }
            if w0 == "new" && w1 == "paragraph" { return Match(kind: .paragraph, wordCount: 2) }
        }
        if allowGerman {
            // "neue Zeile" (and the case the recognizer might hand back "neuer
            // Zeile"); "neuer Absatz". Match the adjective loosely on its stem so a
            // declension variant still lands, but keep the noun exact.
            let neu = (w0 == "neue" || w0 == "neuer" || w0 == "neues")
            if neu && w1 == "zeile" { return Match(kind: .line, wordCount: 2) }
            if neu && w1 == "absatz" { return Match(kind: .paragraph, wordCount: 2) }
        }
        return nil
    }

    // MARK: - Boundary analysis

    /// Whether the phrase sits at the effective start of the text: nothing but
    /// whitespace has been emitted so far and the leading gap is whitespace-only.
    private static func isEffectivelyStart(out: String, leadingGap: String) -> Bool {
        out.allSatisfy(\.isWhitespace) && leadingGap.allSatisfy(\.isWhitespace)
    }

    /// A gap that is only whitespace, or whitespace plus boundary punctuation
    /// (i.e. carries no other characters). Used to decide the trailing edge really
    /// is the end of the utterance.
    private static func isBlankOrPunctuation(_ gap: String) -> Bool {
        gap.allSatisfy { $0.isWhitespace || boundaryPunctuation.contains($0) }
    }

    /// Classify the boundary on the *before* side of a phrase from the gap that
    /// precedes it. Hard when at the text start or when the gap carries sentence
    /// punctuation. `terminator` is true when that punctuation ends a sentence.
    private static func boundaryBefore(_ gap: String, atStart: Bool) -> (hard: Bool, terminator: Bool) {
        if atStart { return (true, true) } // utterance start opens a sentence
        let punct = gap.filter { boundaryPunctuation.contains($0) }
        guard !punct.isEmpty else { return (false, false) }
        return (true, punct.contains { sentenceTerminators.contains($0) })
    }

    /// Classify the boundary on the *after* side of a phrase from the gap that
    /// follows it. Hard at the text end or when the following gap leads with
    /// sentence punctuation.
    private static func boundaryAfter(_ gap: String, atEnd: Bool) -> (hard: Bool, terminator: Bool) {
        if atEnd {
            let punct = gap.filter { boundaryPunctuation.contains($0) }
            return (true, punct.contains { sentenceTerminators.contains($0) })
        }
        // Look at the run up to the first non-whitespace/punctuation char: the
        // boundary is hard only if a punctuation mark sits between the phrase and
        // the next word.
        var sawTerminator = false
        for c in gap {
            if boundaryPunctuation.contains(c) {
                if sentenceTerminators.contains(c) { sawTerminator = true }
                return (true, sawTerminator)
            }
            if !c.isWhitespace { return (false, false) }
        }
        return (false, false)
    }

    // MARK: - String surgery

    /// Strip trailing boundary punctuation and whitespace from what we've emitted
    /// so far, so the break we're about to append butts directly against the
    /// preceding word ("world. " → "world" before appending "\n").
    private static func trimTrailingBoundary(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            let c = s[prev]
            if c.isWhitespace || boundaryPunctuation.contains(c) { end = prev } else { break }
        }
        return String(s[s.startIndex..<end])
    }

    /// The whitespace-only remainder of a gap, with boundary punctuation and any
    /// leading spaces removed — what to keep after a trailing gap is swallowed
    /// into a break. (For a well-formed ". " gap this is just "".)
    private static func whitespaceOnly(_ gap: String) -> String {
        // Drop everything up to and including the last boundary-punctuation char,
        // plus any spaces immediately after it, so we don't re-emit ", " after the
        // newline. Whatever non-space content remained (rare) is preserved.
        var result = gap
        if let lastPunct = gap.lastIndex(where: { boundaryPunctuation.contains($0) }) {
            result = String(gap[gap.index(after: lastPunct)...])
        }
        // Trim leading spaces/tabs that hugged the (now removed) punctuation.
        while let f = result.first, f == " " || f == "\t" { result.removeFirst() }
        return result
    }

    /// Capitalize the first letter of a word (leaving an already-capital or
    /// non-letter start untouched), so a break that opened a new sentence isn't
    /// followed by a lowercase word.
    private static func capitalizeFirst(_ word: String) -> String {
        guard let first = word.first, first.isLowercase else { return word }
        return first.uppercased() + word.dropFirst()
    }

    // MARK: - Tokenize

    /// Split into alternating gaps and words, mirroring `NumberNormalizer`:
    /// `gaps` has one more element than `words`; `gaps[k]` is the text *before*
    /// `words[k]`, and the final gap is the trailing text. A "word" is a run of
    /// letters/digits (apostrophes included); everything else — spaces AND
    /// punctuation — lives in the gaps, which is exactly what the boundary
    /// analysis needs to inspect.
    private static func tokenize(_ s: String) -> (gaps: [String], words: [String]) {
        var gaps: [String] = [""]
        var words: [String] = []
        var buf = ""
        var bufIsWord: Bool? = nil

        func isWordChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "'" || c == "’"
        }
        func flush() {
            guard let isWord = bufIsWord, !buf.isEmpty else { return }
            if isWord {
                words.append(buf)
                gaps.append("")
            } else {
                gaps[gaps.count - 1] += buf
            }
            buf = ""
        }

        for c in s {
            let w = isWordChar(c)
            if bufIsWord == nil { bufIsWord = w; buf = String(c) }
            else if w == bufIsWord { buf.append(c) }
            else { flush(); bufIsWord = w; buf = String(c) }
        }
        flush()
        return (gaps, words)
    }
}
