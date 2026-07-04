// =============================================================================
// First-Word Error Rate (FWER) — did the recognizer catch the very first word?
// =============================================================================
//
// Corpus WER answers "how wrong is the whole transcript?" It says nothing about
// WHERE the errors fall — and the failure mode C3 targets is specific: live
// dictation eats the first word or two while its analyzer warms up, so a clip
// that starts "put the file…" transcribes as "the file…". That single-word miss
// is a rounding error in corpus WER but a real, felt bug at the point of use.
//
// FWER isolates it: for each clip, does the FIRST reference word appear in the
// HEAD of the hypothesis (its first `headWindow` words)? FWER is the fraction of
// clips where it does NOT. Paired with `--lead-trim-ms`, a 0-vs-N run shows
// exactly how much first-phoneme loss the trim introduces (and, symmetrically,
// how much the hotkey-down pre-roll would recover).
//
// THE INVARIANT (shared with WER + TermRecall): the first word is matched after
// the EXACT SAME `TextNormalizer` pass WER uses, so FWER can never contradict the
// corpus number — a "hit" here is a hit under the same casing/punctuation/number
// folding. A small head window (not just index 0) is deliberate: the recognizer
// may prepend a filler or split the first token, and we care whether the WORD
// survived, not whether it landed in slot 0. Everything here is pure and Sendable,
// unit-covered in SelfTest.swift.

import Foundation

enum FirstWordError {
    /// How many leading hypothesis words count as "the head". The first reference
    /// word need only appear within this window to count as caught — a filler or a
    /// split token pushing it to slot 1–2 is still a hit; a genuinely eaten first
    /// word (absent from the whole head) is a miss.
    static let defaultHeadWindow = 3

    /// True when the first (normalized) reference word appears within the first
    /// `headWindow` (normalized) hypothesis words. A reference with no words is
    /// treated as a hit (nothing could be eaten — it never drags FWER down).
    static func firstWordHit(reference: String, hypothesis: String, headWindow: Int = defaultHeadWindow) -> Bool {
        let ref = TextNormalizer.normalizeToWords(reference)
        guard let firstRefWord = ref.first else { return true }  // empty ref → nothing to miss
        let hyp = TextNormalizer.normalizeToWords(hypothesis)
        guard !hyp.isEmpty else { return false }                 // said something, got nothing
        let window = max(1, headWindow)
        return hyp.prefix(window).contains(firstRefWord)
    }

    /// One clip's contribution to the corpus FWER: whether its first reference word
    /// was caught, and whether the clip is even scorable (a clip with an empty
    /// reference has no first word, so it is excluded from the rate rather than
    /// counted as a free hit that would flatter the number).
    struct Item: Sendable {
        let hit: Bool
        let scorable: Bool
    }

    static func item(reference: String, hypothesis: String, headWindow: Int = defaultHeadWindow) -> Item {
        let hasFirstWord = TextNormalizer.normalizeToWords(reference).first != nil
        return Item(hit: firstWordHit(reference: reference, hypothesis: hypothesis, headWindow: headWindow),
                    scorable: hasFirstWord)
    }

    /// Corpus first-word error rate over a set of per-file hit flags: the fraction
    /// of scorable clips whose first reference word was NOT caught. `nil` when no
    /// clip is scorable (every reference empty) — no denominator, so no rate, and
    /// callers print "n/a" rather than a fabricated 0. Mirrors WER's edge-honesty.
    static func rate(hits: [Bool], scorable: [Bool]) -> Double? {
        precondition(hits.count == scorable.count)
        var denom = 0
        var misses = 0
        for (hit, ok) in zip(hits, scorable) where ok {
            denom += 1
            if !hit { misses += 1 }
        }
        guard denom > 0 else { return nil }
        return Double(misses) / Double(denom)
    }
}
