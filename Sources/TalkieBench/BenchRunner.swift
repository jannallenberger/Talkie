// Drives the benchmark: warm the model, then for each corpus item decode +
// resample the audio, time ONLY the recognize call, score WER/CER against the
// reference, and collect per-file rows. Produces a BenchOutcome the table
// renderer turns into the printed report.

@preconcurrency import AVFoundation
import Foundation

/// One file's measured result.
struct FileResult: Sendable, Codable {
    let id: String
    let reference: String
    let hypothesis: String
    let audioSeconds: Double
    let wallSeconds: Double
    let wordErrors: Int
    let referenceWords: Int
    let charErrors: Int
    let referenceChars: Int

    /// RTFx = audio processed per wall-clock second (higher is faster).
    var rtfx: Double { wallSeconds > 0 ? audioSeconds / wallSeconds : 0 }
    var wer: Double { referenceWords > 0 ? Double(wordErrors) / Double(referenceWords) : (wordErrors == 0 ? 0 : 1) }
}

/// Everything the run produced, ready to render or serialize.
struct BenchOutcome: Sendable {
    let measured: [FileResult]      // timed (post-warmup) files
    let warmupCount: Int
    let skippedDecode: Int          // files that failed to decode/transcribe
    let startedAt: Date
}

enum BenchRunner {
    static func run(
        items: [CorpusItem],
        localeIdentifier: String,
        warmupCount: Int,
        quiet: Bool
    ) async -> BenchOutcome {
        let startedAt = Date()

        guard BenchTranscriber.isAvailable else {
            FileHandle.standardError.write(Data("error: on-device SpeechTranscriber is not available on this Mac.\n".utf8))
            return BenchOutcome(measured: [], warmupCount: 0, skippedDecode: 0, startedAt: startedAt)
        }

        let engine = BenchTranscriber(localeIdentifier: localeIdentifier)

        // Warm-up: resolve locale + install/reserve the model + cache the format.
        // This is the one-time first-load cost, kept OUT of the measured timings.
        do {
            if !quiet { Banner.progressLine("Warming up the on-device model (one-time)…") }
            try await engine.prepare()
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return BenchOutcome(measured: [], warmupCount: 0, skippedDecode: 0, startedAt: startedAt)
        }

        let targetFormat: AVAudioFormat
        do {
            targetFormat = try await engine.preferredAudioFormat()
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return BenchOutcome(measured: [], warmupCount: 0, skippedDecode: 0, startedAt: startedAt)
        }

        var measured: [FileResult] = []
        var skipped = 0
        let total = items.count

        for (index, item) in items.enumerated() {
            let isWarmup = index < warmupCount

            // Decode + resample (NOT timed — only recognition is the benchmark).
            let loaded: (buffers: [AVAudioPCMBuffer], durationSeconds: Double)
            do {
                loaded = try AudioFileLoader.buffers(from: item.audioURL, target: targetFormat)
            } catch {
                skipped += 1
                if !quiet {
                    Banner.progressLine("skip \(item.id): \(error.localizedDescription)")
                }
                continue
            }

            // Time only the recognize call.
            let clockStart = DispatchTime.now()
            let hypothesis: String
            do {
                hypothesis = try await engine.transcribe(buffers: loaded.buffers)
            } catch {
                skipped += 1
                if !quiet {
                    Banner.progressLine("skip \(item.id): \(error.localizedDescription)")
                }
                continue
            }
            let wallSeconds = Double(DispatchTime.now().uptimeNanoseconds - clockStart.uptimeNanoseconds) / 1_000_000_000

            let word = WER.score(reference: item.reference, hypothesis: hypothesis)
            let char = WER.scoreCharacters(reference: item.reference, hypothesis: hypothesis)

            let result = FileResult(
                id: item.id,
                reference: item.reference,
                hypothesis: hypothesis,
                audioSeconds: loaded.durationSeconds,
                wallSeconds: wallSeconds,
                wordErrors: word.totalErrors,
                referenceWords: word.referenceLength,
                charErrors: char.totalErrors,
                referenceChars: char.referenceLength
            )

            if isWarmup {
                if !quiet {
                    Banner.progressLine("warmup \(index + 1)/\(warmupCount): \(item.id) (\(pct(result.wer)) WER, discarded)")
                }
            } else {
                measured.append(result)
                if !quiet {
                    let n = index + 1
                    Banner.progressLine("[\(n)/\(total)] \(item.id)  WER \(pct(result.wer))  RTFx \(fmt(result.rtfx, 1))×")
                }
            }
        }

        if !quiet { Banner.clearProgress() }

        return BenchOutcome(
            measured: measured,
            warmupCount: min(warmupCount, total),
            skippedDecode: skipped,
            startedAt: startedAt
        )
    }
}

// MARK: - Small formatting helpers shared by the runner + table

func pct(_ x: Double) -> String { String(format: "%.2f%%", x * 100) }
func fmt(_ x: Double, _ places: Int) -> String { String(format: "%.\(places)f", x) }
