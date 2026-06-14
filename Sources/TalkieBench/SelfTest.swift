// A tiny built-in correctness check for the pure-Swift WER scorer, runnable with
//   talkie-bench --selftest
// without any corpus, model, or Python. It pins the Levenshtein math against
// hand-checked cases so a refactor can't silently change the metric. (We can't
// add a separate XCTest target without editing Package.swift, which the cores
// standards forbid for this worker — so the check lives in-process.)

import Foundation

enum SelfTest {
    /// Returns true if every case passes. Prints a PASS/FAIL line per case.
    static func run() -> Bool {
        var allPassed = true

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "PASS" : "FAIL"
            print("  [\(mark)] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !condition { allPassed = false }
        }

        func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

        // 1. Identity → 0 WER.
        let identity = WER.score(reference: "the quick brown fox", hypothesis: "the quick brown fox")
        check("identity is 0.0 WER", approx(identity.rate, 0.0), "got \(identity.rate)")

        // 2. Empty hypothesis vs 4-word reference → all deletions → 1.0 WER.
        let empty = WER.score(reference: "the quick brown fox", hypothesis: "")
        check("empty hypothesis is 1.0 WER", approx(empty.rate, 1.0) && empty.deletions == 4,
              "rate \(empty.rate), del \(empty.deletions)")

        // 3. One substitution out of 4 words → 0.25 WER.
        let oneSub = WER.score(reference: "the quick brown fox", hypothesis: "the quick brown dog")
        check("one substitution of four = 0.25", approx(oneSub.rate, 0.25) && oneSub.substitutions == 1,
              "rate \(oneSub.rate), sub \(oneSub.substitutions)")

        // 4. One insertion → 1 error over 4 ref words = 0.25, and it's an insertion.
        let oneIns = WER.score(reference: "the quick brown fox", hypothesis: "the quick brown red fox")
        check("one insertion counted as insertion", oneIns.insertions == 1 && oneIns.substitutions == 0 && oneIns.deletions == 0,
              "ins \(oneIns.insertions), sub \(oneIns.substitutions), del \(oneIns.deletions)")

        // 5. One deletion → 1 error over 4 = 0.25, counted as a deletion.
        let oneDel = WER.score(reference: "the quick brown fox", hypothesis: "the quick fox")
        check("one deletion counted as deletion", oneDel.deletions == 1 && oneDel.insertions == 0,
              "del \(oneDel.deletions), ins \(oneDel.insertions)")

        // 6. Normalization: case + punctuation + an unambiguous contraction
        //    ("don't" → "do not") must not count as errors. (The possessive/"is"
        //    's' is intentionally NOT disambiguated — see TextNormalizer.swift.)
        let norm = WER.score(reference: "Don't STOP, the fox!",
                             hypothesis: "do not stop the fox")
        check("normalization ignores case/punct/contraction", approx(norm.rate, 0.0),
              "rate \(norm.rate)")

        // 7. Number-word canonicalization: "twenty" vs "20".
        let num = WER.score(reference: "I have twenty apples", hypothesis: "I have 20 apples")
        check("spelled-out vs digit numbers match", approx(num.rate, 0.0), "rate \(num.rate)")

        // 8. Aggregation micro-average: two items, summed errors / summed ref len.
        //    item A: 1 error / 4 ref; item B: 1 error / 1 ref → 2/5 = 0.4.
        let a = WER.score(reference: "the quick brown fox", hypothesis: "the quick brown dog")
        let b = WER.score(reference: "hello", hypothesis: "")
        let agg = WER.aggregate([a, b])
        check("micro-averaged aggregate = 0.4", approx(agg.rate, 0.4),
              "rate \(agg.rate) (errors \(agg.totalErrors) / ref \(agg.referenceLength))")

        // 9. CER on a one-character slip is smaller than the whole-word WER.
        let cer = WER.scoreCharacters(reference: "color", hypothesis: "colour")
        check("CER counts a 1-char insertion", cer.insertions == 1 && approx(cer.rate, 1.0 / 5.0),
              "ins \(cer.insertions), rate \(cer.rate)")

        print("")
        print(allPassed ? "  All self-tests passed." : "  SELF-TESTS FAILED.")
        return allPassed
    }
}
