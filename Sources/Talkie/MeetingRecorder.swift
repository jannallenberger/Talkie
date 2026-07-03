import AVFoundation
import Foundation

/// Records a meeting from up to two audio streams and labels who said what:
///
/// - **Your mic** → the shared transcription engine → every phrase tagged **"Me"**.
/// - **The far-end** (what the Mac plays from Zoom/Meet/Teams), captured with a
///   Core Audio system-audio tap → a *second* engine → every phrase tagged **"Them"**.
///
/// Two separate streams give perfect 1:1 diarization with zero ML. Each finalized
/// segment is timestamped as it arrives and interleaved into a speaker-labeled
/// transcript. If the far-end tap can't be created (older OS, permission denied),
/// recording falls back to mic-only (Phase 1 behavior) — still useful for your own
/// notes. On stop it assembles the transcript, generates an on-device summary, and
/// saves a markdown meeting note. A `.partial` file is flushed for crash safety.
@MainActor
final class MeetingRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// True while a recording is actually capturing the far end (both sides), false
    /// when it fell back to mic-only. Drives the UI's honest status copy.
    @Published private(set) var capturingFarEnd = false

    /// The user's live notes typed during the meeting (the Granola magic — fused
    /// with the transcript on stop). Two-way bound by MeetingsView.
    @Published var notes = ""

    /// Injected by AppDelegate so meetings feed the on-device context graph.
    weak var contextGraph: ContextGraphStore?

    /// Probe for whether a dictation session is live (the mic engine is shared, so
    /// the two can't run at once). Injected by AppDelegate.
    var isDictating: (() -> Bool)?
    /// Probe for whether a dictation is still being polished/inserted (the post-stop
    /// pipeline still holds the shared engine/audio). Injected by AppDelegate so a
    /// meeting can't start over an in-flight dictation. Mirrors `isDictating`.
    var isProcessingDictation: (() -> Bool)?
    /// The primary locale id for the far-end transcriber. Injected by AppDelegate
    /// so it tracks the user's language setting.
    var primaryLocale: (() -> String)?
    /// The user's configured spoken languages, for per-stream language auto-detect.
    /// When more than one is set, each stream is re-checked at stop and re-transcribed
    /// in its detected language if it was transcribed in the wrong one.
    var spokenLanguages: (() -> [String])?
    /// Meeting language mode: "auto" (multilingual) or a specific locale id to pin
    /// both streams to. Injected by AppDelegate from settings.meetingLanguageMode.
    var meetingLanguageMode: (() -> String)?

    /// Optional live feed of finalized transcript segments (speaker-tagged) for the
    /// in-flight subtopic detector. Invoked from the transcriber's `@Sendable`
    /// segment handler, off the main actor, so it's kept `Sendable` and cheap. It is
    /// snapshotted into a local at `start()`, so it must be wired before recording.
    var onLiveSegment: (@Sendable (MeetingSpeaker, String) -> Void)?

    private let engine: TranscriptionEngine // shared mic engine ("Me")
    private let store: MeetingStore
    private let summarizer = MeetingSummarizer()
    private let audio = AudioCapture()
    private let systemAudio = SystemAudioCapture()

    /// A dedicated engine for the far-end stream ("Them"); built per recording and
    /// torn down on stop. Nil when recording mic-only.
    private var farEngine: TranscriptionEngine?

    /// Multilingual mode: one recognizer per spoken language per stream, live, with
    /// a per-segment confidence vote at stop. Set when the user speaks >1 language
    /// (and the lanes start); nil falls back to the single-locale `engine`/`farEngine`.
    private var micMulti: MultiLangStreamTranscriber?
    private var farMulti: MultiLangStreamTranscriber?

    private var turnLog: TurnLog?
    private var startedAt: Date?
    private var partialURL: URL?
    private var timer: Timer?

    /// Guards the async `start()` window: `start()` does several `await`s (mic
    /// permission, model load, two `beginSession`s). `isStarting` blocks a second
    /// start during that window; `cancelStart` lets a `stop()` tapped mid-start
    /// abort the in-flight setup so it never goes live unstopped.
    private var isStarting = false
    private var cancelStart = false

    /// Snapshotted at start() so a mid-recording settings change can't skew the
    /// stop()-time language correction.
    private var langsAtStart: [String] = []
    private var micLocale = "en-US"
    private var farLocale = "en-US"

    /// Calendar context captured at start() (opt-in): used to title the note and
    /// pre-bias attendee names, and to seed the graph with the people present.
    private var eventTitle: String?
    private var eventAttendees: [String] = []

    init(engine: TranscriptionEngine, store: MeetingStore) {
        self.engine = engine
        self.store = store
    }

    /// Start recording. Returns false if the mic is denied, speech is unavailable,
    /// or a session is already in progress.
    @discardableResult
    func start() async -> Bool {
        guard !isRecording, !isFinishing, !isStarting, TranscriptionEngine.isAvailable else { return false }
        // Reverse exclusivity: never start over a live dictation, nor over one whose
        // post-stop polish/insert is still in flight — both hold the shared mic engine.
        guard isDictating?() != true, isProcessingDictation?() != true else { return false }
        isStarting = true
        cancelStart = false
        defer { isStarting = false }

        guard await AudioCapture.requestMicrophoneAccess() else { return false }
        if cancelStart { return false } // stopped during the permission prompt; nothing built yet

        let start = Date()
        let log = TurnLog(startedAt: start)
        // Snapshot the live-segment feed once so both stream handlers (which run on
        // the transcriber's @Sendable executor) capture a Sendable value, not `self`.
        let liveFeed = onLiveSegment
        let pURL = AppPaths.meetingsDirectory().appendingPathComponent(".recording.partial.txt")
        try? Data().write(to: pURL)

        // Snapshot the language config. When the user speaks more than one language,
        // buffer each stream so it can be re-transcribed in its detected language at
        // stop (a 10-minute rolling window keeps memory bounded for long meetings).
        let mode = meetingLanguageMode?() ?? "auto"
        let pinned = (mode != "auto" && !mode.isEmpty) ? mode : nil
        let langs = spokenLanguages?() ?? []
        // Pinned single-language mode transcribes both streams in that locale and
        // skips the multilingual auto-detect correction; "auto" keeps the existing
        // per-stream detect+correct behavior.
        let multiLang = (pinned == nil) && langs.count > 1
        langsAtStart = (pinned == nil) ? langs : []
        micLocale = pinned ?? (primaryLocale?() ?? "en-US")
        farLocale = micLocale

        // Calendar (opt-in): if granted, title the meeting from the overlapping
        // event and pre-bias attendee names into both recognizers. Returns nil when
        // not authorized — no permission prompt mid-recording.
        eventTitle = nil
        eventAttendees = []
        if CalendarMeetingContext.isAuthorized,
           let event = await CalendarMeetingContext().eventContext(at: start) {
            eventTitle = event.title
            eventAttendees = event.attendeeNames
        }

        // 1. Mic stream → "Me" on the shared engine. Pin it to the primary locale
        //    first: dictation may have left the shared engine stuck on a previously
        //    auto-detected language (it calls setLocaleIdentifier to "stick"), which
        //    would mis-transcribe the mic AND break the stop()-time correction
        //    baseline (micLocale is the primary).
        let distinctLangs = LanguageDetector.distinctByCode(langs)
        do {
            // Multilingual: run one recognizer per language live, vote per segment
            // at stop. Falls back to the single engine if the lanes can't start.
            if multiLang, distinctLangs.count > 1, MultiLangStreamTranscriber.isAvailable {
                let mm = MultiLangStreamTranscriber()
                if let session = try? await mm.start(
                    localeIDs: distinctLangs, contextualStrings: eventAttendees,
                    onLiveSegment: { segment in log.add(.me, segment); liveFeed?(.me, segment) }
                ) {
                    try audio.start(targetFormat: session.format, continuation: session.continuation,
                                    onCaptureFailed: { [weak self] error in
                                        Task { @MainActor in self?.handleMicCaptureFailure(error) }
                                    })
                    micMulti = mm
                } else {
                    await mm.cancel()
                }
            }
            if micMulti == nil {
                await engine.setLocaleIdentifier(micLocale)
                await engine.setContextualStrings(eventAttendees)
                // Timed handler: stamp each finalized segment with its audio-clock
                // span (seconds from session start ≈ recording start) so the meeting
                // carries real per-segment timings and interleaves on the audio clock
                // rather than lagged wall-clock arrival. The live feed still gets the
                // bare text.
                let session = try await engine.beginSession(timedSegmentHandler: { seg in
                    log.add(.me, seg.text, at: seg.start, end: seg.end)
                    liveFeed?(.me, seg.text)
                })
                try audio.start(targetFormat: session.format, continuation: session.continuation,
                                bufferAudio: multiLang, bufferSeconds: 600,
                                onCaptureFailed: { [weak self] error in
                                    Task { @MainActor in self?.handleMicCaptureFailure(error) }
                                })
            }
        } catch {
            await engine.cancelSession()
            if let mic = micMulti { await mic.cancel(); micMulti = nil }
            try? FileManager.default.removeItem(at: pURL)
            return false
        }
        // Stopped while the mic session was spinning up → tear the mic back down.
        if cancelStart {
            audio.stop()
            if let mic = micMulti { await mic.cancel(); micMulti = nil }
            else { _ = await engine.finishSession() }
            try? FileManager.default.removeItem(at: pURL)
            return false
        }

        // 2. Far-end stream → "Them". Best-effort: any failure (unsupported OS,
        //    permission denied, too many concurrent analyzers) degrades cleanly to
        //    mic-only. Multilingual uses live per-language lanes like the mic; if
        //    those can't start (e.g. analyzer cap), it falls back to a single engine.
        var farActive = false
        if SystemAudioCapture.isSupported {
            if multiLang, distinctLangs.count > 1, MultiLangStreamTranscriber.isAvailable {
                let fm = MultiLangStreamTranscriber()
                if let farSession = try? await fm.start(
                    localeIDs: distinctLangs, contextualStrings: eventAttendees,
                    onLiveSegment: { segment in log.add(.them, segment); liveFeed?(.them, segment) }
                ), (try? systemAudio.start(targetFormat: farSession.format, continuation: farSession.continuation)) != nil {
                    farMulti = fm
                    farActive = true
                } else {
                    await fm.cancel()
                }
            }
            if farMulti == nil {
                let locale = farLocale
                let far = TranscriptionEngine(localeIdentifier: locale)
                do {
                    await far.setContextualStrings(eventAttendees)
                    // Timed handler (see the mic stream above): the far-end audio clock
                    // starts at 0 at ITS session start, seconds apart from the mic's, so
                    // cross-stream ordering carries a small relative skew — fine for
                    // interleaving, not promised sample-accurate.
                    let farSession = try await far.beginSession(timedSegmentHandler: { seg in
                        log.add(.them, seg.text, at: seg.start, end: seg.end)
                        liveFeed?(.them, seg.text)
                    })
                    try systemAudio.start(targetFormat: farSession.format, continuation: farSession.continuation,
                                          bufferAudio: multiLang, bufferSeconds: 600)
                    farEngine = far
                    farActive = true
                    farLocale = locale
                } catch {
                    await far.cancelSession()
                }
            }
        }
        // Stopped while the far-end was spinning up → tear everything back down.
        if cancelStart {
            systemAudio.stop()
            audio.stop()
            if let mic = micMulti { await mic.cancel(); micMulti = nil }
            else { _ = await engine.finishSession() }
            if let farM = farMulti { await farM.cancel(); farMulti = nil }
            else if let farEngine { _ = await farEngine.finishSession(); self.farEngine = nil }
            try? FileManager.default.removeItem(at: pURL)
            return false
        }

        // Commit (no awaits past here, so this runs atomically on the main actor).
        turnLog = log
        startedAt = start
        partialURL = pURL
        elapsed = 0
        capturingFarEnd = farActive
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return true
    }

    /// The near-end mic capture failed mid-recording (the active input device changed
    /// and no usable mic remained — `AudioCapture` already tried to recover). Stop and
    /// finalize the recording so what was captured up to the failure is preserved,
    /// rather than letting the meeting run on silently capturing nothing. No-op if a
    /// recording isn't live (e.g. a stray late callback after stop()).
    func handleMicCaptureFailure(_ error: Error) {
        talkieDebugLog("MeetingRecorder: mic capture failed mid-recording: \(error.localizedDescription)")
        guard isRecording, !isFinishing else { return }
        Task { await stop() }
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        // Periodic crash-safety flush of the running transcript.
        if let turnLog, let partialURL {
            let text = MeetingTranscriptRenderer.render(turnLog.snapshot())
            try? text.data(using: .utf8)?.write(to: partialURL, options: .atomic)
        }

        // Zero-PCM far-end tap watchdog (plan 01 §4.2a). Only meaningful while we
        // believe we're capturing the far end: poll its health, passing the mic-alive
        // cross-check so a genuinely quiet call isn't mistaken for a dead tap. The
        // watchdog rebuilds a dead tap transparently; if it stays dead past the cap it
        // gives up, and we honestly downgrade the record card to "Recording (mic
        // only)…" (MeetingsView flips automatically off `capturingFarEnd`).
        if capturingFarEnd {
            let micAge = audio.secondsSinceLastBuffer()
            if systemAudio.checkHealth(micSecondsSinceLastBuffer: micAge) == .gaveUp {
                capturingFarEnd = false
                talkieDebugLog("MeetingRecorder: far-end capture gave up (dead tap) — now recording mic only.")
            }
        }
    }

    /// Stop, transcribe-finalize both streams, summarize, and save the meeting note.
    func stop() async {
        // If a start() is still mid-`await`, signal it to abort so it can't go live
        // unstopped after we return.
        if isStarting { cancelStart = true }
        guard isRecording else { return }
        isRecording = false
        isFinishing = true
        // A wedged finalize must never leave the recorder stuck "finishing" — that
        // would permanently lock out dictation AND new meetings. Clear the flags on
        // EVERY exit path, on the same main actor as the prior manual resets (no new
        // isolation hop), so an unexpected throw/early-return can't wedge the UI.
        defer { isFinishing = false; capturingFarEnd = false }
        timer?.invalidate()
        timer = nil

        // Stop capture first so no more buffers arrive, then finalize each stream.
        systemAudio.stop()
        audio.stop()

        let start = startedAt ?? Date()
        let duration = Date().timeIntervalSince(start)
        let log = turnLog
        let wasFarEnd = capturingFarEnd
        let langs = langsAtStart
        let userNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        // Finalize each stream. A multilingual (live-lanes) stream resolves its
        // per-segment language vote here and rebuilds the speaker's turns — each
        // language span becomes a timed turn, so mid-meeting switches AND cross-
        // stream interleaving both survive. A single-locale stream finalizes as
        // before and gets the legacy whole-stream correction below.
        let micWasMulti = micMulti != nil
        let farWasMulti = farMulti != nil
        if let mic = micMulti {
            let spans = await mic.finish(anchorLocale: micLocale)
            if let log { applyMergedSpans(spans, speaker: .me, log: log) }
            micMulti = nil
        } else {
            _ = await engine.finishSession()
        }
        let far = farEngine
        if let farM = farMulti {
            let spans = await farM.finish(anchorLocale: farLocale)
            if let log, wasFarEnd { applyMergedSpans(spans, speaker: .them, log: log) }
            farMulti = nil
        } else if let far {
            _ = await far.finishSession()
        }

        // Legacy whole-stream language correction — ONLY for streams that used the
        // single-locale fallback (the live-lanes path already routed per segment).
        if langs.count > 1, let log {
            if !micWasMulti {
                await correctStreamLanguage(.me, engine: engine, buffers: audio.bufferedAudio(),
                                            streamLocale: micLocale, langs: langs, log: log)
            }
            if !farWasMulti, let far, wasFarEnd {
                await correctStreamLanguage(.them, engine: far, buffers: systemAudio.bufferedAudio(),
                                            streamLocale: farLocale, langs: langs, log: log)
            }
        }
        farEngine = nil

        startedAt = nil
        turnLog = nil

        let finalTurns = log?.snapshot() ?? []
        let transcript = MeetingTranscriptRenderer.render(finalTurns)
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Per-segment audio-clock timings for captions/click-to-play/chapters. Built
        // from the SAME final snapshot as the transcript, so they never disagree; the
        // rendered transcript and `.md` are unchanged (segments live only in the index).
        let segments = MeetingTranscriptRenderer.segments(from: finalTurns)
        guard !clean.isEmpty else {
            // Nothing was transcribed — but if the user jotted notes, those are real
            // work and must not vanish. Persist a notes-only meeting before clearing,
            // rather than wiping `notes` and returning empty-handed.
            if !userNotes.isEmpty {
                let id = UUID()
                let meeting = Meeting(
                    id: id,
                    title: eventTitle ?? Self.makeTitle(start: start),
                    startUnix: start.timeIntervalSince1970,
                    durationSec: duration,
                    transcript: "",
                    summary: Self.composeSummary(userNotes: userNotes, transcriptSummary: "", fused: nil),
                    participants: ["Me"],
                    source: "talkie (notes only)",
                    fileName: MeetingStore.fileName(for: start, id: id)
                )
                store.add(meeting)
                // Atomic with the persist above (no `await`) so the just-saved meeting
                // can't be lost to a crash before the partial is dropped.
                if let partialURL { try? FileManager.default.removeItem(at: partialURL) }
                partialURL = nil
            } else if let partialURL {
                try? FileManager.default.removeItem(at: partialURL)
                self.partialURL = nil
            }
            // isFinishing / capturingFarEnd are cleared by the `defer` at the top.
            notes = ""
            return
        }

        // Participants reflect what was *captured*, not just who happened to speak,
        // so a captured-but-silent far end is still reported honestly (and stays
        // consistent with `source`).
        let participants = wasFarEnd ? ["Me", "Them"] : ["Me"]

        // Granola magic: if you jotted notes during the call, fuse them with the
        // transcript (expanded, never invented); otherwise the plain on-device summary.
        // If fusion is unavailable (the on-device model isn't ready / returns nil),
        // `composeSummary` still preserves the raw notes so the user's typed work is
        // never silently discarded.
        let fused: String?
        if !userNotes.isEmpty {
            fused = await MeetingNotesFusion().fuse(notes: userNotes, transcript: clean, using: OnDeviceLLM())?.bodyMarkdown
        } else {
            fused = nil
        }
        let transcriptSummary = await summarizer.summarize(clean) ?? ""
        let summary = Self.composeSummary(userNotes: userNotes, transcriptSummary: transcriptSummary, fused: fused)

        let id = UUID()
        let meeting = Meeting(
            id: id,
            title: eventTitle ?? Self.makeTitle(start: start),
            startUnix: start.timeIntervalSince1970,
            durationSec: duration,
            transcript: clean,
            summary: summary,
            participants: participants,
            source: wasFarEnd ? "talkie (mic + system audio)" : "talkie (mic-only)",
            fileName: MeetingStore.fileName(for: start, id: id),
            segments: segments
        )
        store.add(meeting)
        // The meeting is durably persisted only now — so the crash-partial can only
        // be dropped here, AFTER store.add (not before the summarization awaits, where
        // a crash would lose the whole transcript). No `await` between store.add and
        // this delete: it stays atomic on the main actor.
        if let partialURL { try? FileManager.default.removeItem(at: partialURL) }
        partialURL = nil

        // Feed the context graph: calendar attendees as people + transcript entities.
        if let graph = contextGraph {
            let provenance = Provenance(source: .meeting, sourceID: meeting.id.uuidString,
                                        dateUnix: start.timeIntervalSince1970, snippet: nil)
            var candidates = eventAttendees.map {
                ContextGraphExtractor.Candidate(kind: .person, displayName: $0)
            }
            candidates += ContextGraphExtractor.candidates(from: clean)
            graph.ingest(candidates, provenance: provenance)
        }

        // Cleared only after the meeting is durably persisted above (P2-01): the
        // user's notes are never wiped before they're saved somewhere.
        // isFinishing / capturingFarEnd are cleared by the `defer` at the top.
        notes = ""
        eventTitle = nil
        eventAttendees = []
    }

    /// Compose the meeting summary, guaranteeing the user's typed notes are never
    /// silently lost. Pure (no actor state) so it's unit-testable:
    /// - `fused` present → the fusion already incorporated the notes; use it as-is.
    /// - `fused == nil` but notes non-empty → on-device fusion was unavailable/failed,
    ///   so preserve the raw notes verbatim under a "## Your notes" section with an
    ///   explicit notice, followed by the plain transcript summary (if any).
    /// - no notes → the plain transcript summary.
    nonisolated static func composeSummary(userNotes: String, transcriptSummary: String, fused: String?) -> String {
        let notes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = transcriptSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fused, !fused.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fused
        }
        guard !notes.isEmpty else { return summary }
        var parts = [
            "_Notes fusion unavailable — your raw notes are preserved below._",
            "## Your notes\n\n\(notes)",
        ]
        if !summary.isEmpty { parts.append(summary) }
        return parts.joined(separator: "\n\n")
    }

    /// Decide, by AUDIO self-consistency, whether one stream's speech was actually
    /// in a different one of the user's languages than it was transcribed in, and
    /// if so re-transcribe that stream's buffered audio in the right language.
    ///
    /// We do NOT trust language-ID of the streamed text: speech in a non-`streamLocale`
    /// language decoded by the `streamLocale` model comes out as phonetic gibberish,
    /// which NLLanguageRecognizer often mis-scores as `streamLocale` (so the old
    /// "detect a different language from the text" trigger silently never fired).
    /// Instead, if the stream's transcript doesn't confidently read as `streamLocale`,
    /// re-transcribe the audio in each other language and keep whichever output most
    /// strongly self-identifies as its own language. A successful re-transcription
    /// collapses the stream to one block anchored at its first turn; a confident
    /// match is untouched.
    /// Rebuild a speaker's turns from the multilingual merge — one timed turn per
    /// language span, so per-segment language and chronological interleaving survive.
    private func applyMergedSpans(_ spans: [StreamLanguageVoter.Span], speaker: MeetingSpeaker, log: TurnLog) {
        guard !spans.isEmpty else { return }
        log.replace(speaker, withTimedTurns: spans.map { (elapsed: $0.start, text: $0.text, end: $0.end) })
    }

    private func correctStreamLanguage(
        _ speaker: MeetingSpeaker,
        engine: TranscriptionEngine,
        buffers: sending [AVAudioPCMBuffer],
        streamLocale: String,
        langs: [String],
        log: TurnLog
    ) async {
        let streamTurns = log.turns(for: speaker)
        guard !streamTurns.isEmpty, !buffers.isEmpty else { return }
        let raw = streamTurns.map(\.text).joined(separator: " ")

        // Too few words to language-ID → keep the stream as transcribed (avoids
        // re-transcribing every very short stream for no possible gain).
        guard LanguageDetector.canScore(raw) else { return }
        let streamConf = LanguageDetector.selfConsistency(raw, expected: streamLocale, among: langs)
        guard streamConf < LanguageDetector.confidentMatch else { return }

        let others = langs.filter { Self.languageCode($0) != Self.languageCode(streamLocale) }
        let candidates = await engine.transcribeCandidates(buffers, localeIdentifiers: others, installIfNeeded: true)
        var bestText: String?
        var bestConf = streamConf
        for candidate in candidates {
            let conf = LanguageDetector.selfConsistency(candidate.text, expected: candidate.localeID, among: langs)
            if conf > bestConf {
                bestConf = conf
                bestText = candidate.text
            }
        }
        guard let reText = bestText,
              bestConf >= streamConf + LanguageDetector.switchMargin,
              bestConf >= LanguageDetector.switchFloor else { return }
        log.replace(speaker, withSingleTurn: reText, at: streamTurns.first!.elapsed)
    }

    private static func languageCode(_ id: String) -> String {
        Locale(identifier: id).language.languageCode?.identifier ?? id
    }

    /// On launch, recover a transcript left behind by a crash mid-recording into a
    /// Meeting (no summary). Must run before any new recording overwrites the file.
    func recoverPartialIfNeeded() {
        let pURL = AppPaths.meetingsDirectory().appendingPathComponent(".recording.partial.txt")
        guard let raw = try? String(contentsOf: pURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: pURL)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A two-speaker partial carries "] Them:" labels; a solo one doesn't — so the
        // recovered note's participants stay consistent with its transcript shape.
        let recoveredFarEnd = trimmed.contains("] Them:")
        let date = Date()
        let id = UUID()
        store.add(Meeting(
            id: id,
            title: "Recovered meeting · " + Self.titleFormatter.string(from: date),
            startUnix: date.timeIntervalSince1970,
            durationSec: 0,
            transcript: trimmed,
            summary: "",
            participants: recoveredFarEnd ? ["Me", "Them"] : ["Me"],
            source: "talkie (recovered)",
            fileName: MeetingStore.fileName(for: date, id: id)
        ))
    }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func makeTitle(start: Date) -> String {
        "Meeting · " + titleFormatter.string(from: start)
    }
}
