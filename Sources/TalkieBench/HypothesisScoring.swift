// =============================================================================
// External-hypothesis scoring — score transcripts this harness did NOT produce
// =============================================================================
//
// The standard run transcribes the corpus itself through Apple's on-device model
// and scores the result. But the accuracy flywheel needs to score OTHER systems'
// output against the SAME references with the SAME metric: a Whisper Large V3 run,
// a cloud API, a decoding-trick experiment, or a re-run of Apple's own output with
// a post-hoc corrector applied. None of those live in this process.
//
// So this mode reads pre-made hypotheses from a directory of `<stem>.hyp.txt`
// sidecars — one per corpus item, keyed by the same audio-file stem `CorpusLoader`
// already uses as the item id — and scores each with the EXISTING `WER.score`
// (which normalizes both sides through `TextNormalizer`). No model is invoked; no
// audio is decoded. RTFx/latency are meaningless for text someone else produced,
// so the rendered table deliberately omits the timing columns.
//
// A corpus item with no matching `.hyp.txt` is skipped and counted (a partial
// hypothesis set silently scoring only the files it happens to cover would inflate
// the number). If zero items match, the caller exits nonzero.

import Foundation

/// One externally-produced hypothesis scored against its reference.
struct HypothesisResult: Sendable {
    let id: String
    let reference: String
    let hypothesis: String
    let wordErrors: Int
    let referenceWords: Int
    let charErrors: Int
    let referenceChars: Int

    var wer: Double { referenceWords > 0 ? Double(wordErrors) / Double(referenceWords) : (wordErrors == 0 ? 0 : 1) }
}

/// Everything the hypotheses run produced.
struct HypothesisOutcome: Sendable {
    let scored: [HypothesisResult]
    /// Corpus items that had no matching `<stem>.hyp.txt` in the directory.
    let missing: [String]
    let hypothesesDirectory: URL
}

enum HypothesisScoring {
    /// The sidecar extension we look for, mirroring the `.hyp.txt` convention.
    static let hypothesisSuffix = ".hyp.txt"

    /// Load `<stem>.hyp.txt` for each corpus item and score it. `stem` is the
    /// item id (the audio-file stem), so the same LibriSpeech utt-id / sidecar
    /// naming the corpus already uses lines the hypotheses up automatically.
    static func run(items: [CorpusItem], hypothesesDirectory dir: URL) -> HypothesisOutcome {
        var scored: [HypothesisResult] = []
        var missing: [String] = []

        for item in items {
            guard let hyp = loadHypothesis(for: item.id, in: dir) else {
                missing.append(item.id)
                continue
            }
            let word = WER.score(reference: item.reference, hypothesis: hyp)
            let char = WER.scoreCharacters(reference: item.reference, hypothesis: hyp)
            scored.append(HypothesisResult(
                id: item.id,
                reference: item.reference,
                hypothesis: hyp,
                wordErrors: word.totalErrors,
                referenceWords: word.referenceLength,
                charErrors: char.totalErrors,
                referenceChars: char.referenceLength
            ))
        }

        return HypothesisOutcome(scored: scored, missing: missing, hypothesesDirectory: dir)
    }

    /// Read `<dir>/<stem>.hyp.txt`, trimmed. nil if it doesn't exist / can't read.
    /// The whole file is the hypothesis for that one clip (same shape as a `.txt`
    /// reference sidecar).
    static func loadHypothesis(for stem: String, in dir: URL) -> String? {
        let url = dir.appendingPathComponent(stem + hypothesisSuffix)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed  // empty string is a legitimate (all-deletions) hypothesis
    }

    // MARK: - Rendering (no timing columns — RTFx is meaningless for pre-made text)

    static func render(_ o: HypothesisOutcome, corpus: URL, locale: String) -> String {
        guard !o.scored.isEmpty else {
            return """

              No hypotheses were scored. None of the \(o.missing.count) corpus item(s)
              had a matching `<stem>.hyp.txt` in:
                \(o.hypothesesDirectory.path)

              Name each hypothesis file after its audio stem (the corpus item id),
              e.g. clip-042.flac → clip-042.hyp.txt. See docs/bench/JARGON_CORPUS.md.
            """
        }

        let totalWordErrors = o.scored.reduce(0) { $0 + $1.wordErrors }
        let totalRefWords = o.scored.reduce(0) { $0 + $1.referenceWords }
        let totalCharErrors = o.scored.reduce(0) { $0 + $1.charErrors }
        let totalRefChars = o.scored.reduce(0) { $0 + $1.referenceChars }
        let corpusWER = totalRefWords > 0 ? Double(totalWordErrors) / Double(totalRefWords) : 0
        let corpusCER = totalRefChars > 0 ? Double(totalCharErrors) / Double(totalRefChars) : 0

        let perFileWERs = o.scored.map(\.wer).sorted()
        let medianFileWER = ResultsTable.percentile(perFileWERs, 0.50)

        var out = "\n"
        out += "  RESULTS — external hypotheses (scored, not transcribed here)\n"
        out += "  " + String(repeating: "─", count: 58) + "\n\n"

        out += row("Hypotheses scored", "\(o.scored.count)")
        if !o.missing.isEmpty {
            out += row("Corpus items missing a hypothesis", "\(o.missing.count)")
        }
        out += "\n"

        out += "  ACCURACY (lower is better)\n"
        out += row("  Word Error Rate (WER)", pct(corpusWER))
        out += row("  Character Error Rate (CER)", pct(corpusCER))
        out += row("  Median per-file WER", pct(medianFileWER))
        out += "\n"

        out += footer(o, corpus: corpus, locale: locale)
        return out
    }

    private static func footer(_ o: HypothesisOutcome, corpus: URL, locale: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var lines: [String] = []
        lines.append("  " + String(repeating: "─", count: 58))
        lines.append("  Scored on THIS machine — re-run to verify:")
        lines.append("    machine    : \(Provenance.machine)")
        lines.append("    macOS      : \(Provenance.osVersion)")
        lines.append("    date       : \(iso.string(from: Date()))")
        lines.append("    corpus     : \(corpus.lastPathComponent) (\(corpus.path))")
        lines.append("    hypotheses : \(o.hypothesesDirectory.path)")
        lines.append("    locale     : \(locale)")
        lines.append("    measured   : WER/CER of PRE-MADE transcripts — no model run, no timing")
        lines.append("")
        lines.append("  These transcripts were produced elsewhere; only accuracy is scored.")
        lines.append("  Both sides are normalized identically (TextNormalizer) so the number is")
        lines.append("  comparable to a live talkie-bench run on the same corpus.")
        return lines.joined(separator: "\n") + "\n"
    }

    // Local copy of the table renderer's row layout (kept private to this file so
    // it doesn't couple to ResultsTable's internals; identical 34-col label pad).
    private static func row(_ label: String, _ value: String) -> String {
        let labelWidth = 34
        let padded = label.count >= labelWidth
            ? label
            : label + String(repeating: " ", count: labelWidth - label.count)
        return "  \(padded)\(value)\n"
    }
}
