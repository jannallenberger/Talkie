// Renders the final results as a clean, monospaced table with an honesty footer.
//
// The footer records the provenance of every number — machine, macOS version,
// corpus, locale, date, file count, warm-up count — because (per BRAND.md and
// the cores standards) a measured number is only credible if you can see exactly
// what produced it. No number is printed without this footer. We never invent a
// percentile or round a measurement into a marketing line.

import Foundation

enum ResultsTable {
    // MARK: - Shared aggregation (single source of truth)

    /// Every corpus-level number the human table AND the markdown row report,
    /// computed in exactly ONE place. The table renderer and `markdownRow` both
    /// read this struct, so a WER printed in the table can never disagree with the
    /// WER emitted on the machine-readable row — they are the same field. If a new
    /// column is ever added, it is added here once and both consumers see it.
    struct Aggregate {
        let fileCount: Int
        let totalAudioSeconds: Double
        let totalWallSeconds: Double
        /// Micro-averaged corpus WER (sum word errors / sum reference words).
        let corpusWER: Double
        /// Micro-averaged corpus CER (sum char errors / sum reference chars).
        let corpusCER: Double
        /// Corpus RTFx from totals (total audio / total wall).
        let corpusRTFx: Double
        /// Median of the per-file WER distribution (distinct from the micro-avg).
        let medianFileWER: Double
        let medianLatencySeconds: Double
        let p90LatencySeconds: Double

        /// Corpus throughput in audio minutes processed per wall-clock minute.
        /// (RTFx expressed as min/min — identical ratio, friendlier unit for the
        /// "files/min" column header, which we report as audio-minutes/min.)
        var audioMinutes: Double { totalAudioSeconds / 60 }

        init?(_ outcome: BenchOutcome) {
            let results = outcome.measured
            guard !results.isEmpty else { return nil }

            // Corpus-level WER/CER via micro-average (sum errors / sum reference len).
            let totalWordErrors = results.reduce(0) { $0 + $1.wordErrors }
            let totalRefWords = results.reduce(0) { $0 + $1.referenceWords }
            let totalCharErrors = results.reduce(0) { $0 + $1.charErrors }
            let totalRefChars = results.reduce(0) { $0 + $1.referenceChars }
            corpusWER = totalRefWords > 0 ? Double(totalWordErrors) / Double(totalRefWords) : 0
            corpusCER = totalRefChars > 0 ? Double(totalCharErrors) / Double(totalRefChars) : 0

            // Speed: corpus RTFx from totals, plus per-file latency distribution.
            let totalAudio = results.reduce(0) { $0 + $1.audioSeconds }
            let totalWall = results.reduce(0) { $0 + $1.wallSeconds }
            totalAudioSeconds = totalAudio
            totalWallSeconds = totalWall
            corpusRTFx = totalWall > 0 ? totalAudio / totalWall : 0

            let latencies = results.map(\.wallSeconds).sorted()
            medianLatencySeconds = ResultsTable.percentile(latencies, 0.50)
            p90LatencySeconds = ResultsTable.percentile(latencies, 0.90)

            // Per-file WER spread (median of per-file WER, distinct from micro-avg).
            let perFileWERs = results.map(\.wer).sorted()
            medianFileWER = ResultsTable.percentile(perFileWERs, 0.50)

            fileCount = results.count
        }
    }

    static func render(_ outcome: BenchOutcome, corpus: URL, locale: String) -> String {
        guard let agg = Aggregate(outcome) else {
            return """

            No files were measured. \(outcome.skippedDecode) file(s) failed to
            decode or transcribe. Check that the corpus contains decodable audio
            with matching reference transcripts, and that the on-device speech
            model is installed (re-run; the first run installs it).
            """
        }

        var out = "\n"
        out += "  RESULTS — Apple SpeechAnalyzer (on-device), raw recognition\n"
        out += "  " + String(repeating: "─", count: 58) + "\n\n"

        out += row("Files measured", "\(agg.fileCount)")
        out += row("Audio measured", "\(fmt(agg.totalAudioSeconds, 1)) s (\(fmt(agg.audioMinutes, 1)) min)")
        out += "\n"

        out += "  ACCURACY (lower is better)\n"
        out += row("  Word Error Rate (WER)", pct(agg.corpusWER))
        out += row("  Character Error Rate (CER)", pct(agg.corpusCER))
        out += row("  Median per-file WER", pct(agg.medianFileWER))
        out += "\n"

        out += "  SPEED (higher RTFx is better)\n"
        out += row("  Real-time factor (RTFx)", "\(fmt(agg.corpusRTFx, 1))×")
        out += row("  Median per-file latency", "\(fmt(agg.medianLatencySeconds, 3)) s")
        out += row("  p90 per-file latency", "\(fmt(agg.p90LatencySeconds, 3)) s")
        out += row("  Total wall-time", "\(fmt(agg.totalWallSeconds, 1)) s")
        out += "\n"

        if outcome.skippedDecode > 0 {
            out += row("Skipped (decode/recognize)", "\(outcome.skippedDecode)")
            out += "\n"
        }

        out += footer(outcome: outcome, corpus: corpus, locale: locale)
        return out
    }

    // MARK: - Machine-readable single row (for BENCHMARKS.md)

    /// One pipe-delimited Markdown table row summarising a whole run, for pasting
    /// into BENCHMARKS.md. Columns (exactly, in order):
    ///
    ///   | date | machine | macOS | locale | corpus (files/min) | WER | CER | RTFx | median lat | p90 lat |
    ///
    /// Every number comes from the SAME `Aggregate` the human table prints, so the
    /// row and the table can never drift. Returns `nil` when nothing was measured
    /// (no row is better than a fabricated one). `date` is the run's start instant
    /// (ISO-8601, calendar date) so the row is self-dating.
    ///
    /// The "corpus (files/min)" cell records what was measured: the corpus name,
    /// the file count, and the audio minutes covered — e.g. `test-clean 87f/13.2m`.
    static func markdownRow(outcome: BenchOutcome, corpus: URL, locale: String) -> String? {
        guard let agg = Aggregate(outcome) else { return nil }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let date = dateFormatter.string(from: outcome.startedAt)

        // The corpus cell: name + files measured + audio-minutes covered.
        let corpusCell = "\(corpus.lastPathComponent) \(agg.fileCount)f/\(fmt(agg.audioMinutes, 1))m"

        let cells: [String] = [
            date,
            Provenance.machine,
            Provenance.osVersion,
            locale,
            corpusCell,
            pct(agg.corpusWER),
            pct(agg.corpusCER),
            "\(fmt(agg.corpusRTFx, 1))×",
            "\(fmt(agg.medianLatencySeconds, 3)) s",
            "\(fmt(agg.p90LatencySeconds, 3)) s",
        ]
        return "| " + cells.joined(separator: " | ") + " |"
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
