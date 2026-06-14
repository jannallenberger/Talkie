import AVFoundation
import Foundation
import Speech

/// A single in-flight transcript update, pushed to the UI as recognition progresses.
struct TranscriptUpdate: Sendable {
    /// Text that the recognizer has committed (will not change).
    var finalizedText: String
    /// The live, still-changing tail.
    var volatileText: String
    /// True only on the final update of a session.
    var isComplete: Bool

    /// The full string as it should appear right now.
    var combined: String {
        let joiner = finalizedText.isEmpty || volatileText.isEmpty ? "" : " "
        return finalizedText + joiner + volatileText
    }
}

enum TalkieEngineError: LocalizedError {
    case transcriberUnavailable
    case noSupportedLocale
    case modelInstallFailed(String)
    case noCompatibleAudioFormat

    var errorDescription: String? {
        switch self {
        case .transcriberUnavailable:
            return "On-device speech recognition is not available on this Mac."
        case .noSupportedLocale:
            return "No supported speech locale could be resolved."
        case .modelInstallFailed(let detail):
            return "The speech model could not be installed: \(detail)"
        case .noCompatibleAudioFormat:
            return "No compatible audio format was found for the microphone."
        }
    }
}

/// Wraps Apple's macOS 26 `SpeechAnalyzer` + `SpeechTranscriber` for live,
/// on-device, low-latency dictation. One instance is reused across sessions;
/// the heavy model load happens once and lingers for the process lifetime.
actor TranscriptionEngine {
    private var locale: Locale
    private var contextualStrings: [String] = []

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private var finalizedText: String = ""
    private var volatileText: String = ""

    private var onUpdate: (@Sendable (TranscriptUpdate) -> Void)?
    /// Fired once per finalized segment (a "batch") so the caller can clean
    /// each one incrementally. Set per session.
    private var onSegment: (@Sendable (String) -> Void)?

    init(localeIdentifier: String) {
        self.locale = Locale(identifier: localeIdentifier)
    }

    /// Switch the language used for subsequent live sessions (language auto-detect).
    func setLocaleIdentifier(_ id: String) {
        locale = Locale(identifier: id)
    }

    func setUpdateHandler(_ handler: @escaping @Sendable (TranscriptUpdate) -> Void) {
        self.onUpdate = handler
    }

    /// Set (or clear with nil) the per-session finalized-segment handler.
    func setSegmentHandler(_ handler: (@Sendable (String) -> Void)?) {
        self.onSegment = handler
    }

    /// Phrases that bias recognition toward the user's custom vocabulary
    /// (names, brand terms, jargon). Applied per session via `AnalysisContext`.
    func setContextualStrings(_ phrases: [String]) {
        self.contextualStrings = phrases
    }

    /// True if on-device transcription exists at all on this hardware/OS.
    static var isAvailable: Bool {
        SpeechTranscriber.isAvailable
    }

    /// Resolve the best locale we can actually transcribe in.
    private func resolvedLocale() async throws -> Locale {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return match
        }
        if let enUS = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
            return enUS
        }
        throw TalkieEngineError.noSupportedLocale
    }

    /// Ensure the on-device model for `transcriber` is downloaded & installed.
    /// First run on a given locale triggers a one-time download.
    private func ensureModelInstalled(for transcriber: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .installed else { return }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TalkieEngineError.modelInstallFailed(error.localizedDescription)
        }
    }

    /// Build a transcriber configured for live progressive dictation. We request
    /// `.volatileResults` explicitly so the HUD gets partial hypotheses as the
    /// user speaks (not just the final string).
    private func makeTranscriber(locale loc: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: loc,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    /// One-time warm-up so the first real dictation (or language switch) isn't
    /// gated on a model download. Pass a locale id to pre-warm a specific language.
    func warmUp(localeIdentifier id: String? = nil) async throws {
        guard SpeechTranscriber.isAvailable else { throw TalkieEngineError.transcriberUnavailable }
        let loc: Locale
        if let id, let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) {
            loc = resolved
        } else {
            loc = try await resolvedLocale()
        }
        let t = makeTranscriber(locale: loc)
        try await ensureModelInstalled(for: t)
        // Best-effort: keep the locale asset reserved so it isn't reclaimed.
        _ = try? await AssetInventory.reserve(locale: loc)
    }

    /// One-shot re-transcription of already-captured audio in a different locale
    /// (used by language auto-detect). Returns nil on any failure, so the caller
    /// keeps the original transcript.
    func transcribeBuffered(_ buffers: [AVAudioPCMBuffer], localeIdentifier id: String) async -> String? {
        guard SpeechTranscriber.isAvailable, !buffers.isEmpty else { return nil }
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else { return nil }

        let transcriber = makeTranscriber(locale: loc)
        // Never download a model inline here — that would freeze the insert for
        // seconds. If the language isn't installed yet, bail; warmUp() installs
        // it in the background so the NEXT switch is instant.
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { return nil }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return nil }
        // Compare load-bearing format fields rather than AVAudioFormat.== (which
        // also compares channel layout and can spuriously differ between locales).
        guard let firstFormat = buffers.first?.format,
              firstFormat.sampleRate == format.sampleRate,
              firstFormat.channelCount == format.channelCount,
              firstFormat.commonFormat == format.commonFormat else { return nil }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualStrings.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings = [.general: contextualStrings]
            try? await analyzer.setContext(ctx)
        }

        var collected = ""
        let reader = Task {
            do {
                for try await result in transcriber.results where result.isFinal {
                    collected = appendCommitted(collected, String(result.text.characters))
                }
            } catch {}
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            reader.cancel()
            return nil
        }
        for buffer in buffers {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        continuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await reader.value

        let result = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Begin a dictation session. Returns the audio format the caller must feed
    /// (`AudioCapture` converts the mic to this) plus the continuation to push
    /// `AnalyzerInput` buffers into. Idempotent guard: a session must be finished
    /// before another begins.
    func beginSession() async throws -> (format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        guard SpeechTranscriber.isAvailable else { throw TalkieEngineError.transcriberUnavailable }

        // Reset accumulators.
        finalizedText = ""
        volatileText = ""

        let loc = try await resolvedLocale()
        let transcriber = makeTranscriber(locale: loc)
        try await ensureModelInstalled(for: transcriber)
        self.transcriber = transcriber

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TalkieEngineError.noCompatibleAudioFormat
        }

        // Build the analyzer and its input stream.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Dictionary biasing: feed custom vocabulary as contextual strings.
        if !contextualStrings.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings = [.general: contextualStrings]
            try await analyzer.setContext(ctx)
        }

        // Consume results as they stream in.
        self.resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await self.ingest(text: text, isFinal: result.isFinal)
                }
            } catch is CancellationError {
                // Expected on teardown.
            } catch {
                await self.handleResultsError(error)
            }
        }

        try await analyzer.start(inputSequence: stream)
        return (format, continuation)
    }

    /// Fold one recognizer result into the running transcript and notify the UI.
    /// When a segment finalizes, also emit it on its own so the caller can clean
    /// each batch incrementally (instead of one huge pass at the end).
    private func ingest(text: String, isFinal: Bool) {
        if isFinal {
            if !text.isEmpty {
                finalizedText = appendCommitted(finalizedText, text)
                onSegment?(text)
            }
            volatileText = ""
        } else {
            volatileText = text
        }
        emit(isComplete: false)
    }

    private func appendCommitted(_ base: String, _ next: String) -> String {
        guard !base.isEmpty else { return next }
        return base + " " + next
    }

    private func emit(isComplete: Bool) {
        let update = TranscriptUpdate(
            finalizedText: finalizedText,
            volatileText: volatileText,
            isComplete: isComplete
        )
        onUpdate?(update)
    }

    private func handleResultsError(_ error: Error) async {
        // Fully tear the session down so a failed results stream doesn't leak an
        // un-finalized analyzer into the next session.
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        analyzer = nil
        transcriber = nil
        resultsTask = nil
        // Surface as completion so the UI doesn't hang in "listening".
        volatileText = ""
        emit(isComplete: true)
    }

    /// Stop feeding audio, flush the analyzer, and return the final transcript.
    func finishSession() async -> String {
        inputContinuation?.finish()
        inputContinuation = nil

        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                // If finalize fails the results stream may never terminate;
                // cancel the reader so the await below can't hang forever.
                resultsTask?.cancel()
            }
        }

        // Let the results loop drain any remaining finalized text.
        await resultsTask?.value
        resultsTask = nil

        // Combine both buffers so a volatile tail that finalization didn't fold
        // in (e.g. on the finalize-throws path) isn't lost. No-op on the happy
        // path, where volatileText is already empty.
        let joiner = finalizedText.isEmpty || volatileText.isEmpty ? "" : " "
        let result = finalizedText + joiner + volatileText
        volatileText = ""

        // Emit a terminal update so the HUD can dismiss cleanly.
        emit(isComplete: true)

        analyzer = nil
        transcriber = nil
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hard-cancel without producing a transcript (e.g. user aborted).
    func cancelSession() async {
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        resultsTask?.cancel()
        resultsTask = nil
        finalizedText = ""
        volatileText = ""
        analyzer = nil
        transcriber = nil
    }
}
