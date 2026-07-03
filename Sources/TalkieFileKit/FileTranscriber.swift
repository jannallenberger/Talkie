// A SELF-CONTAINED, offline, file-input transcriber built on Apple's macOS 26
// `SpeechAnalyzer` / `SpeechTranscriber`.
//
// This is a faithful, standalone mirror of the recognition path in the app's
// `Sources/Talkie/TranscriptionEngine.swift` — same locale resolution, same
// `SpeechTranscriber(reportingOptions:[.volatileResults])` config, same asset
// install via `AssetInventory`, same final-results accumulation. It does NOT
// import the Talkie app target (per the cores standards: file transcription is a
// separate library that must not depend on the app), so both `talkie-bench` and
// the `talkie` CLI exercise the *same API the app uses* without coupling targets.
//
// It moved (work package G4) from `Sources/TalkieBench/BenchTranscriber.swift`
// into the shared `TalkieFileKit` library and was renamed `FileTranscriber`. The
// original text-only `transcribe(buffers:contextualStrings:)` path is preserved
// byte-for-byte (only `public` was added) so `talkie-bench`'s WER numbers are
// identical before and after the move. A NEW, additive `transcribeTimed(...)`
// path surfaces per-final-result `(text, CMTimeRange)` for the CLI's SRT/VTT/JSON
// cue rendering; the bench keeps using the text-only path and never pays for it.
//
// Work package G5 adds a THIRD, additive path — `transcribeLive(bufferStream:…)` —
// that consumes an open-ended `AsyncStream<AVAudioPCMBuffer>` from a live mic tap
// (`talkie dictate`) instead of a finite file, emitting partial-hypothesis
// progress as it goes and finalizing when the caller ends the stream. The file
// and bench callers are untouched by it.
//
// Differences from the live engine, all in service of file transcription:
//   • The file paths take a file (decoded + resampled by AudioFileLoader), fed as
//     a finite stream, then finalized — no microphone, no live HUD updates. The
//     `transcribeLive` path DOES take mic buffers, but stays a primitive: it emits
//     raw progress text and a raw final transcript, with no HUD, no injection, and
//     no history write (the CLI never touches the app's history.json).
//   • Raw recognition only: no cleanup, no dictionary rules. (contextualStrings
//     biasing is available but off by default, matching the bench's clean measure.)

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

public enum FileTranscriberError: LocalizedError {
    case unavailable
    case noSupportedLocale(String)
    case modelInstallFailed(String)
    case noCompatibleAudioFormat

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "On-device speech recognition (SpeechTranscriber) is not available on this Mac."
        case .noSupportedLocale(let id):
            return "No supported speech locale could be resolved for '\(id)'."
        case .modelInstallFailed(let detail):
            return "The speech model could not be installed: \(detail)"
        case .noCompatibleAudioFormat:
            return "SpeechAnalyzer reported no compatible audio format."
        }
    }
}

/// One finalized transcript span with the audio time range it covers. Emitted by
/// `transcribeTimed` so callers (the CLI's SRT/VTT/JSON writers) can build cues
/// with real timestamps; the bench never uses this. `CMTimeRange` comes straight
/// from `SpeechTranscriber.Result.range` (a stored property present on every
/// result), so the timestamps are Apple's, not something we reconstruct.
public struct TimedSegment: Sendable {
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double

    public init(text: String, startSeconds: Double, endSeconds: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// One reusable transcriber for the whole run: the heavy model load happens once
/// (warm-up) and the analyzer format is cached so every file is converted to the
/// exact format the analyzer wants.
public actor FileTranscriber {
    private let requestedLocale: Locale
    private var resolvedLocale: Locale?
    private var analyzerFormat: AVAudioFormat?

    public init(localeIdentifier: String) {
        self.requestedLocale = Locale(identifier: localeIdentifier)
    }

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// The audio format SpeechAnalyzer wants for this locale, resolved on first
    /// use. AudioFileLoader resamples every file to this.
    public func preferredAudioFormat() async throws -> AVAudioFormat {
        if let analyzerFormat { return analyzerFormat }
        let loc = try await locale()
        let transcriber = makeTranscriber(locale: loc)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw FileTranscriberError.noCompatibleAudioFormat
        }
        analyzerFormat = format
        return format
    }

    /// Resolve + install the model once, so timed runs don't pay first-load cost.
    public func prepare() async throws {
        guard SpeechTranscriber.isAvailable else { throw FileTranscriberError.unavailable }
        let loc = try await locale()
        let transcriber = makeTranscriber(locale: loc)
        try await ensureModelInstalled(for: transcriber)
        _ = try? await AssetInventory.reserve(locale: loc)
        _ = try await preferredAudioFormat()
    }

    /// Transcribe one already-converted set of buffers (matching the analyzer's
    /// format) and return the final transcript. The caller times this call.
    ///
    /// `contextualStrings` applies the SAME on-device vocabulary biasing the live
    /// app uses (`AnalysisContext.contextualStrings`, mirrored verbatim from
    /// `TranscriptionEngine.beginSession`). Empty (the default) = raw recognition,
    /// so the standard benchmark stays a clean measure of the model. The bias
    /// comparison mode passes a phrase list here to measure the WER it buys.
    public func transcribe(buffers: [AVAudioPCMBuffer], contextualStrings: [String] = []) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw FileTranscriberError.unavailable }
        guard !buffers.isEmpty else { return "" }

        let loc = try await locale()
        let transcriber = makeTranscriber(locale: loc)
        try await ensureModelInstalled(for: transcriber)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // On-device vocabulary biasing — identical to the live engine path.
        if !contextualStrings.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings = [.general: contextualStrings]
            try await analyzer.setContext(ctx)
        }

        // Accumulate only finalized text — the headline transcript, no volatile
        // tail. The reader Task owns the accumulator exclusively; we read it only
        // after joining the task, so there is no concurrent access (Swift 6 clean).
        let reader = Task { () -> String in
            var collected = ""
            do {
                for try await result in transcriber.results where result.isFinal {
                    collected = Self.append(collected, String(result.text.characters))
                }
            } catch {
                // Surfaced via the empty/short transcript; the run records it.
            }
            return collected
        }

        try await analyzer.start(inputSequence: stream)
        for buffer in buffers {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let collected = await reader.value

        return collected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Like `transcribe`, but ALSO collects the audio time range of every finalized
    /// result so the caller can render timed cues (SRT/VTT/JSON segments). Additive:
    /// the bench never calls this, so its measured path is untouched. Returns the
    /// same joined plain-text transcript plus one `TimedSegment` per final result,
    /// in emission order. `SpeechTranscriber.Result.range` (a `CMTimeRange`) is a
    /// stored property present on every result, so no extra reporting option is
    /// needed to get timestamps — they are exactly what the recognizer reported.
    public func transcribeTimed(
        buffers: [AVAudioPCMBuffer],
        contextualStrings: [String] = []
    ) async throws -> (text: String, segments: [TimedSegment]) {
        guard SpeechTranscriber.isAvailable else { throw FileTranscriberError.unavailable }
        guard !buffers.isEmpty else { return ("", []) }

        let loc = try await locale()
        let transcriber = makeTranscriber(locale: loc)
        try await ensureModelInstalled(for: transcriber)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        if !contextualStrings.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings = [.general: contextualStrings]
            try await analyzer.setContext(ctx)
        }

        // Collect (text, range) for each finalized result. Same single-owner
        // reader-Task discipline as `transcribe`: the accumulator is read only
        // after the task joins, so there's no concurrent access.
        let reader = Task { () -> [TimedSegment] in
            var segments: [TimedSegment] = []
            do {
                for try await result in transcriber.results where result.isFinal {
                    let piece = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !piece.isEmpty else { continue }
                    let range = result.range
                    let start = range.start.seconds
                    let duration = range.duration.seconds
                    // Guard against non-numeric CMTime (e.g. .invalid) so a bad
                    // range can never produce NaN cue times downstream.
                    let safeStart = start.isFinite ? max(0, start) : 0
                    let safeEnd = duration.isFinite ? safeStart + max(0, duration) : safeStart
                    segments.append(TimedSegment(text: piece,
                                                 startSeconds: safeStart,
                                                 endSeconds: safeEnd))
                }
            } catch {
                // Partial segments are still useful; the empty case is handled by
                // the caller (falls back to a single untimed cue).
            }
            return segments
        }

        try await analyzer.start(inputSequence: stream)
        for buffer in buffers {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let segments = await reader.value

        let joined = segments.map(\.text).reduce("") { Self.append($0, $1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (joined, segments)
    }

    /// Transcribe a LIVE, open-ended stream of already-converted buffers (the mic
    /// path used by `talkie dictate`), rather than a finite file. Additive: the
    /// file/bench callers are untouched.
    ///
    /// The caller (DictateCommand) owns an `AVAudioEngine` tap that converts each
    /// mic buffer to `preferredAudioFormat()` and yields it into `bufferStream`.
    /// Recording ends when the caller finishes that stream (Enter / SIGINT); this
    /// method then finalizes the analyzer and returns the committed transcript.
    ///
    /// Unlike `transcribe`, this consumes results as they arrive so partial
    /// hypotheses can drive progress. `onProgress` is called on each result with
    /// the current best text (committed finals + the volatile tail) — DictateCommand
    /// prints that to STDERR so command substitution captures only the final stdout
    /// line. The result-handling mirrors the live engine
    /// (`TranscriptionEngine`): `.isFinal` results append to the committed transcript
    /// and clear the volatile tail; non-final results become the volatile tail.
    ///
    /// Raw recognition only — no cleanup, no dictionary rules — matching the CLI's
    /// "voice as a primitive" contract (smart cleanup stays in the app).
    public func transcribeLive(
        bufferStream: AsyncStream<AVAudioPCMBuffer>,
        contextualStrings: [String] = [],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw FileTranscriberError.unavailable }

        let loc = try await locale()
        let transcriber = makeTranscriber(locale: loc)
        try await ensureModelInstalled(for: transcriber)

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        if !contextualStrings.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings = [.general: contextualStrings]
            try await analyzer.setContext(ctx)
        }

        // Single-owner reader: accumulates committed finals and tracks the volatile
        // tail so progress reflects the same "committed + volatile" view the app's
        // HUD shows. We read `collected` only after the task joins, so there is no
        // concurrent access (Swift 6 clean).
        let reader = Task { () -> String in
            var committed = ""
            do {
                for try await result in transcriber.results {
                    let piece = String(result.text.characters)
                    if result.isFinal {
                        committed = Self.append(committed, piece)
                        onProgress?(committed.trimmingCharacters(in: .whitespacesAndNewlines))
                    } else {
                        // Volatile hypothesis: show committed + the live tail, but do
                        // not commit it — a later final result supersedes it.
                        let tail = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                        let preview = tail.isEmpty ? committed : Self.append(committed, tail)
                        onProgress?(preview.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            } catch {
                // Whatever committed so far is still returned; the caller handles the
                // empty case.
            }
            return committed
        }

        try await analyzer.start(inputSequence: inputStream)

        // Pump the live mic buffers into the analyzer until the caller finishes the
        // stream (Enter / SIGINT). This await returns when `bufferStream` ends.
        for await buffer in bufferStream {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        continuation.finish()

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let collected = await reader.value
        return collected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Config mirrored from TranscriptionEngine

    private func locale() async throws -> Locale {
        if let resolvedLocale { return resolvedLocale }
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            resolvedLocale = match
            return match
        }
        if let enUS = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
            resolvedLocale = enUS
            return enUS
        }
        throw FileTranscriberError.noSupportedLocale(requestedLocale.identifier)
    }

    /// Same configuration as live dictation: volatile results on, no attributes.
    private func makeTranscriber(locale loc: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: loc,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    private func ensureModelInstalled(for transcriber: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .installed else { return }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw FileTranscriberError.modelInstallFailed(error.localizedDescription)
        }
    }

    private static func append(_ base: String, _ next: String) -> String {
        guard !base.isEmpty else { return next }
        return base + " " + next
    }
}
