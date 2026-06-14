// A SELF-CONTAINED, offline, file-input transcriber built on Apple's macOS 26
// `SpeechAnalyzer` / `SpeechTranscriber`.
//
// This is a faithful, standalone mirror of the recognition path in the app's
// `Sources/Talkie/TranscriptionEngine.swift` — same locale resolution, same
// `SpeechTranscriber(reportingOptions:[.volatileResults])` config, same asset
// install via `AssetInventory`, same final-results accumulation. It does NOT
// import the Talkie app target (per the cores standards: the bench is a separate
// executable that must not depend on the app), so the benchmark exercises the
// *same API the app uses* without coupling the two targets.
//
// Differences from the live engine, all in service of benchmarking:
//   • Input is a file (decoded + resampled by AudioFileLoader), fed as a finite
//     stream, then finalized — there is no microphone, no live HUD updates.
//   • We measure ONLY the recognize call (start → feed → finalize → drain).
//   • Raw recognition only: no cleanup, no contextual-string biasing, so the WER
//     reflects the model's quality, not Talkie's vocabulary advantage.

@preconcurrency import AVFoundation
import Foundation
import Speech

enum BenchTranscriberError: LocalizedError {
    case unavailable
    case noSupportedLocale(String)
    case modelInstallFailed(String)
    case noCompatibleAudioFormat

    var errorDescription: String? {
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

/// One reusable transcriber for the whole run: the heavy model load happens once
/// (warm-up) and the analyzer format is cached so every file is converted to the
/// exact format the analyzer wants.
actor BenchTranscriber {
    private let requestedLocale: Locale
    private var resolvedLocale: Locale?
    private var analyzerFormat: AVAudioFormat?

    init(localeIdentifier: String) {
        self.requestedLocale = Locale(identifier: localeIdentifier)
    }

    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// The audio format SpeechAnalyzer wants for this locale, resolved on first
    /// use. AudioFileLoader resamples every file to this.
    func preferredAudioFormat() async throws -> AVAudioFormat {
        if let analyzerFormat { return analyzerFormat }
        let loc = try await locale()
        let transcriber = makeTranscriber(locale: loc)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw BenchTranscriberError.noCompatibleAudioFormat
        }
        analyzerFormat = format
        return format
    }

    /// Resolve + install the model once, so timed runs don't pay first-load cost.
    func prepare() async throws {
        guard SpeechTranscriber.isAvailable else { throw BenchTranscriberError.unavailable }
        let loc = try await locale()
        let transcriber = makeTranscriber(locale: loc)
        try await ensureModelInstalled(for: transcriber)
        _ = try? await AssetInventory.reserve(locale: loc)
        _ = try await preferredAudioFormat()
    }

    /// Transcribe one already-converted set of buffers (matching the analyzer's
    /// format) and return the final transcript. The caller times this call.
    func transcribe(buffers: [AVAudioPCMBuffer]) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw BenchTranscriberError.unavailable }
        guard !buffers.isEmpty else { return "" }

        let loc = try await locale()
        let transcriber = makeTranscriber(locale: loc)
        try await ensureModelInstalled(for: transcriber)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

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
        throw BenchTranscriberError.noSupportedLocale(requestedLocale.identifier)
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
            throw BenchTranscriberError.modelInstallFailed(error.localizedDescription)
        }
    }

    private static func append(_ base: String, _ next: String) -> String {
        guard !base.isEmpty else { return next }
        return base + " " + next
    }
}
