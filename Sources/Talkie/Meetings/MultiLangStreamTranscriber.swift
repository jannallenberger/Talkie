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
actor MultiLangStreamTranscriber {
    /// One language's live recognizer over the shared stream.
    private struct Lane {
        let localeID: String
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let format: AVAudioFormat
        let results: Task<[StreamLanguageVoter.TimedWord], Never>
    }

    private var lanes: [Lane] = []
    private var fanoutTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

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
            let transcriber = SpeechTranscriber(
                locale: loc,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.transcriptionConfidence, .audioTimeRange]
            )
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                talkieDebugLog("meeting-lane[\(id)]: skip — model not installed")
                continue
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                talkieDebugLog("meeting-lane[\(id)]: skip — no compatible format")
                continue
            }

            let (laneStream, laneCont) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if !contextualStrings.isEmpty {
                let ctx = AnalysisContext()
                ctx.contextualStrings = [.general: contextualStrings]
                try? await analyzer.setContext(ctx)
            }

            // Live segments are emitted only by the first lane — the live notch
            // needs one stream while recording; the per-language truth is resolved
            // by the merge at stop.
            let liveCb = built.isEmpty ? onLiveSegment : nil
            let laneLocale = id
            let results = Task { () -> [StreamLanguageVoter.TimedWord] in
                var words: [StreamLanguageVoter.TimedWord] = []
                do {
                    for try await result in transcriber.results where result.isFinal {
                        let attr = result.text
                        let fullText = String(attr.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !fullText.isEmpty else { continue }
                        // Per-word timing + confidence is what enables word-level
                        // language routing (a single foreign word in a sentence).
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
                        // Fallback: a result with no per-word timing still votes as
                        // one block over its own range, so nothing is silently lost.
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
                talkieDebugLog("meeting-lane[\(id)]: analyzer.start threw — \(error.localizedDescription)")
                results.cancel()
                laneCont.finish()
                continue
            }
            built.append(Lane(localeID: id, analyzer: analyzer, continuation: laneCont, format: format, results: results))
        }

        // Need at least two lanes to have anything to vote between; otherwise the
        // caller falls back to its normal single-locale path.
        guard built.count >= 2, let reference = built.first?.format else {
            for lane in built { await lane.analyzer.cancelAndFinishNow(); lane.results.cancel(); lane.continuation.finish() }
            talkieDebugLog("meeting-lanes: only \(built.count) lane(s) started — falling back to single locale")
            throw TalkieEngineError.noCompatibleAudioFormat
        }

        self.lanes = built
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

    /// Replay one input buffer into every lane, conforming to each lane's format.
    private func fanout(_ input: AnalyzerInput) {
        for lane in lanes {
            for buf in TranscriptionEngine.conform([input.buffer], to: lane.format) {
                lane.continuation.yield(AnalyzerInput(buffer: buf))
            }
        }
    }

    private func finishLaneInputs() {
        for lane in lanes { lane.continuation.finish() }
    }

    /// Stop all lanes and return the language-routed spans (per-segment confidence
    /// vote, anchored on `anchorLocale`). Empty if nothing was transcribed.
    func finish(anchorLocale: String) async -> [StreamLanguageVoter.Span] {
        inputContinuation?.finish()
        inputContinuation = nil
        await fanoutTask?.value
        fanoutTask = nil

        var all: [StreamLanguageVoter.TimedWord] = []
        for lane in lanes {
            do {
                try await lane.analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                // If finalize throws, the lane's results stream may never terminate
                // and `await lane.results.value` below would hang stop() forever.
                // Cancel the reader: its `for try await … catch {}` returns the words
                // accumulated so far on cancel, so the await resolves promptly.
                // (Mirrors TranscriptionEngine.finishSessionDetailed's guard.)
                lane.results.cancel()
                talkieDebugLog("meeting-lane[\(lane.localeID)]: finalize threw — \(error.localizedDescription); cancelling reader")
            }
            all.append(contentsOf: await lane.results.value)
        }
        lanes = []

        let spans = StreamLanguageVoter.mergeWords(all)
        talkieDebugLog("meeting-merge[\(anchorLocale)] words=\(all.count) → \(spans.count) span(s): "
            + spans.map { "\($0.localeID):'\($0.text.prefix(24))'" }.joined(separator: " | "))
        return spans
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
