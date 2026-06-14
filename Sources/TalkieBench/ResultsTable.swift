// Renders the final results as a clean, monospaced table with an honesty footer.
//
// The footer records the provenance of every number — machine, macOS version,
// corpus, locale, date, file count, warm-up count — because (per BRAND.md and
// the cores standards) a measured number is only credible if you can see exactly
// what produced it. No number is printed without this footer. We never invent a
// percentile or round a measurement into a marketing line.

import Foundation

enum ResultsTable {
    static func render(_ outcome: BenchOutcome, corpus: URL, locale: String) -> String {
        let results = outcome.measured
        guard !results.isEmpty else {
            return """

            No files were measured. \(outcome.skippedDecode) file(s) failed to
            decode or transcribe. Check that the corpus contains decodable audio
            with matching reference transcripts, and that the on-device speech
            model is installed (re-run; the first run installs it).
            """
        }

        // Corpus-level WER/CER via micro-average (sum errors / sum reference len).
        let totalWordErrors = results.reduce(0) { $0 + $1.wordErrors }
        let totalRefWords = results.reduce(0) { $0 + $1.referenceWords }
        let totalCharErrors = results.reduce(0) { $0 + $1.charErrors }
        let totalRefChars = results.reduce(0) { $0 + $1.referenceChars }
        let corpusWER = totalRefWords > 0 ? Double(totalWordErrors) / Double(totalRefWords) : 0
        let corpusCER = totalRefChars > 0 ? Double(totalCharErrors) / Double(totalRefChars) : 0

        // Speed: corpus RTFx from totals, plus per-file latency distribution.
        let totalAudio = results.reduce(0) { $0 + $1.audioSeconds }
        let totalWall = results.reduce(0) { $0 + $1.wallSeconds }
        let corpusRTFx = totalWall > 0 ? totalAudio / totalWall : 0

        let latencies = results.map(\.wallSeconds).sorted()
        let medianLatency = percentile(latencies, 0.50)
        let p90Latency = percentile(latencies, 0.90)

        // Per-file WER spread (mean of per-file WER, distinct from the micro-avg).
        let perFileWERs = results.map(\.wer).sorted()
        let medianFileWER = percentile(perFileWERs, 0.50)

        var out = "\n"
        out += "  RESULTS — Apple SpeechAnalyzer (on-device), raw recognition\n"
        out += "  " + String(repeating: "─", count: 58) + "\n\n"

        out += row("Files measured", "\(results.count)")
        out += row("Audio measured", "\(fmt(totalAudio, 1)) s (\(fmt(totalAudio / 60, 1)) min)")
        out += "\n"

        out += "  ACCURACY (lower is better)\n"
        out += row("  Word Error Rate (WER)", pct(corpusWER))
        out += row("  Character Error Rate (CER)", pct(corpusCER))
        out += row("  Median per-file WER", pct(medianFileWER))
        out += "\n"

        out += "  SPEED (higher RTFx is better)\n"
        out += row("  Real-time factor (RTFx)", "\(fmt(corpusRTFx, 1))×")
        out += row("  Median per-file latency", "\(fmt(medianLatency, 3)) s")
        out += row("  p90 per-file latency", "\(fmt(p90Latency, 3)) s")
        out += row("  Total wall-time", "\(fmt(totalWall, 1)) s")
        out += "\n"

        if outcome.skippedDecode > 0 {
            out += row("Skipped (decode/recognize)", "\(outcome.skippedDecode)")
            out += "\n"
        }

        out += footer(outcome: outcome, corpus: corpus, locale: locale)
        return out
    }

    // MARK: - Footer (provenance — never omitted)

    private static func footer(outcome: BenchOutcome, corpus: URL, locale: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var lines: [String] = []
        lines.append("  " + String(repeating: "─", count: 58))
        lines.append("  Measured on THIS machine — re-run to verify:")
        lines.append("    machine    : \(Provenance.machine)")
        lines.append("    macOS      : \(Provenance.osVersion)")
        lines.append("    date       : \(iso.string(from: outcome.startedAt))")
        lines.append("    corpus     : \(corpus.lastPathComponent) (\(corpus.path))")
        lines.append("    locale     : \(locale)")
        lines.append("    warm-up    : \(outcome.warmupCount) file(s) discarded; timings are warm")
        lines.append("    measured   : raw recognition only — NO cleanup, NO dictionary biasing")
        lines.append("")
        lines.append("  Note: LibriSpeech test-clean is clean read speech — its WER is a")
        lines.append("  floor, not your live dictation accuracy. For a Whisper Large V3")
        lines.append("  comparison, run that tool on the SAME files (see main.swift header).")
        lines.append("  Corpus: LibriSpeech (Panayotov et al., 2015), OpenSLR-12, CC BY 4.0.")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Layout helpers

    private static func row(_ label: String, _ value: String) -> String {
        let labelWidth = 34
        let padded = label.count >= labelWidth
            ? label
            : label + String(repeating: " ", count: labelWidth - label.count)
        return "  \(padded)\(value)\n"
    }

    /// Linear-interpolated percentile over a SORTED array. Empty → 0.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        if lower == upper { return sorted[lower] }
        let frac = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * frac
    }
}

// MARK: - JSON output (raw rows for independent re-scoring)

extension BenchOutcome {
    func writeRawJSON(to url: URL) throws {
        struct Envelope: Codable {
            let machine: String
            let osVersion: String
            let date: String
            let warmupCount: Int
            let skippedDecode: Int
            let results: [FileResult]
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let envelope = Envelope(
            machine: Provenance.machine,
            osVersion: Provenance.osVersion,
            date: iso.string(from: startedAt),
            warmupCount: warmupCount,
            skippedDecode: skippedDecode,
            results: measured
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: url)
    }
}
