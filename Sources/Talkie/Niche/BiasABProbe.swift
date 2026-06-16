@preconcurrency import AVFoundation
import Foundation
import Speech

/// A self-contained A/B transcription probe for the in-app **jargon bias test**
/// (gate zero, driven by live speech instead of benchmark files). It builds its
/// OWN `SpeechAnalyzer` / `SpeechTranscriber` and does NOT touch the live
/// `TranscriptionEngine` actor — so it stays clear of that file's in-flight work.
///
/// It transcribes one captured recording twice — bias OFF, then bias ON with the
/// supplied phrases — so the user can SEE whether on-device
/// `AnalysisContext.contextualStrings` actually changes the output. Same audio
/// both passes, so any difference is purely the biasing. 100% on-device.
actor BiasABProbe {
    enum ProbeError: LocalizedError {
        case unavailable, noLocale, noFormat
        var errorDescription: String? {
            switch self {
            case .unavailable: return "On-device speech recognition isn't available on this Mac."
            case .noLocale:    return "No supported speech locale could be resolved."
            case .noFormat:    return "No compatible audio format was found."
            }
        }
    }

    private let requestedLocale: Locale
    private var resolvedLocale: Locale?
    private var cachedFormat: AVAudioFormat?

    init(localeIdentifier: String) {
        self.requestedLocale = Locale(identifier: localeIdentifier)
    }

    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Warm the model once so the comparison isn't paying first-load cost.
    func prepare() async throws {
        guard SpeechTranscriber.isAvailable else { throw ProbeError.unavailable }
        let loc = try await locale()
        let transcriber = makeTranscriber(locale: loc)
        try await ensureModelInstalled(for: transcriber)
        _ = try? await AssetInventory.reserve(locale: loc)
        _ = try await preferredAudioFormat()
    }

    /// The format the analyzer wants — `AudioCapture` converts the mic to this.
    func preferredAudioFormat() async throws -> AVAudioFormat {
        if let cachedFormat { return cachedFormat }
        let loc = try await locale()
        let transcriber = makeTranscriber(locale: loc)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ProbeError.noFormat
        }
        cachedFormat = format
        return format
    }

    /// Transcribe the captured audio once, raw (no biasing). The post-hoc niche
    /// corrector runs on the result.
    func transcribe(buffers: [AVAudioPCMBuffer]) async -> String {
        (try? await transcribeOnce(buffers, contextualStrings: [])) ?? ""
    }

    /// Transcribe the SAME captured audio twice. The buffer array is sent into the
    /// actor once (Swift 6 clean) and reused read-only for both passes. Retained for
    /// re-verifying the (failed) biasing path; the live test uses `transcribe`.
    func transcribeAB(buffers: [AVAudioPCMBuffer], contextualStrings: [String]) async -> (off: String, on: String) {
        let off = (try? await transcribeOnce(buffers, contextualStrings: [])) ?? ""
        let on = (try? await transcribeOnce(buffers, contextualStrings: contextualStrings)) ?? ""
        return (off, on)
    }

    // MARK: - One pass (mirrors TranscriptionEngine's recognition path)

    private func transcribeOnce(_ buffers: [AVAudioPCMBuffer], contextualStrings ctx: [String]) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw ProbeError.unavailable }
        guard !buffers.isEmpty else { return "" }

        let loc = try await locale()
        let transcriber = makeTranscriber(locale: loc)
        try await ensureModelInstalled(for: transcriber)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // The one bit under test: on-device vocabulary biasing, applied exactly as
        // the live engine applies it.
        if !ctx.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: ctx]
            try await analyzer.setContext(context)
        }

        let reader = Task { () -> String in
            var collected = ""
            do {
                for try await result in transcriber.results where result.isFinal {
                    collected = Self.append(collected, String(result.text.characters))
                }
            } catch {}
            return collected
        }

        try await analyzer.start(inputSequence: stream)
        for buffer in buffers { continuation.yield(AnalyzerInput(buffer: buffer)) }
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
        throw ProbeError.noLocale
    }

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
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    private static func append(_ base: String, _ next: String) -> String {
        guard !base.isEmpty else { return next }
        return base + " " + next
    }
}
