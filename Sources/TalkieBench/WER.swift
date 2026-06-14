// Levenshtein-based Word Error Rate (and Character Error Rate).
//
// WER = (substitutions + deletions + insertions) / reference_word_count, the
// minimum-edit alignment between the reference and the hypothesis token streams.
// This is the field-standard metric (same definition `jiwer` computes); we
// implement it in pure Swift so the harness needs no Python to produce a number.
//
// Both strings are passed through the SAME `TextNormalizer` before scoring so we
// penalize mistranscription, not formatting (case, punctuation, "don't" vs
// "do not", "twenty" vs "20"). Normalizing both sides identically is what keeps
// the comparison fair — see TextNormalizer.swift.

import Foundation

/// A breakdown of one alignment, useful for both WER and CER.
struct EditCounts: Sendable {
    var substitutions = 0
    var deletions = 0
    var insertions = 0
    var referenceLength = 0

    var hits: Int { referenceLength - substitutions - deletions }
    var totalErrors: Int { substitutions + deletions + insertions }

    /// Error rate. Conventions at the edges (matching jiwer):
    ///   • empty reference + empty hypothesis → 0.0 (nothing to get wrong)
    ///   • empty reference + non-empty hypothesis → 1.0 (all insertions)
    var rate: Double {
        if referenceLength == 0 {
            return insertions == 0 ? 0.0 : 1.0
        }
        return Double(totalErrors) / Double(referenceLength)
    }
}

enum WER {
    /// Word Error Rate between a reference and a hypothesis, after normalization.
    static func score(reference: String, hypothesis: String) -> EditCounts {
        let refTokens = TextNormalizer.normalizeToWords(reference)
        let hypTokens = TextNormalizer.normalizeToWords(hypothesis)
        return editCounts(reference: refTokens, hypothesis: hypTokens)
    }

    /// Character Error Rate: the same alignment over the normalized character
    /// stream (whitespace collapsed to single spaces). Secondary, finer-grained
    /// view that doesn't over-penalize a one-character slip as a whole-word miss.
    static func scoreCharacters(reference: String, hypothesis: String) -> EditCounts {
        let refChars = TextNormalizer.normalizeToCharacters(reference)
        let hypChars = TextNormalizer.normalizeToCharacters(hypothesis)
        return editCounts(reference: refChars, hypothesis: hypChars)
    }

    /// Aggregate edit counts across many items into one corpus-level rate.
    /// (Summing counts, then dividing, is the correct micro-average — NOT the
    /// mean of per-utterance rates, which would over-weight short utterances.)
    static func aggregate(_ counts: [EditCounts]) -> EditCounts {
        var total = EditCounts()
        for c in counts {
            total.substitutions += c.substitutions
            total.deletions += c.deletions
            total.insertions += c.insertions
            total.referenceLength += c.referenceLength
        }
        return total
    }

    // MARK: - The Levenshtein DP

    /// Classic Wagner–Fischer edit distance with operation back-tracking, generic
    /// over any equatable token (words or characters). Two-row DP for the cost,
    /// then a full back-pointer matrix to recover S/D/I counts. O(n·m) time,
    /// which is fine for utterance-length inputs (LibriSpeech lines are short).
    static func editCounts<T: Equatable>(reference ref: [T], hypothesis hyp: [T]) -> EditCounts {
        let n = ref.count
        let m = hyp.count

        var result = EditCounts()
        result.referenceLength = n

        if n == 0 {
            result.insertions = m
            return result
        }
        if m == 0 {
            result.deletions = n
            return result
        }

        // cost[i][j] = edit distance between ref[0..<i] and hyp[0..<j].
        // op[i][j] records how we got there, to count S/D/I afterwards.
        //   0 = match/substitution (diagonal), 1 = deletion (up), 2 = insertion (left)
        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        var op = [[UInt8]](repeating: [UInt8](repeating: 0, count: m + 1), count: n + 1)

        for i in 0...n { cost[i][0] = i; op[i][0] = 1 }       // delete all of ref
        for j in 0...m { cost[0][j] = j; op[0][j] = 2 }       // insert all of hyp
        op[0][0] = 0

        for i in 1...n {
            for j in 1...m {
                if ref[i - 1] == hyp[j - 1] {
                    cost[i][j] = cost[i - 1][j - 1]
                    op[i][j] = 0
                } else {
                    let sub = cost[i - 1][j - 1] + 1   // substitution
                    let del = cost[i - 1][j] + 1       // deletion (skip a ref token)
                    let ins = cost[i][j - 1] + 1       // insertion (skip a hyp token)
                    let best = min(sub, min(del, ins))
                    cost[i][j] = best
                    // Tie-break sub > del > ins for stable, conventional counts.
                    if best == sub { op[i][j] = 0 }
                    else if best == del { op[i][j] = 1 }
                    else { op[i][j] = 2 }
                }
            }
        }

        // Walk the back-pointers to tally substitutions / deletions / insertions.
        var i = n, j = m
        while i > 0 || j > 0 {
            switch op[i][j] {
            case 0: // diagonal: match or substitution
                if i > 0 && j > 0 {
                    if ref[i - 1] != hyp[j - 1] { result.substitutions += 1 }
                    i -= 1; j -= 1
                } else if i > 0 {
                    result.deletions += 1; i -= 1
                } else {
                    result.insertions += 1; j -= 1
                }
            case 1: // up: deletion
                result.deletions += 1; i -= 1
            default: // left: insertion
                result.insertions += 1; j -= 1
            }
        }
        return result
    }
}
