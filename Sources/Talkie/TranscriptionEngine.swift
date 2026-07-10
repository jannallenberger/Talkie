import AVFoundation
import Foundation
import Speech

/// Best-effort debug log to a file — the unified log doesn't reliably capture
/// this app's NSLog, so language auto-detect diagnostics go here instead. OPT-IN
/// ONLY: a normal run (Debug or Release) writes nothing. Enable for a session
/// with `TALKIE_DEBUG_LOG=1 ./scripts/run.sh` (or export it before launching
/// Talkie.app directly), then read with
/// `cat ~/Library/Application\ Support/Talkie/debug.log`. Gated on an env var
/// rather than `Dev.isEnabled` because this is a free function called from
/// many non-actor-isolated contexts (no cross-actor hop needed to check it).
/// The write itself is dispatched onto a private serial queue so callers on
/// the insert-critical path never block on disk I/O; see `TalkieDebugLogSink`.
private let talkieDebugLogEnabled = ProcessInfo.processInfo.environment["TALKIE_DEBUG_LOG"] != nil

func talkieDebugLog(_ message: String) {
    guard talkieDebugLogEnabled else { return }
    guard let data = (message + "\n").data(using: .utf8) else { return }
    TalkieDebugLogSink.queue.async {
        TalkieDebugLogSink.append(data)
    }
}

/// Single serialized sink for `talkieDebugLog`: one long-lived `FileHandle`
/// behind one serial queue, so concurrent callers never race the same append
/// (the old per-call open/seek/write/close was not thread-safe). Lives in
/// `~/Library/Application Support/Talkie/debug.log`, created owner-only
/// (0600) since it can contain dictated text and other apps' AX field text.
/// Truncated back to empty once it crosses ~1 MB — best-effort diagnostics,
/// not an audit trail, so unbounded growth isn't worth the complexity of
/// numbered rotation.
private enum TalkieDebugLogSink {
    static let queue = DispatchQueue(label: "com.coralate.talkie.debuglog", qos: .utility)
    private static let maxBytes: UInt64 = 1_000_000
    private static let fileURL = AppPaths.supportDirectory().appendingPathComponent("debug.log")
    // Mutated only from inside `append`, which is itself only ever run on
    // `queue` (a serial queue) — that serialization is what makes this safe,
    // not actor isolation, so Swift 6 needs the explicit opt-out below.
    nonisolated(unsafe) private static var handle: FileHandle?

    /// Must only be called on `queue`.
    static func append(_ data: Data) {
        if handle == nil {
            let path = fileURL.path
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            } else {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
            handle = try? FileHandle(forWritingTo: fileURL)
        }
        guard let handle else { return }
        if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64,
           size > maxBytes {
            try? handle.truncate(atOffset: 0)
        }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

/// One finalized recognizer segment with its audio-clock span (seconds from the
/// session's audio start, which begins at 0 ≈ recording start). Emitted alongside
/// the bare-text segment so callers that persist timings (meetings, imports) have a
/// real start/end to stand on, while the dictation path — which only needs the text
/// — ignores it. `start`/`end` are pre-guarded finite by the producer.
struct TimedSegment: Sendable, Codable {
    var text: String
    var start: Double
    var end: Double
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
    case noInputDevice

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
        case .noInputDevice:
            return "No microphone is available. Check your input device in System Settings → Sound."
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
    /// Each finalized segment, in spoken order. A new segment is committed every
    /// time the recognizer finalizes at a pause — so this is exactly the list
    /// `SentenceFlow` de-seams (a pause is not a sentence boundary).
    private var finalizedSegments: [String] = []
    private var volatileText: String = ""

    private var onUpdate: (@Sendable (TranscriptUpdate) -> Void)?
    /// Fired once per finalized segment (a "batch") so the caller can clean
    /// each one incrementally. Set per session.
    private var onSegment: (@Sendable (String) -> Void)?
    /// Fired once per finalized segment WITH its audio-clock span (seconds), for
    /// callers that persist timings (meetings, imports). Set per session; nil on
    /// the dictation path, which needs only the text. Kept separate from `onSegment`
    /// so the existing text-only callers are untouched.
    private var onTimedSegment: (@Sendable (TimedSegment) -> Void)?
    /// Each finalized segment's audio-clock span, in spoken order — the timed
    /// mirror of `finalizedSegments`. Returned by `finishSessionDetailed`.
    private var finalizedTimedSegments: [TimedSegment] = []
    /// Per-word recognition confidence accumulated across the live session, in
    /// spoken order (A12). These are the `.transcriptionConfidence` values already
    /// requested on every session (`makeTranscriber`) but historically discarded in
    /// the live results loop — read here so the stop-time review gate can flag the
    /// words the recognizer was visibly unsure about. Purely additive: nothing here
    /// changes the transcript, the timing, or when text reaches the focused app;
    /// the accumulation is allocation-light and on the SAME actor + result stream
    /// (no extra pass, no second decode). Returned by `finishSessionDetailed`.
    private var sessionWordConfidences: [WordConfidence] = []

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
        // Per-word text is dictated content — never log it, even when the sink
        // is enabled. The min/max spread (vs. the mean above) is what actually
        // showed whether confidence separates right-vs-wrong model per word;
        // building it is skipped entirely when the sink is off since scanning
        // every word is real work on the re-transcription hot path.
        if talkieDebugLogEnabled {
            let confidences = collected.words.map(\.1)
            let minConf = confidences.min() ?? 0
            let maxConf = confidences.max() ?? 0
            talkieDebugLog("reTx[\(id)] mean=\(String(format: "%.2f", confidence)) " +
                "min=\(String(format: "%.2f", minConf)) max=\(String(format: "%.2f", maxConf)) " +
                "words=\(collected.words.count)")
        }
        return (text: text, confidence: confidence)
    }

    /// Begin a dictation session. Returns the audio format the caller must feed
    /// (`AudioCapture` converts the mic to this) plus the continuation to push
    /// `AnalyzerInput` buffers into. Idempotent guard: a session must be finished
    /// before another begins.
    func beginSession(
        segmentHandler: (@Sendable (String) -> Void)? = nil,
        timedSegmentHandler: (@Sendable (TimedSegment) -> Void)? = nil
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

        // Reset accumulators + bind the per-session segment handlers.
        finalizedText = ""
        finalizedSegments = []
        finalizedTimedSegments = []
        sessionWordConfidences = []
        volatileText = ""
        onSegment = segmentHandler
        onTimedSegment = timedSegmentHandler

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
                    // Capture the finalized segment's audio-clock span (seconds).
                    // Guard non-finite like the multilingual lanes do — a bad range
                    // must degrade to a zero-length span at a sane time, never a NaN.
                    var start = result.range.start.seconds
                    var end = (result.range.start + result.range.duration).seconds
                    if !start.isFinite { start = 0 }
                    if !end.isFinite { end = start }
                    // A12: harvest per-word confidence from the SAME finalized result
                    // (only finalized runs carry stable confidence; volatile partials
                    // churn). This walks the runs already materialized above — the same
                    // pattern the multilingual re-transcribe path uses — and appends
                    // (word, confidence) pairs. Behavior-neutral: it neither alters
                    // `text` nor gates anything the live path does with it.
                    var words: [WordConfidence] = []
                    if result.isFinal {
                        for run in result.text.runs {
                            guard let c = run.transcriptionConfidence else { continue }
                            let w = String(result.text[run.range].characters)
                                .trimmingCharacters(in: .whitespaces)
                            if !w.isEmpty { words.append(WordConfidence(word: w, confidence: c)) }
                        }
                    }
                    await self.ingest(text: text, isFinal: result.isFinal,
                                      start: start, end: end, wordConfidences: words)
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
    private func ingest(text: String, isFinal: Bool, start: Double = 0, end: Double = 0,
                        wordConfidences: [WordConfidence] = []) {
        if isFinal {
            if !text.isEmpty {
                finalizedText = appendCommitted(finalizedText, text)
                finalizedSegments.append(text)
                onSegment?(text)
                let timed = TimedSegment(text: text, start: start, end: end)
                finalizedTimedSegments.append(timed)
                onTimedSegment?(timed)
                // Accumulate the finalized segment's per-word confidences (A12),
                // in spoken order, only for a segment we actually committed — so
                // the list stays aligned with `finalizedText`.
                if !wordConfidences.isEmpty {
                    sessionWordConfidences.append(contentsOf: wordConfidences)
                }
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
        onTimedSegment = nil
        // Surface as completion so the UI doesn't hang in "listening".
        volatileText = ""
        emit(isComplete: true)
    }

    /// Stop feeding audio, flush, and return the final transcript. Protocol
    /// (`TranscriptionBackend`) entry point — delegates and drops the segment lists.
    func finishSession() async -> String {
        await finishSessionDetailed().text
    }

    /// Like `finishSession`, but also returns the per-segment list so the caller
    /// can de-seam pause boundaries (see `SentenceFlow`), plus the audio-clock–timed
    /// segments so meeting/import callers can persist real per-segment timings, plus
    /// the per-word recognition confidences (A12) so the dictation path can run the
    /// low-confidence review gate. The plain `segments` shape is unchanged;
    /// `timedSegments` and `wordConfidences` are purely additive — a caller that
    /// ignores them pays nothing. Concrete-only.
    func finishSessionDetailed() async
        -> (text: String, segments: [String], timedSegments: [TimedSegment], wordConfidences: [WordConfidence]) {
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
        // it to the segment handlers too, so the assembler's combined output
        // includes it. No-op on the happy path (volatileText already empty). The
        // tail never finalized, so it has no real audio range — stamp a zero-length
        // span continuing from the last timed segment's end so ordering is preserved
        // and the value stays finite (we honestly don't claim a duration for it).
        if !volatileText.isEmpty {
            // A LARGE volatile tail here is the fingerprint of a finalization stall: the
            // analyzer stopped promoting finalized results mid-session (~30 min in) and
            // everything since piled up as one unstamped block. The multilingual meeting
            // path rotates its analyzers to prevent this outright; the single-locale path
            // (dictation + the meeting far/mic fallback) instead relies on
            // `MeetingTranscriptRenderer.decollapse` to split this tail into timed lines.
            let tailWords = volatileText.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
            if tailWords > 60 {
                talkieDebugLog("TranscriptionEngine: large volatile tail at finish (\(tailWords) words) — likely a finalization stall; the renderer will de-collapse it")
            }
            onSegment?(volatileText)
            finalizedSegments.append(volatileText)
            let tailStart = finalizedTimedSegments.last?.end ?? 0
            let tail = TimedSegment(text: volatileText, start: tailStart, end: tailStart)
            finalizedTimedSegments.append(tail)
            onTimedSegment?(tail)
        }
        let joiner = finalizedText.isEmpty || volatileText.isEmpty ? "" : " "
        let result = finalizedText + joiner + volatileText
        volatileText = ""
        let segments = finalizedSegments
        finalizedSegments = []
        let timedSegments = finalizedTimedSegments
        finalizedTimedSegments = []
        // Hand off the accumulated per-word confidences (A12) and clear them so the
        // next session starts empty. The finalize-throws volatile tail (above) never
        // finalized, so it legitimately contributes no confidence entries.
        let wordConfidences = sessionWordConfidences
        sessionWordConfidences = []

        // Emit a terminal update so the HUD can dismiss cleanly.
        emit(isComplete: true)

        onSegment = nil
        onTimedSegment = nil
        analyzer = nil
        transcriber = nil
        return (result.trimmingCharacters(in: .whitespacesAndNewlines), segments, timedSegments, wordConfidences)
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
        finalizedSegments = []
        finalizedTimedSegments = []
        sessionWordConfidences = []
        volatileText = ""
        onSegment = nil
        onTimedSegment = nil
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
