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

        // ---------------------------------------------------------------------
        // Per-term recall (TermRecall) — the E1 scorer for "did the jargon land?"
        // ---------------------------------------------------------------------

        // 10. Single-token recall: term said 3× across two clips, caught 2×.
        let tr1 = TermRecall.score(
            terms: ["Coralate"],
            pairs: [
                TermRecallPair(reference: "we shipped Coralate and Coralate again",
                               hypothesis: "we shipped Coralate and correlate again"),   // 1 of 2 caught
                TermRecallPair(reference: "Coralate is the product",
                               hypothesis: "Coralate is the product"),                    // 1 of 1 caught
            ])
        check("single-term recall = 2/3",
              tr1.rows[0].referenceOccurrences == 3 && tr1.rows[0].hypothesisHits == 2
                && approx(tr1.aggregateRecall, 2.0 / 3.0),
              "ref \(tr1.rows[0].referenceOccurrences), hit \(tr1.rows[0].hypothesisHits), agg \(tr1.aggregateRecall)")

        // 11. Multi-word term matched as a CONTIGUOUS token subsequence, case-
        //     folded to match WER. The term "context graph" is caught here but a
        //     "context" followed by a NON-adjacent "graph" (a token between them)
        //     is not — the tokens must be adjacent.
        let tr2 = TermRecall.score(
            terms: ["Context Graph"],
            pairs: [
                TermRecallPair(reference: "the Context Graph is the moat",
                               hypothesis: "the context graph is the moat"),         // caught (case-folded)
                TermRecallPair(reference: "context is a graph in theory",
                               hypothesis: "context is a graph in theory"),          // "context ... graph" not adjacent → no occurrence
            ])
        check("multi-word term matches contiguous tokens only",
              tr2.rows[0].referenceOccurrences == 1 && tr2.rows[0].hypothesisHits == 1
                && approx(tr2.rows[0].recall, 1.0),
              "ref \(tr2.rows[0].referenceOccurrences), hit \(tr2.rows[0].hypothesisHits)")

        // 11b. Punctuation parity: a comma between the two words is stripped by
        //     TextNormalizer identically on both sides, so "context, graph" DOES
        //     become the contiguous "context graph". This proves the per-term
        //     matcher folds punctuation exactly like WER (the load-bearing E1
        //     invariant — otherwise per-term numbers could contradict corpus WER).
        let tr2b = TermRecall.score(
            terms: ["Context Graph"],
            pairs: [TermRecallPair(reference: "our context, graph aside",
                                   hypothesis: "our context graph aside")])
        check("punctuation folds identically to WER (comma doesn't block match)",
              tr2b.rows[0].referenceOccurrences == 1 && tr2b.rows[0].hypothesisHits == 1,
              "ref \(tr2b.rows[0].referenceOccurrences), hit \(tr2b.rows[0].hypothesisHits)")

        // 12. Per-pair cap: a hypothesis repeating the term extra times can't push
        //     recall above 100% (hits capped at that pair's reference occurrences).
        let tr3 = TermRecall.score(
            terms: ["worktree"],
            pairs: [TermRecallPair(reference: "one worktree here",
                                   hypothesis: "worktree worktree worktree")])
        check("hypothesis over-count is capped at reference occurrences",
              tr3.rows[0].referenceOccurrences == 1 && tr3.rows[0].hypothesisHits == 1
                && approx(tr3.aggregateRecall, 1.0),
              "ref \(tr3.rows[0].referenceOccurrences), hit \(tr3.rows[0].hypothesisHits)")

        // 13. A term absent from every reference is reported as absent (n/a),
        //     NOT scored as 0% — it must not drag the aggregate down.
        let tr4 = TermRecall.score(
            terms: ["SwiftPM", "Higgsfield"],
            pairs: [TermRecallPair(reference: "we use SwiftPM daily",
                                   hypothesis: "we use SwiftPM daily")])
        check("absent term excluded from aggregate",
              tr4.absentTerms == ["Higgsfield"] && tr4.scorableRows.count == 1
                && approx(tr4.aggregateRecall, 1.0),
              "absent \(tr4.absentTerms), agg \(tr4.aggregateRecall)")

        // 14. Non-overlapping occurrence count: "na na na" contains "na na" once.
        let occ = TermRecall.occurrences(of: ["na", "na"], in: ["na", "na", "na"])
        check("occurrences are non-overlapping", occ == 1, "got \(occ)")

        // 15. Perfect-hypothesis sanity: reference == hypothesis → recall 100%
        //     for every term. This is exactly the synthetic sanity check the E1
        //     validation performs (WER 0.0, term recall 100%).
        let tr5 = TermRecall.score(
            terms: ["claude.md", "talkie-bench", "NicheCorrector"],
            pairs: [TermRecallPair(reference: "run claude.md through talkie-bench and NicheCorrector",
                                   hypothesis: "run claude.md through talkie-bench and NicheCorrector")])
        check("identical hyp gives 100% recall on all present terms",
              approx(tr5.aggregateRecall, 1.0) && tr5.scorableRows.count == 3,
              "agg \(tr5.aggregateRecall), scorable \(tr5.scorableRows.count)")

        // ---------------------------------------------------------------------
        // Hypothesis loader (HypothesisScoring) — reads <stem>.hyp.txt sidecars
        // ---------------------------------------------------------------------

        // 16. Round-trip: write a hypothesis sidecar to a temp dir, confirm the
        //     loader finds it by stem and scoring an identical hypothesis is 0 WER
        //     while a missing sidecar is reported (not silently scored).
        let hypDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-bench-selftest-\(UUID().uuidString)")
        var hypLoaderOK = false
        do {
            try FileManager.default.createDirectory(at: hypDir, withIntermediateDirectories: true)
            let ref = "the quick brown fox"
            try (ref + "\n").write(to: hypDir.appendingPathComponent("clip-1.hyp.txt"),
                                   atomically: true, encoding: .utf8)
            let items = [
                CorpusItem(id: "clip-1", audioURL: hypDir, reference: ref),      // has a sidecar
                CorpusItem(id: "clip-2", audioURL: hypDir, reference: "no hyp"), // missing
            ]
            let out = HypothesisScoring.run(items: items, hypothesesDirectory: hypDir)
            hypLoaderOK = out.scored.count == 1
                && out.scored.first?.id == "clip-1"
                && out.scored.first?.wordErrors == 0
                && out.missing == ["clip-2"]
            try? FileManager.default.removeItem(at: hypDir)
        } catch {
            hypLoaderOK = false
        }
        check("hypothesis loader finds sidecar by stem, reports missing", hypLoaderOK)

        print("")
        print(allPassed ? "  All self-tests passed." : "  SELF-TESTS FAILED.")
        return allPassed
    }
}
