import AVFoundation
import Foundation
import Speech

/// Runs one on-device recognizer per spoken language over a SINGLE audio stream,
/// live and in parallel, so a bilingual speaker is transcribed correctly even when
/// switching language mid-sentence. The same audio is fanned out to every lane; at
/// stop, `StreamLanguageVoter` merges the lanes' timed, confidence-scored segments
/// into one language-correct transcript (the right model is confident on its
/// language's spans, the wrong one isn't).
///
/// `start` mirrors `TranscriptionEngine.beginSession`'s shape — it returns the
/// audio `format` the caller feeds and a `continuation` to push mic/system buffers
/// into — so it drops into `MeetingRecorder` in place of a single-locale session.
///
/// **Analyzer rotation.** A single `SpeechAnalyzer` stops promoting volatile
/// hypotheses to finalized results on a long, continuous stream (~30 min in); once it
/// stalls, every later word arrives stamped at the last good audio time and a whole
/// speaker turn collapses under one timecode. `MeetingRecorder.tick()` therefore calls
/// `rotate()` periodically: each lane retires its current analyzer and starts a fresh
/// one over the continuing audio, so no analyzer ever lives long enough to stall. Word
/// timings from a retired generation are shifted into meeting time by the generation's
/// `offset` (the seconds of audio already fed when it started) and kept; the merge at
/// `finish` sees one continuous, correctly-clocked timeline.
actor MultiLangStreamTranscriber {
    /// One language's live recognizer over the shared stream. A reference type so its
    /// analyzer generation can be rotated in place (see `rotate`). `offset` is the
    /// meeting time at which the CURRENT generation started (added to its
    /// analyzer-relative word timings); `collected` holds the offset-corrected words
    /// already harvested from PRIOR generations.
    private final class Lane {
        let localeID: String
        let locale: Locale
        let format: AVAudioFormat
        let contextualStrings: [String]
        let liveCb: (@Sendable (String) -> Void)?
        var analyzer: SpeechAnalyzer
        var continuation: AsyncStream<AnalyzerInput>.Continuation
        var results: Task<[StreamLanguageVoter.TimedWord], Never>
        var offset: Double
        var collected: [StreamLanguageVoter.TimedWord] = []
        /// One converter per lane, reused across every fed buffer for the lane's
        /// whole lifetime (including across `rotate()`, since the target format
        /// never changes) — avoids rebuilding an `AVAudioConverter` per buffer.
        let converter = TranscriptionEngine.ConformingConverter()

        init(localeID: String, locale: Locale, format: AVAudioFormat,
             contextualStrings: [String], liveCb: (@Sendable (String) -> Void)?,
             gen: Gen, offset: Double) {
            self.localeID = localeID
            self.locale = locale
            self.format = format
            self.contextualStrings = contextualStrings
            self.liveCb = liveCb
            self.analyzer = gen.analyzer
            self.continuation = gen.continuation
            self.results = gen.results
            self.offset = offset
        }
    }

    /// A freshly-built, started analyzer generation for one lane.
    private struct Gen {
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let results: Task<[StreamLanguageVoter.TimedWord], Never>
    }

    private var lanes: [Lane] = []
    private var fanoutTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    /// Seconds of (reference-format) audio fanned out so far — the meeting clock the
    /// per-generation analyzer offsets are pinned to.
    private var audioSecondsFed: Double = 0
    private var referenceSampleRate: Double = 1
    private var rotationCount = 0
    /// Audio seconds at which the still-open window began (0 until the first
    /// rotation). Everything before it has already been handed out by `rotate()`.
    private(set) var openWindowStart: Double = 0

    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Most distinct languages we'll ever spin a live recognizer up for, PER stream.
    /// Each lane is a full on-device `SpeechAnalyzer` fed the same audio, so the
    /// recognizer count is `maxLanes × {mic, far-end}` — capping per stream keeps
    /// the worst case bounded (`maxLanes * 2`) no matter how many languages the
    /// meeting is tagged with. Four covers any realistic multilingual meeting; the
    /// system's own concurrent-analyzer limit would reject far more than this anyway.
    static let maxLanes = 4

    /// Pick the candidate locales to build lanes for: de-duplicate (preserving the
    /// caller's order — the first/primary language stays the live-segment lane) and
    /// cap to `maxLanes`. Pure so it can be tested without touching Speech.
    static func selectLaneLocales(_ ids: [String], limit: Int = maxLanes) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
            if out.count >= limit { break }
        }
        return out
    }

    /// Build and start a lane per distinct language. Returns the reference audio
    /// format the caller feeds and the continuation to push buffers into. Languages
    /// whose model isn't installed are skipped; throws if fewer than two lanes can
    /// start (nothing to vote between → the caller should use a single-locale
    /// session instead).
    func start(
        localeIDs ids: [String],
        contextualStrings: [String] = [],
        onLiveSegment: (@Sendable (String) -> Void)? = nil
    ) async throws -> (format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        guard SpeechTranscriber.isAvailable else { throw TalkieEngineError.transcriberUnavailable }

        // Bound the lane count: N spoken languages × {mic, far-end} would otherwise
        // spin up an unbounded number of live recognizers over the same stream.
        let laneLocaleIDs = Self.selectLaneLocales(ids)
        if laneLocaleIDs.count < ids.count {
            talkieDebugLog("meeting-lanes: capping \(ids.count) candidate locale(s) to \(laneLocaleIDs.count)")
        }

        var built: [Lane] = []
        for id in laneLocaleIDs {
            guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
                talkieDebugLog("meeting-lane[\(id)]: skip — locale unsupported")
                continue
            }
            let probe = Self.makeTranscriber(locale: loc)
            guard await AssetInventory.status(forModules: [probe]) == .installed else {
                talkieDebugLog("meeting-lane[\(id)]: skip — model not installed")
                continue
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else {
                talkieDebugLog("meeting-lane[\(id)]: skip — no compatible format")
                continue
            }

            // Live segments are emitted only by the first lane — the live notch needs
            // one stream while recording; the per-language truth is resolved by the
            // merge at stop.
            let liveCb = built.isEmpty ? onLiveSegment : nil
            guard let gen = await startAnalyzer(locale: loc, laneLocaleID: id,
                                                contextualStrings: contextualStrings, liveCb: liveCb) else {
                talkieDebugLog("meeting-lane[\(id)]: analyzer.start threw")
                continue
            }
            built.append(Lane(localeID: id, locale: loc, format: format,
                              contextualStrings: contextualStrings, liveCb: liveCb,
                              gen: gen, offset: 0))
        }

        // Need at least two lanes to have anything to vote between; otherwise the
        // caller falls back to its normal single-locale path.
        guard built.count >= 2, let reference = built.first?.format else {
            for lane in built { await lane.analyzer.cancelAndFinishNow(); lane.results.cancel(); lane.continuation.finish() }
            talkieDebugLog("meeting-lanes: only \(built.count) lane(s) started — falling back to single locale")
            throw TalkieEngineError.noCompatibleAudioFormat
        }

        self.lanes = built
        self.referenceSampleRate = max(1, reference.sampleRate)
        self.audioSecondsFed = 0
        self.rotationCount = 0
        self.openWindowStart = 0
        talkieDebugLog("meeting-lanes started: [\(built.map(\.localeID).joined(separator: ", "))]")

        // Fan the caller's reference-format audio out to every lane. The closure
        // captures only `self` + the (Sendable) stream; the per-lane work happens
        // in the actor-isolated `fanout` so non-Sendable lane state isn't captured.
        let (inStream, inCont) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inCont
        self.fanoutTask = Task { [weak self] in
            for await input in inStream { await self?.fanout(input) }
            await self?.finishLaneInputs()
        }
        return (reference, inCont)
    }

    /// Build a transcriber configured exactly like the live meeting lanes.
    private static func makeTranscriber(locale loc: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: loc,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.transcriptionConfidence, .audioTimeRange]
        )
    }

    /// Build + start one analyzer generation for a lane: a fresh transcriber, analyzer,
    /// input stream, and a reader task that harvests finalized per-word timings (in the
    /// analyzer's own audio clock, starting at 0). Returns nil if the analyzer won't
    /// start. Used for both the initial lane and every rotation.
    private func startAnalyzer(
        locale loc: Locale, laneLocaleID: String,
        contextualStrings: [String], liveCb: (@Sendable (String) -> Void)?
    ) async -> Gen? {
        let transcriber = Self.makeTranscriber(locale: loc)
        let (laneStream, laneCont) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualStrings.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings = [.general: contextualStrings]
            try? await analyzer.setContext(ctx)
        }

        let laneLocale = laneLocaleID
        let results = Task { () -> [StreamLanguageVoter.TimedWord] in
            var words: [StreamLanguageVoter.TimedWord] = []
            do {
                for try await result in transcriber.results where result.isFinal {
                    let attr = result.text
                    let fullText = String(attr.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !fullText.isEmpty else { continue }
                    // Per-word timing + confidence is what enables word-level language
                    // routing (a single foreign word in a sentence).
                    var anyWord = false
                    for run in attr.runs {
                        guard let conf = run.transcriptionConfidence,
                              let range = run.audioTimeRange else { continue }
                        let word = String(attr[run.range].characters).trimmingCharacters(in: .whitespaces)
                        guard !word.isEmpty else { continue }
                        let s = range.start.seconds
                        let e = (range.start + range.duration).seconds
                        words.append(.init(localeID: laneLocale, text: word,
                                           start: s.isFinite ? s : 0,
                                           end: e.isFinite ? e : s,
                                           confidence: conf))
                        anyWord = true
                    }
                    // Fallback: a result with no per-word timing still votes as one block
                    // over its own range, so nothing is silently lost.
                    if !anyWord {
                        var sum = 0.0, n = 0
                        for run in attr.runs where run.transcriptionConfidence != nil {
                            sum += run.transcriptionConfidence ?? 0; n += 1
                        }
                        let s = result.range.start.seconds
                        let e = (result.range.start + result.range.duration).seconds
                        words.append(.init(localeID: laneLocale, text: fullText,
                                           start: s.isFinite ? s : 0,
                                           end: e.isFinite ? e : s,
                                           confidence: n > 0 ? sum / Double(n) : 0))
                    }
                    liveCb?(fullText)
                }
            } catch {}
            return words
        }

        do {
            try await analyzer.start(inputSequence: laneStream)
        } catch {
            results.cancel()
            laneCont.finish()
            return nil
        }
        return Gen(analyzer: analyzer, continuation: laneCont, results: results)
    }

    /// Retire each lane's current analyzer and start a fresh one over the continuing
    /// audio, so no single analyzer runs long enough to hit the ~30-min finalization
    /// stall. The replacement is built and swapped in BEFORE the old one is stopped, so
    /// the fanout always has a live target and no audio is dropped; the retired
    /// generation's words are then harvested, shifted into meeting time by its offset,
    /// and kept. Best-effort per lane: if a replacement fails to start, the lane is left
    /// running on its existing analyzer (a stall risk beats a dead lane).
    /// Returns the retired window's words from every lane, merged by the same
    /// language vote `finish` uses — so a multi-language meeting can feed its live
    /// summary digest every rotation instead of summarizing everything at stop.
    @discardableResult
    func rotate() async -> [StreamLanguageVoter.Span] {
        guard !lanes.isEmpty else { return [] }
        rotationCount += 1
        var windowWords: [StreamLanguageVoter.TimedWord] = []
        var nextWindowStart = Double.infinity
        for lane in lanes {
            guard let gen = await startAnalyzer(locale: lane.locale, laneLocaleID: lane.localeID,
                                                contextualStrings: lane.contextualStrings,
                                                liveCb: lane.liveCb) else {
                talkieDebugLog("meeting-lane[\(lane.localeID)]: rotate — replacement failed; keeping current analyzer")
                continue
            }
            // Swap synchronously — no await between capturing `old` and installing the
            // new generation, so `fanout` (also actor-isolated) cannot interleave and
            // split a buffer across generations. Offset correctness: `audioSecondsFed` is
            // the END time of the last buffer that reached the OLD analyzer, which is the
            // START time of the first buffer the NEW analyzer will receive (the next
            // `fanout`). Any buffers that arrived while `startAnalyzer` was awaited fed the
            // OLD continuation (the swap hadn't happened yet), so pinning `lane.offset`
            // here lines the new analyzer's clock-0 up exactly with meeting time — no gap,
            // no overlap with the retiring generation.
            let old = (analyzer: lane.analyzer, continuation: lane.continuation,
                       results: lane.results, offset: lane.offset)
            lane.analyzer = gen.analyzer
            lane.continuation = gen.continuation
            lane.results = gen.results
            lane.offset = audioSecondsFed
            nextWindowStart = min(nextWindowStart, lane.offset)

            // Retire the old generation: stop its input, finalize (bounded), drain,
            // shift into meeting time, accumulate.
            old.continuation.finish()
            let raw = await Self.finalizeGeneration(analyzer: old.analyzer, results: old.results,
                                                    localeID: lane.localeID)
            let off = old.offset
            let shifted = raw.map { w in
                var w = w; w.start += off; w.end += off; return w
            }
            lane.collected.append(contentsOf: shifted)
            windowWords.append(contentsOf: shifted)
            // Liveness signal: a window that fed audio but harvested no words is the
            // fingerprint of a stall the rotation just cleared.
            talkieDebugLog("meeting-lane[\(lane.localeID)]: rotated (#\(rotationCount)) — window words=\(raw.count), next offset \(Int(lane.offset))s")
        }
        if nextWindowStart.isFinite { openWindowStart = nextWindowStart }
        return StreamLanguageVoter.mergeWords(windowWords)
    }

    /// Replay one input buffer into every lane, conforming to each lane's format, and
    /// advance the meeting audio clock (from the reference-format input).
    private func fanout(_ input: AnalyzerInput) {
        audioSecondsFed += Double(input.buffer.frameLength) / referenceSampleRate
        for lane in lanes {
            // Each lane's converter is cached (source/target formats are fixed for
            // the lane's lifetime), so this reuses one `AVAudioConverter` across the
            // whole stream instead of building one per buffer per lane.
            if let buf = lane.converter.convert(input.buffer, to: lane.format) {
                lane.continuation.yield(AnalyzerInput(buffer: buf))
            }
        }
    }

    private func finishLaneInputs() {
        for lane in lanes { lane.continuation.finish() }
    }

    /// Stop all lanes and return the language-routed spans (per-segment confidence
    /// vote, anchored on `anchorLocale`). Empty if nothing was transcribed. Includes
    /// every rotated-out generation's words plus the final live generation's.
    func finish(anchorLocale: String) async -> [StreamLanguageVoter.Span] {
        inputContinuation?.finish()
        inputContinuation = nil
        await fanoutTask?.value
        fanoutTask = nil

        // Finalize every lane at once: they're independent recognizers, so a
        // three-language meeting waits for the slowest lane, not the sum of all.
        let closing = lanes
        for lane in closing { lane.continuation.finish() }
        let jobs = closing.map { (analyzer: $0.analyzer, results: $0.results, localeID: $0.localeID) }
        let harvested = await withTaskGroup(of: (Int, [StreamLanguageVoter.TimedWord]).self) { group in
            for (i, job) in jobs.enumerated() {
                group.addTask {
                    (i, await Self.finalizeGeneration(analyzer: job.analyzer, results: job.results,
                                                      localeID: job.localeID))
                }
            }
            var out = [[StreamLanguageVoter.TimedWord]](repeating: [], count: jobs.count)
            for await (i, words) in group { out[i] = words }
            return out
        }
        var all: [StreamLanguageVoter.TimedWord] = []
        for (lane, raw) in zip(closing, harvested) {
            let off = lane.offset
            all.append(contentsOf: lane.collected)
            all.append(contentsOf: raw.map { w in
                var w = w; w.start += off; w.end += off; return w
            })
        }
        lanes = []

        let spans = StreamLanguageVoter.mergeWords(all)
        talkieDebugLog("meeting-merge[\(anchorLocale)] words=\(all.count) → \(spans.count) span(s): "
            + spans.map { "\($0.localeID):'\($0.text.prefix(24))'" }.joined(separator: " | "))
        return spans
    }

    /// Longest one analyzer generation's finalize + reader drain may take before it is
    /// hard-cancelled. Apple's `finalizeAndFinishThroughEndOfInput` can silently never
    /// return — the same non-termination `TranscriptionEngine.finishSessionDetailed`
    /// bounds for dictation. Unbounded here, it parked `MeetingRecorder.stop()` forever:
    /// the note was never saved (it came back as a "Recovered meeting" on relaunch) and
    /// dictation stayed locked out. A healthy finalize takes well under a second.
    static let finalizeTimeout: Double = 10

    /// Finalize one analyzer generation and return its words (analyzer clock), bounded
    /// by `finalizeTimeout`. On timeout the analyzer is hard-cancelled (cooperative
    /// cancellation doesn't reach Apple's finalize) and the reader is cancelled, which
    /// ends it with the words finalized so far — so a wedged lane costs its unfinalized
    /// tail, never the meeting.
    private static func finalizeGeneration(
        analyzer: SpeechAnalyzer,
        results: Task<[StreamLanguageVoter.TimedWord], Never>,
        localeID: String
    ) async -> [StreamLanguageVoter.TimedWord] {
        let finishedInTime = await withAsyncTimeout(
            seconds: finalizeTimeout,
            operation: {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    // A throwing finalize may leave the results stream open forever;
                    // cancel the reader so the drain below resolves.
                    results.cancel()
                    talkieDebugLog("meeting-lane[\(localeID)]: finalize threw — cancelling reader")
                }
                _ = await results.value
            },
            onTimeout: {
                await analyzer.cancelAndFinishNow()
                results.cancel()
            }
        )
        if !finishedInTime {
            talkieDebugLog("meeting-lane[\(localeID)]: finalize exceeded \(Int(finalizeTimeout))s — force-cancelled, keeping the words finalized so far")
        }
        return await results.value
    }

    /// Hard-cancel without producing a transcript.
    func cancel() async {
        inputContinuation?.finish()
        inputContinuation = nil
        fanoutTask?.cancel()
        fanoutTask = nil
        for lane in lanes {
            await lane.analyzer.cancelAndFinishNow()
            lane.results.cancel()
            lane.continuation.finish()
        }
        lanes = []
    }
}
