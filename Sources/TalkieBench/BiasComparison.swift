// =============================================================================
// Gate zero: does on-device `contextualStrings` biasing actually reduce WER?
// =============================================================================
//
// The entire confidence-based niche-vocabulary feature rests on one unproven
// assumption: that feeding domain jargon into Apple's on-device
// `AnalysisContext.contextualStrings` measurably improves recognition of those
// terms. The API accepts the array without complaint either way — but on-device
// biasing is documented in places to be a silent soft no-op. So before any of the
// feature is wired into the app, this mode settles it empirically: transcribe each
// clip twice (bias OFF, then bias ON with the supplied phrases) and report the WER
// delta on YOUR hardware with YOUR audio.
//
// Build a small jargon corpus (clips where you actually say the niche terms, with
// reference transcripts — same formats the standard benchmark accepts) and a
// `--bias` phrase file (one term/phrase per line, `#` for comments). If WER drops,
// the architecture is viable. If it doesn't move, pivot to the post-hoc
// text-correction fallback and skip the recognizer-biasing phases entirely.

@preconcurrency import AVFoundation
import Foundation
import TalkieFileKit

/// One clip transcribed both ways.
struct BiasFileResult: Sendable {
    let id: String
    let wordErrorsOff: Int
    let wordErrorsOn: Int
    let referenceWords: Int
    let hypothesisOff: String
    let hypothesisOn: String

    var werOff: Double { referenceWords > 0 ? Double(wordErrorsOff) / Double(referenceWords) : 0 }
    var werOn: Double { referenceWords > 0 ? Double(wordErrorsOn) / Double(referenceWords) : 0 }
}

struct BiasComparisonOutcome: Sendable {
    let rows: [BiasFileResult]
    let phraseCount: Int
    let skipped: Int

    private var totalRefWords: Int { rows.reduce(0) { $0 + $1.referenceWords } }
    /// Micro-averaged corpus WER (total errors / total reference words).
    var werOff: Double {
        let e = rows.reduce(0) { $0 + $1.wordErrorsOff }
        return totalRefWords > 0 ? Double(e) / Double(totalRefWords) : 0
    }
    var werOn: Double {
        let e = rows.reduce(0) { $0 + $1.wordErrorsOn }
        return totalRefWords > 0 ? Double(e) / Double(totalRefWords) : 0
    }
    var improved: Int { rows.filter { $0.wordErrorsOn < $0.wordErrorsOff }.count }
    var worsened: Int { rows.filter { $0.wordErrorsOn > $0.wordErrorsOff }.count }
    var unchanged: Int { rows.filter { $0.wordErrorsOn == $0.wordErrorsOff }.count }

    /// Absolute WER reduction in percentage points (positive = biasing helped).
    var absoluteDeltaPoints: Double { (werOff - werOn) * 100 }
    /// Relative WER reduction (positive = biasing helped).
    var relativeDelta: Double { werOff > 0 ? (werOff - werOn) / werOff : 0 }
}

enum BiasComparison {
    /// Load the bias phrase list: one phrase per line, blank lines and `#` comments
    /// ignored.
    static func loadPhrases(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func run(
        items: [CorpusItem],
        localeIdentifier: String,
        phrases: [String],
        quiet: Bool
    ) async -> BiasComparisonOutcome {
        guard FileTranscriber.isAvailable else {
            FileHandle.standardError.write(Data("error: on-device SpeechTranscriber is not available on this Mac.\n".utf8))
            return BiasComparisonOutcome(rows: [], phraseCount: phrases.count, skipped: items.count)
        }

        let engine = FileTranscriber(localeIdentifier: localeIdentifier)
        do {
            if !quiet { Banner.progressLine("Warming up the on-device model (one-time)…") }
            try await engine.prepare()
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return BiasComparisonOutcome(rows: [], phraseCount: phrases.count, skipped: items.count)
        }

        let targetFormat: AVAudioFormat
        do {
            targetFormat = try await engine.preferredAudioFormat()
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return BiasComparisonOutcome(rows: [], phraseCount: phrases.count, skipped: items.count)
        }

        var rows: [BiasFileResult] = []
        var skipped = 0
        let total = items.count

        for (index, item) in items.enumerated() {
            // Decode a fresh buffer set per pass: a non-Sendable PCM buffer array
            // can only be sent into the actor once, and decoding is not timed in
            // this mode (WER, not latency, is what we're measuring).
            let buffersOff: [AVAudioPCMBuffer]
            let buffersOn: [AVAudioPCMBuffer]
            do {
                buffersOff = try AudioFileLoader.buffers(from: item.audioURL, target: targetFormat).buffers
                buffersOn = try AudioFileLoader.buffers(from: item.audioURL, target: targetFormat).buffers
            } catch {
                skipped += 1
                if !quiet { Banner.progressLine("skip \(item.id): \(error.localizedDescription)") }
                continue
            }

            do {
                let off = try await engine.transcribe(buffers: buffersOff)
                let on = try await engine.transcribe(buffers: buffersOn, contextualStrings: phrases)
                let wOff = WER.score(reference: item.reference, hypothesis: off)
                let wOn = WER.score(reference: item.reference, hypothesis: on)
                let row = BiasFileResult(
                    id: item.id,
                    wordErrorsOff: wOff.totalErrors,
                    wordErrorsOn: wOn.totalErrors,
                    referenceWords: wOff.referenceLength,
                    hypothesisOff: off,
                    hypothesisOn: on
                )
                rows.append(row)
                if !quiet {
                    let mark = row.wordErrorsOn < row.wordErrorsOff ? "↓" : (row.wordErrorsOn > row.wordErrorsOff ? "↑" : "=")
                    Banner.progressLine("[\(index + 1)/\(total)] \(item.id)  off \(pct(row.werOff)) → on \(pct(row.werOn)) \(mark)")
                }
            } catch {
                skipped += 1
                if !quiet { Banner.progressLine("skip \(item.id): \(error.localizedDescription)") }
                continue
            }
        }

        if !quiet { Banner.clearProgress() }
        return BiasComparisonOutcome(rows: rows, phraseCount: phrases.count, skipped: skipped)
    }

    // MARK: - Rendering

    static func render(_ o: BiasComparisonOutcome) -> String {
        var lines: [String] = []
        lines.append("")
        lines.append("══════════════════════════════════════════════════════════")
        lines.append("  Bias comparison — gate zero")
        lines.append("══════════════════════════════════════════════════════════")
        lines.append("  bias phrases applied : \(o.phraseCount)")
        lines.append("  clips compared       : \(o.rows.count)\(o.skipped > 0 ? "  (\(o.skipped) skipped)" : "")")
        lines.append("")

        guard !o.rows.isEmpty else {
            lines.append("  No clips were compared — check the corpus and references.")
            lines.append("══════════════════════════════════════════════════════════")
            return lines.joined(separator: "\n")
        }

        lines.append("                    WER")
        lines.append("    bias OFF   :  \(pct(o.werOff))")
        lines.append("    bias ON    :  \(pct(o.werOn))")
        lines.append("    ──────────────────────")
        lines.append("    absolute Δ :  \(signed(o.absoluteDeltaPoints)) pts   (positive = biasing helped)")
        lines.append("    relative   :  \(signed(o.relativeDelta * 100)) %")
        lines.append("")
        lines.append("    clips improved : \(o.improved)")
        lines.append("    clips worse    : \(o.worsened)")
        lines.append("    clips same     : \(o.unchanged)")
        lines.append("")
        lines.append("  \(verdict(o))")
        lines.append("══════════════════════════════════════════════════════════")
        return lines.joined(separator: "\n")
    }

    /// The decision this whole mode exists to produce.
    private static func verdict(_ o: BiasComparisonOutcome) -> String {
        // Thresholds are deliberately conservative: we want a clear, repeatable
        // signal before committing the recognizer-biasing architecture.
        if o.absoluteDeltaPoints >= 1.0 && o.improved > o.worsened {
            return """
            VERDICT ✓  On-device contextualStrings biasing MEASURABLY reduces WER.
                       The niche-vocabulary architecture is viable via the recognizer
                       bias slot on this stack/locale. (NOTE: the shipping verdict was
                       ≈/✗ — biasing is a no-op here — so the live path feeds graduated
                       terms to the post-hoc NicheCorrector instead; see
                       NicheVocabSnapshot.correctorTerms. Re-open bias wiring only if a
                       future run flips this to ✓.)
            """
        } else if o.absoluteDeltaPoints <= -1.0 || o.worsened > o.improved {
            return """
            VERDICT ✗  Biasing HURTS recognition on this set. Do NOT wire it into the
                       live path as-is. Investigate phrase quality / homophone collisions
                       before reconsidering; the post-hoc TextProcessor fallback is safer.
            """
        } else {
            return """
            VERDICT ≈  No measurable effect — treat contextualStrings as a soft no-op on
                       this stack/locale. Skip the recognizer-biasing phases and build the
                       post-hoc text-correction fallback (high-confidence terms applied to
                       the raw transcript) instead.
            """
        }
    }

    private static func signed(_ x: Double) -> String { String(format: "%+.2f", x) }
}
