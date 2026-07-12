// =============================================================================
// Per-term recall — did the recognizer actually get the jargon right?
// =============================================================================
//
// Corpus WER answers "how wrong is the transcript overall?" It does NOT answer
// the question the niche-vocabulary work actually cares about: "of the specific
// terms I care about (claude.md, Higgsfield, SwiftPM, GitHub…), how many did
// the recognizer spell right?" A transcript can post a great WER while quietly
// mangling every proper noun, because the jargon is a tiny fraction of the words.
//
// This file computes **per-term recall**: for each term in a phrase list, count
// how many times it occurs in the references, how many of those occurrences the
// hypothesis got, and the recall %. Plus an aggregate across all terms.
//
// THE ONE INVARIANT THAT MATTERS (per the E1 spec / risk note): terms are matched
// after the EXACT SAME normalization that `WER` uses — `TextNormalizer` — so the
// per-term numbers can never contradict the corpus WER. A multi-word term
// ("context graph", "inference latency") is matched as a **contiguous token
// subsequence** of the normalized token stream, so "context graph" matches inside
// "the context graph is" but not across a gap. Everything here is pure and
// Sendable, unit-covered in SelfTest.swift.

import Foundation

/// One term's recall across the corpus.
struct TermRecallRow: Sendable {
    /// The term as written in the phrase file (the human-facing surface form).
    let term: String
    /// Times the (normalized) term appeared across all reference transcripts.
    let referenceOccurrences: Int
    /// Times it also appeared in the paired (normalized) hypothesis — capped so a
    /// hypothesis can't claim more hits than the reference had occurrences.
    let hypothesisHits: Int

    /// Recall = hits / occurrences. A term that never occurs in any reference has
    /// no recall to compute; callers treat that separately (see `absentTerms`).
    var recall: Double {
        referenceOccurrences > 0 ? Double(hypothesisHits) / Double(referenceOccurrences) : 0
    }
    /// True when this term never appeared in any reference, so its recall is
    /// undefined rather than 0% — we surface it as "n/a" and exclude it from the
    /// aggregate rather than dragging the average to zero on an untested term.
    var isAbsent: Bool { referenceOccurrences == 0 }
}

/// The whole per-term result, aggregate included.
struct TermRecallOutcome: Sendable {
    let rows: [TermRecallRow]

    /// Terms that actually occur in at least one reference (the scorable set).
    var scorableRows: [TermRecallRow] { rows.filter { !$0.isAbsent } }
    /// Terms in the phrase file that never occur in any reference — reported so a
    /// user notices a phrase list that doesn't match the corpus.
    var absentTerms: [String] { rows.filter(\.isAbsent).map(\.term) }

    var totalOccurrences: Int { scorableRows.reduce(0) { $0 + $1.referenceOccurrences } }
    var totalHits: Int { scorableRows.reduce(0) { $0 + $1.hypothesisHits } }

    /// Micro-averaged recall: total hits / total occurrences across scorable terms
    /// (occurrence-weighted, matching how WER micro-averages — a frequent term
    /// counts more than a term seen once). 0 when nothing is scorable.
    var aggregateRecall: Double {
        totalOccurrences > 0 ? Double(totalHits) / Double(totalOccurrences) : 0
    }
}

/// One (reference, hypothesis) pair to score terms over. Mirrors what both the
/// live run (FileResult) and the hypotheses run produce, so `TermRecall` doesn't
/// depend on either shape.
struct TermRecallPair: Sendable {
    let reference: String
    let hypothesis: String
}

enum TermRecall {
    /// Normalize a term to the token subsequence WER would compare. Empty tokens
    /// (a phrase that normalizes away entirely, e.g. only punctuation) yield [].
    static func normalizedTokens(_ term: String) -> [String] {
        TextNormalizer.normalizeToWords(term)
    }

    /// Count non-overlapping occurrences of `needle` (a token subsequence) inside
    /// `haystack` (a token stream). A single-token needle is the common case; a
    /// multi-word term is matched as CONTIGUOUS tokens. Non-overlapping so
    /// "na na na" contains "na na" once, not twice — the conservative choice that
    /// keeps reference/hypothesis counting symmetric.
    static func occurrences(of needle: [String], in haystack: [String]) -> Int {
        guard !needle.isEmpty, needle.count <= haystack.count else { return 0 }
        var count = 0
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            var matched = true
            for k in 0..<needle.count where haystack[i + k] != needle[k] {
                matched = false
                break
            }
            if matched {
                count += 1
                i += needle.count   // non-overlapping: jump past the whole match
            } else {
                i += 1
            }
        }
        return count
    }

    /// Score a phrase list across all (reference, hypothesis) pairs.
    ///
    /// For each term we sum, over every pair: reference occurrences, and hypothesis
    /// hits CAPPED at that pair's reference occurrences. Capping per-pair is what
    /// makes recall a true "of what was said, how much was caught" number —
    /// a hypothesis that repeats a term extra times can't push recall above 100%.
    static func score(terms: [String], pairs: [TermRecallPair]) -> TermRecallOutcome {
        // Pre-normalize each pair's token streams once (not per term).
        let normalizedPairs: [(ref: [String], hyp: [String])] = pairs.map {
            (TextNormalizer.normalizeToWords($0.reference),
             TextNormalizer.normalizeToWords($0.hypothesis))
        }

        var rows: [TermRecallRow] = []
        for term in terms {
            let needle = normalizedTokens(term)
            // A term that normalizes to nothing can't be scored; report it absent.
            guard !needle.isEmpty else {
                rows.append(TermRecallRow(term: term, referenceOccurrences: 0, hypothesisHits: 0))
                continue
            }
            var refTotal = 0
            var hitTotal = 0
            for pair in normalizedPairs {
                let refN = occurrences(of: needle, in: pair.ref)
                guard refN > 0 else { continue }   // no occurrences here → nothing to catch
                let hypN = occurrences(of: needle, in: pair.hyp)
                refTotal += refN
                hitTotal += min(hypN, refN)         // cap: can't catch more than were said
            }
            rows.append(TermRecallRow(term: term,
                                      referenceOccurrences: refTotal,
                                      hypothesisHits: hitTotal))
        }
        return TermRecallOutcome(rows: rows)
    }

    // MARK: - Rendering

    /// A monospaced per-term table + aggregate line. Same visual language as the
    /// other tables (leading two-space indent, boxed section rule).
    static func render(_ o: TermRecallOutcome) -> String {
        var lines: [String] = []
        lines.append("")
        lines.append("  PER-TERM RECALL (of the terms you care about, how many landed)")
        lines.append("  " + String(repeating: "─", count: 58))

        let scorable = o.scorableRows
        guard !scorable.isEmpty else {
            lines.append("  None of the \(o.rows.count) terms occur in any reference transcript,")
            lines.append("  so there is nothing to score. Check that the phrase file matches the")
            lines.append("  corpus you ran (the terms must actually be spoken in the clips).")
            lines.append("  " + String(repeating: "─", count: 58))
            return lines.joined(separator: "\n")
        }

        // Column widths: term (flexible, capped), occurrences, hits, recall.
        let termWidth = min(34, max(12, scorable.map { $0.term.count }.max() ?? 12))
        func cell(_ s: String, _ w: Int, right: Bool = false) -> String {
            if s.count >= w { return s }
            let pad = String(repeating: " ", count: w - s.count)
            return right ? pad + s : s + pad
        }

        lines.append("  " + cell("term", termWidth) + "  " + cell("ref", 5, right: true)
                     + "  " + cell("hit", 5, right: true) + "  " + cell("recall", 8, right: true))
        for r in scorable.sorted(by: { $0.term.lowercased() < $1.term.lowercased() }) {
            lines.append("  " + cell(r.term, termWidth)
                         + "  " + cell("\(r.referenceOccurrences)", 5, right: true)
                         + "  " + cell("\(r.hypothesisHits)", 5, right: true)
                         + "  " + cell(pct(r.recall), 8, right: true))
        }

        lines.append("  " + String(repeating: "─", count: 58))
        lines.append("  aggregate term recall : \(pct(o.aggregateRecall))"
                     + "  (\(o.totalHits)/\(o.totalOccurrences) occurrences)")

        if !o.absentTerms.isEmpty {
            lines.append("")
            lines.append("  \(o.absentTerms.count) term(s) never occur in any reference (not scored):")
            lines.append("    " + o.absentTerms.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
