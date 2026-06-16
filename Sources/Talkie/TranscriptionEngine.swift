import AVFoundation
import Foundation
import Speech

/// Best-effort debug log to a file — the unified log doesn't reliably capture
/// this app's NSLog, so language auto-detect diagnostics go here instead. Reads
/// with `cat /tmp/talkie-lang.log`. TEMPORARY: remove once tuning is settled.
func talkieDebugLog(_ message: String) {
    guard let data = (message + "\n").data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/talkie-lang.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}

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
            // Per-word recognition confidence is the load-bearing signal for
            // language auto-detect: the right acoustic model fits the audio (high
            // confidence) while the wrong model decoding foreign speech does not.
            // audioTimeRange is requested too so a future per-segment (code-switch)
            // router has word timings on a shared clock.
            attributeOptions: [.transcriptionConfidence, .audioTimeRange]
        )
    }

    /// One-time warm-up so the first real dictation (or language switch) isn't
    /// gated on a model download. Pass a locale id to pre-warm a specific language.
    func warmUp(localeIdentifier id: String? = nil) async throws {
        guard SpeechTranscriber.isAvailable else { throw TalkieEngineError.transcriberUnavailable }
        let loc: Locale
        if let id {
            // A specific language was requested (the per-language warm-up loop).
            // If it isn't supported on-device, skip — do NOT fall back to the
            // primary, which would silently warm the wrong model and leave the
            // requested language uninstalled (guaranteeing a later re-transcribe
            // bail).
            guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
                return
            }
            loc = resolved
        } else {
            loc = try await resolvedLocale()
        }
        let t = makeTranscriber(locale: loc)
        try await ensureModelInstalled(for: t)
        // Best-effort: keep the locale asset reserved so it isn't reclaimed.
        _ = try? await AssetInventory.reserve(locale: loc)
    }

    /// Re-transcribe the buffered audio in each candidate locale (the stop-time
    /// language-correction path) and return every non-empty result with its locale
    /// and **mean per-word recognition confidence** — the caller picks the language
    /// whose model fit the audio best. Runs sequentially: the candidate set is
    /// small (the user's spoken languages), and keeping the loop inside the actor
    /// lets the same buffers be replayed per candidate without re-sending
    /// non-`Sendable` audio across isolation domains.
    func transcribeCandidates(
        _ buffers: [AVAudioPCMBuffer],
        localeIdentifiers ids: [String],
        installIfNeeded: Bool = false
    ) async -> [(localeID: String, text: String, confidence: Double)] {
        var out: [(localeID: String, text: String, confidence: Double)] = []
        for id in ids {
            if let scored = await transcribeScored(buffers, localeIdentifier: id, installIfNeeded: installIfNeeded) {
                out.append((localeID: id, text: scored.text, confidence: scored.confidence))
            }
        }
        return out
    }

    /// One-shot re-transcription of already-captured audio in a locale, returning
    /// just the text (used by the meeting language-correction shim). Returns nil
    /// when the language can't be transcribed at all.
    func transcribeBuffered(
        _ buffers: [AVAudioPCMBuffer],
        localeIdentifier id: String,
        installIfNeeded: Bool = false
    ) async -> String? {
        await transcribeScored(buffers, localeIdentifier: id, installIfNeeded: installIfNeeded)?.text
    }

    /// Core re-transcription: replays the buffered audio through a fresh
    /// single-locale analyzer and returns the committed text plus the mean
    /// per-word `transcriptionConfidence`. Returns nil only when the language
    /// can't be transcribed at all (unsupported, no model and `installIfNeeded`
    /// false, or an empty result), so the caller keeps the original transcript.
    func transcribeScored(
        _ buffers: [AVAudioPCMBuffer],
        localeIdentifier id: String,
        installIfNeeded: Bool = false
    ) async -> (text: String, confidence: Double)? {
        guard SpeechTranscriber.isAvailable, !buffers.isEmpty else {
            talkieDebugLog("reTx[\(id)]: bail — unavailable or no buffers (\(buffers.count))")
            return nil
        }
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
            talkieDebugLog("reTx[\(id)]: bail — locale not supported on this device")
            return nil
        }

        let transcriber = makeTranscriber(locale: loc)
        // The model must be present. By default we never download inline (it would
        // freeze the insert for seconds) and trust warmUp() to have installed it.
        // On the user-waiting stop path the caller passes installIfNeeded:true, so
        // the FIRST utterance in a not-yet-warmed language is still corrected
        // instead of silently kept as wrong-language gibberish.
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            guard installIfNeeded else {
                talkieDebugLog("reTx[\(id)]: bail — model not installed (no inline install)")
                return nil
            }
            do {
                try await ensureModelInstalled(for: transcriber)
            } catch {
                talkieDebugLog("reTx[\(id)]: bail — model install failed: \(error.localizedDescription)")
                return nil
            }
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            talkieDebugLog("reTx[\(id)]: bail — no compatible audio format")
            return nil
        }
        // The buffers were captured in the PRIMARY transcriber's format; a
        // different locale can resolve to a different best format. Re-sample to
        // THIS transcriber's format rather than bailing on a mismatch (which used
        // to silently discard correct detections). Matching formats pass through
        // untouched.
        let feedBuffers = Self.conform(buffers, to: format)
        guard !feedBuffers.isEmpty else {
            talkieDebugLog("reTx[\(id)]: bail — resample produced no buffers")
            return nil
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualStrings.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings = [.general: contextualStrings]
            try? await analyzer.setContext(ctx)
        }

        // Accumulate committed text and per-word confidence together. `words`
        // (text:confidence per run) is diagnostic — it shows whether confidence
        // separates right-vs-wrong model per word (the prerequisite for future
        // per-segment code-switch routing).
        let reader = Task { () -> (text: String, confSum: Double, confCount: Int, words: [(String, Double)]) in
            var text = ""
            var confSum = 0.0
            var confCount = 0
            var words: [(String, Double)] = []
            do {
                for try await result in transcriber.results where result.isFinal {
                    text = appendCommitted(text, String(result.text.characters))
                    for run in result.text.runs {
                        if let c = run.transcriptionConfidence {
                            confSum += c
                            confCount += 1
                            let w = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                            if !w.isEmpty { words.append((w, c)) }
                        }
                    }
                }
            } catch {}
            return (text, confSum, confCount, words)
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            reader.cancel()
            talkieDebugLog("reTx[\(id)]: bail — analyzer.start threw: \(error.localizedDescription)")
            return nil
        }
        for buffer in feedBuffers {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        continuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        let collected = await reader.value

        let text = collected.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            talkieDebugLog("reTx[\(id)]: empty transcript")
            return nil
        }
        let confidence = collected.confCount > 0 ? collected.confSum / Double(collected.confCount) : 0
        let wordStr = collected.words.map { "\($0.0):\(String(format: "%.2f", $0.1))" }.joined(separator: " ")
        talkieDebugLog("reTx[\(id)] mean=\(String(format: "%.2f", confidence)) text='\(text)'\n    words=[\(wordStr)]")
        return (text: text, confidence: confidence)
    }

    /// Begin a dictation session. Returns the audio format the caller must feed
    /// (`AudioCapture` converts the mic to this) plus the continuation to push
    /// `AnalyzerInput` buffers into. Idempotent guard: a session must be finished
    /// before another begins.
    func beginSession(
        segmentHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> (format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        guard SpeechTranscriber.isAvailable else { throw TalkieEngineError.transcriberUnavailable }

        // Exclusivity: never run two sessions on one engine. Tear down any
        // lingering/finishing session before starting a new one, so a slow
        // finishSession of a prior session can't stomp this one.
        if analyzer != nil {
            inputContinuation?.finish()
            inputContinuation = nil
            if let analyzer { await analyzer.cancelAndFinishNow() }
            resultsTask?.cancel()
            resultsTask = nil
            self.analyzer = nil
            self.transcriber = nil
        }

        // Reset accumulators + bind the per-session segment handler.
        finalizedText = ""
        volatileText = ""
        onSegment = segmentHandler

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
        onSegment = nil
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

        // If finalization left a volatile tail (the finalize-throws path), route
        // it to the segment handler too, so the assembler's combined output
        // includes it. No-op on the happy path (volatileText already empty).
        if !volatileText.isEmpty {
            onSegment?(volatileText)
        }
        let joiner = finalizedText.isEmpty || volatileText.isEmpty ? "" : " "
        let result = finalizedText + joiner + volatileText
        volatileText = ""

        // Emit a terminal update so the HUD can dismiss cleanly.
        emit(isComplete: true)

        onSegment = nil
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
        onSegment = nil
        analyzer = nil
        transcriber = nil
    }

    // MARK: Buffer re-sampling (for cross-locale re-transcription)

    /// Holds one buffer for AVAudioConverter's pull-style input block.
    private final class OneShot: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ b: AVAudioPCMBuffer) { buffer = b }
        func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
    }

    /// Re-sample captured buffers to `target` when their format differs, so audio
    /// captured for one locale's transcriber can be replayed through another's.
    /// Buffers already in `target` pass through untouched. Returns [] only if no
    /// converter can be built (the caller then keeps the original transcript).
    nonisolated static func conform(
        _ buffers: [AVAudioPCMBuffer],
        to target: AVAudioFormat
    ) -> [AVAudioPCMBuffer] {
        guard let sourceFormat = buffers.first?.format else { return [] }
        if sourceFormat.sampleRate == target.sampleRate,
           sourceFormat.channelCount == target.channelCount,
           sourceFormat.commonFormat == target.commonFormat {
            return buffers
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else { return [] }
        converter.primeMethod = .none // avoid timestamp drift on streamed buffers
        var out: [AVAudioPCMBuffer] = []
        out.reserveCapacity(buffers.count)
        for buffer in buffers {
            guard let converted = convertOne(buffer, using: converter, to: target),
                  converted.frameLength > 0 else { continue }
            out.append(converted)
        }
        return out
    }

    /// Convert a single PCM buffer to `target`. Mirrors `AudioCapture.convert`.
    nonisolated private static func convertOne(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to target: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        let source = OneShot(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, statusPtr in
            if let next = source.take() {
                statusPtr.pointee = .haveData
                return next
            }
            statusPtr.pointee = .noDataNow
            return nil
        }
        if status == .error || error != nil { return nil }
        return output
    }
}
