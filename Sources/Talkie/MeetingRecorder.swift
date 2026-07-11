@preconcurrency import AVFoundation
import Foundation

/// A confined, non-blocking sink that writes converted PCM to one compressed `.m4a`
/// file (D9 keep-audio tee). It sits behind the capture classes' `onBuffer` tap, which
/// fires on the realtime capture/IOProc thread — so the one hard rule is **never block
/// that thread**. `append(_:)` therefore only bounces the buffer onto a private serial
/// queue and returns immediately; all `AVAudioFile` I/O happens on that queue, one
/// buffer at a time (mirroring the `SingleShotInput`/`OneShot` confinement pattern and
/// `AudioCapture`'s own lock discipline). `@unchecked Sendable` is accurate because
/// every mutable member (`file`, `failed`) is touched ONLY inside `queue`; nothing else
/// reads them.
///
/// The file is created lazily from the FIRST buffer's format, so the on-disk stream is
/// exactly what the recognizer heard (the analyzer's mono format) encoded as AAC — the
/// faithful source for quote-verification, and small on disk. If encoding setup or a
/// write ever fails, it latches `failed` and silently drops the rest: a broken tee must
/// never take down a recording, and a half-written file simply means that stream offers
/// no playback (the row degrades gracefully).
final class MeetingAudioFileWriter: @unchecked Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private var failed = false
    private var started = false
    /// Latched true inside `close()`. A mic-tap buffer can still be queued (or already
    /// in flight on `queue`) at the moment `close()` runs — `AudioCapture.stop()` does
    /// not drain in-flight tap callbacks the way `SystemAudioCapture` does — and without
    /// this latch that late `append` would see `file == nil` and re-create the just-
    /// finalized AVAudioFile, truncating (and resurrecting) the finished m4a. Checked
    /// alongside `failed` in `append`'s guard so a post-close buffer is a silent no-op.
    private var closed = false

    init(url: URL) {
        self.url = url
        self.queue = DispatchQueue(label: "com.coralate.talkie.meeting-audio-writer")
    }

    /// Hand one converted buffer to the writer. Returns instantly; the copy-free handoff
    /// is safe because the capture classes allocate a FRESH output buffer per convert
    /// (it does not alias the RT block's input), so the closure can retain it. All actual
    /// file work runs serialized on `queue`.
    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard !failed, !closed else { return }
            if file == nil {
                // Create the AAC file from the first buffer's format. `settings` asks for
                // MPEG-4 AAC in the same channel/rate as the incoming PCM; AVAudioFile
                // does the PCM→AAC encode on write.
                var settings = buffer.format.settings
                settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
                do {
                    file = try AVAudioFile(
                        forWriting: url, settings: settings,
                        commonFormat: buffer.format.commonFormat,
                        interleaved: buffer.format.isInterleaved)
                    started = true
                } catch {
                    failed = true
                    return
                }
            }
            do {
                try file?.write(from: buffer)
            } catch {
                // One failed write shouldn't spam; latch and stop.
                failed = true
            }
        }
    }

    /// Flush and close the file, blocking only the caller (never the RT thread) until the
    /// serial queue drains the last queued write. Idempotent — a second close is a no-op.
    /// Returns whether a usable file was actually produced (at least one buffer written
    /// and no failure), so the recorder only records `audioFiles` for streams that really
    /// have playable audio on disk.
    @discardableResult
    func close() -> Bool {
        queue.sync {
            file = nil // releasing the AVAudioFile finalizes the m4a container
            closed = true // latch: any append still in flight/queued becomes a no-op
        }
        return started && !failed
    }
}

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

    /// Chapter boundaries the live subtopic engine accepted during THIS recording,
    /// in accept order (D8). AppDelegate resets it at `onRecordingStarted` and
    /// appends `(topic, elapsed)` on every accept; `stop()` snapshots it into the
    /// composed `Meeting.chapters` *synchronously, before its first `await`*, then
    /// clears it — so the ordering trap is closed: the collector is filled through
    /// recording and consumed at compose-time, never handed over in the stop path
    /// where the `$isRecording` sink has already reset the engine. `@MainActor` state
    /// (the class is `@MainActor`), mutated and read only on the main actor.
    var pendingChapters: [Chapter] = []

    private let engine: TranscriptionEngine // shared mic engine ("Me")
    private let store: MeetingStore
    private let summarizer = MeetingSummarizer()
    private let audio = AudioCapture()
    private let systemAudio = SystemAudioCapture()

    /// A dedicated engine for the far-end stream ("Them"); built per recording and
    /// torn down on stop. Nil when recording mic-only.
    private var farEngine: TranscriptionEngine?

    /// True once the far-end stream has actually started at any point during THIS
    /// recording — set the moment `farActive` first becomes true in `start()` (either
    /// the multilingual lanes or the single-locale fallback) and, unlike the live
    /// `capturingFarEnd` flag, NEVER reset by the zero-PCM watchdog giving up mid-
    /// meeting. `stop()` gates the far-end multilingual merge/language correction and
    /// the meeting's `participants`/`source` on THIS flag rather than the live
    /// `capturingFarEnd`, so a watchdog give-up mid-call can no longer discard the
    /// real far-end transcript already captured before the tap died, nor mislabel a
    /// meeting that genuinely captured both sides as mic-only. Reset to false at the
    /// top of every `start()` attempt.
    private var farEverActive = false

    /// Multilingual mode: one recognizer per spoken language per stream, live, with
    /// a per-segment confidence vote at stop. Set when the user speaks >1 language
    /// (and the lanes start); nil falls back to the single-locale `engine`/`farEngine`.
    private var micMulti: MultiLangStreamTranscriber?
    private var farMulti: MultiLangStreamTranscriber?

    /// Analyzer-rotation clock (far-end diarization-stall fix). A single `SpeechAnalyzer`
    /// stops finalizing on a long continuous stream (~30 min in), collapsing the rest of
    /// the transcript under one timecode. `tick()` rotates the live multilingual lanes
    /// every `meetingRotationInterval` seconds so no analyzer ever lives that long. The
    /// in-flight rotation is tracked so `stop()` can await it before finalizing (rotation
    /// and finish both mutate lane state on the same actor and must not overlap).
    private var lastRotationElapsed: TimeInterval = 0
    private var rotationTask: Task<Void, Never>?
    /// Comfortably under the observed ~30-min stall, so a fresh analyzer is always well
    /// within its healthy window (single-locale streams rely on the renderer's
    /// stall-collapse safeguard instead of rotation).
    private static let meetingRotationInterval: TimeInterval = 600

    private var turnLog: TurnLog?
    private var startedAt: Date?
    private var partialURL: URL?
    private var timer: Timer?

    /// Cheap dirty-check for the per-second partial flush: the last flush's
    /// (notes, turn count). A 2-hour meeting must not re-serialize and re-write an
    /// identical partial every second, so `tick()` skips the write when neither the
    /// notes string nor the turn count has changed (and the far-end flag hasn't
    /// flipped) since the last flush. Reset when a recording starts (in `start()`).
    private var lastFlushedNotes: String?
    private var lastFlushedTurnCount = -1
    private var lastFlushedFarEnd: Bool?

    /// Guards the async `start()` window: `start()` does several `await`s (mic
    /// permission, model load, two `beginSession`s). `isStarting` blocks a second
    /// start during that window; `cancelStart` lets a `stop()` tapped mid-start
    /// abort the in-flight setup so it never goes live unstopped. Exposed read-only
    /// (`private(set)`) so AppDelegate can guard dictation-start against this same
    /// startup window — a meeting mid-`start()` also holds the shared mic engine.
    @Published private(set) var isStarting = false
    private var cancelStart = false

    /// Snapshotted at start() so a mid-recording settings change can't skew the
    /// stop()-time language correction.
    private var langsAtStart: [String] = []
    private var micLocale = "en-US"
    private var farLocale = "en-US"

    // MARK: Keep-audio tee (D9)
    //
    // When the "Keep audio with meeting notes" toggle is on, the recording tees each
    // stream's converted PCM to an AAC `.m4a` beside the note. The toggle is snapshotted
    // ONCE at start() (like langsAtStart) — flipping it mid-call never changes what a
    // recording already committed to. The meeting id is also fixed at start() so the
    // audio filenames share the `.md` basename the meeting will get at stop().
    /// Whether THIS recording keeps audio (snapshot of the toggle at start()).
    private var keepAudio = false
    /// The meeting id chosen at start() so audio filenames align with the note; consumed
    /// when the `Meeting` is built at stop().
    private var pendingMeetingID: UUID?
    /// The per-stream writers, non-nil only while a keep-audio recording is live. Closed
    /// on every start()/stop() exit path so a crash mid-recording leaves at most a
    /// partial (harmless) file, never an open handle.
    private var micWriter: MeetingAudioFileWriter?
    private var farWriter: MeetingAudioFileWriter?
    /// The audio filenames decided at start() (so they share the note's basename), used
    /// to record `audioFiles` and to clean up partials on a discarded start. Empty when
    /// keep-audio is off for this recording.
    private var micAudioName = ""
    private var farAudioName = ""
    /// The `speaker → basename` map accumulated for the streams actually opened, folded
    /// into `Meeting.audioFiles` at stop(). Empty unless keep-audio was on AND a stream
    /// produced a usable file.
    private var keepAudioFiles: [String: String] = [:]

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
        farEverActive = false
        defer { isStarting = false }

        guard await AudioCapture.requestMicrophoneAccess() else { return false }
        if cancelStart { return false } // stopped during the permission prompt; nothing built yet

        let start = Date()
        let log = TurnLog(startedAt: start)
        // Snapshot the live-segment feed once so both stream handlers (which run on
        // the transcriber's @Sendable executor) capture a Sendable value, not `self`.
        let liveFeed = onLiveSegment
        // Structured crash partial (C7): a hidden JSON dotfile in the meetings folder,
        // flushed every second by `tick()` and recovered on the next launch. Seed it
        // now with the true start time so a crash during setup still recovers an honest
        // timeline; `tick()` fills in notes/transcript/far-end as they change.
        let pURL = AppPaths.meetingsDirectory().appendingPathComponent(".recording.partial.json")
        if let seed = Self.encodePartial(
            RecordingPartial(startedAt: start.timeIntervalSince1970, farEnd: false, notes: "", transcript: "")
        ) {
            try? seed.write(to: pURL, options: .atomic)
        }

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

        // Keep-audio (D9): snapshot the toggle ONCE, now — mid-call flips don't count.
        // Fix the meeting id here too so the audio filenames share the `.md` basename the
        // meeting gets at stop(). The mic writer is opened eagerly (the mic stream always
        // exists); the far writer is opened only if the far-end stream comes up, below.
        keepAudio = AppSettings.keepMeetingAudioEnabled
        keepAudioFiles = [:]
        micWriter = nil
        farWriter = nil
        let meetingID = UUID()
        pendingMeetingID = meetingID
        if keepAudio {
            let audioStem = (MeetingStore.fileName(for: start, id: meetingID) as NSString).deletingPathExtension
            micAudioName = "\(audioStem)-me.m4a"
            farAudioName = "\(audioStem)-them.m4a"
        } else {
            micAudioName = ""
            farAudioName = ""
        }
        let micTap = keepAudio ? makeWriterTap(basename: micAudioName, assignTo: \.micWriter) : nil

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
                                    onBuffer: micTap,
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
                                onBuffer: micTap,
                                onCaptureFailed: { [weak self] error in
                                    Task { @MainActor in self?.handleMicCaptureFailure(error) }
                                })
            }
        } catch {
            await engine.cancelSession()
            if let mic = micMulti { await mic.cancel(); micMulti = nil }
            closeAudioWriters(record: false) // discard any partial mic tee
            try? FileManager.default.removeItem(at: pURL)
            return false
        }
        // Stopped while the mic session was spinning up → tear the mic back down.
        if cancelStart {
            audio.stop()
            if let mic = micMulti { await mic.cancel(); micMulti = nil }
            else { _ = await engine.finishSession() }
            closeAudioWriters(record: false) // discard any partial mic tee
            try? FileManager.default.removeItem(at: pURL)
            return false
        }

        // 2. Far-end stream → "Them". Best-effort: any failure (unsupported OS,
        //    permission denied, too many concurrent analyzers) degrades cleanly to
        //    mic-only. Multilingual uses live per-language lanes like the mic; if
        //    those can't start (e.g. analyzer cap), it falls back to a single engine.
        var farActive = false
        // The far-end keep-audio tap is created only if the far stream actually comes up
        // (below), so a mic-only recording never opens a "-them" file. Built lazily so the
        // writer isn't created for a stream that fails to start.
        if SystemAudioCapture.isSupported {
            let farTap: (@Sendable (AVAudioPCMBuffer) -> Void)? =
                keepAudio ? makeWriterTap(basename: farAudioName, assignTo: \.farWriter) : nil
            if multiLang, distinctLangs.count > 1, MultiLangStreamTranscriber.isAvailable {
                let fm = MultiLangStreamTranscriber()
                if let farSession = try? await fm.start(
                    localeIDs: distinctLangs, contextualStrings: eventAttendees,
                    onLiveSegment: { segment in log.add(.them, segment); liveFeed?(.them, segment) }
                ), (try? systemAudio.start(targetFormat: farSession.format, continuation: farSession.continuation,
                                           onBuffer: farTap)) != nil {
                    farMulti = fm
                    farActive = true
                    farEverActive = true
                } else {
                    await fm.cancel()
                }
            }
            if farMulti == nil {
                let locale = farLocale
                let far = PrivacyWall.assertLocal(TranscriptionEngine(localeIdentifier: locale))
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
                                          bufferAudio: multiLang, bufferSeconds: 600,
                                          onBuffer: farTap)
                    farEngine = far
                    farActive = true
                    farEverActive = true
                    farLocale = locale
                } catch {
                    await far.cancelSession()
                }
            }
            // The far stream never started → drop the writer we speculatively created so
            // it can't linger holding a (never-written) "-them" file open, and clear its
            // recorded name so stop() won't claim a Them file that doesn't exist.
            if !farActive, farWriter != nil {
                farWriter?.close()
                farWriter = nil
                try? FileManager.default.removeItem(
                    at: AppPaths.meetingsDirectory().appendingPathComponent(farAudioName))
                farAudioName = ""
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
            closeAudioWriters(record: false) // discard any partial mic/far tee
            try? FileManager.default.removeItem(at: pURL)
            return false
        }

        // Commit (no awaits past here, so this runs atomically on the main actor).
        turnLog = log
        startedAt = start
        partialURL = pURL
        // Reset the flush dirty-check to EXACTLY the seed partial that was written to
        // disk above (empty notes/turns, `farEnd: false`). So if this recording is
        // actually capturing the far end (`farActive`), the very first tick sees the
        // flag differ from disk and flushes, correcting `farEnd` in the partial; and
        // steady state still elides identical re-writes for a long meeting.
        lastFlushedNotes = ""
        lastFlushedTurnCount = 0
        lastFlushedFarEnd = false
        // Clear any chapters left by a prior recording so this meeting starts fresh
        // (belt-and-suspenders: AppDelegate also resets at onRecordingStarted).
        pendingChapters = []
        elapsed = 0
        lastRotationElapsed = 0
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

    // MARK: Keep-audio tee helpers (D9)

    /// Build a writer for `basename` in ~/Talkie Meetings/, stash it on `self` via
    /// `keyPath` (so stop()/teardown can close it), and return the `@Sendable` tap that
    /// forwards converted buffers to it. The tap captures the writer directly (a
    /// `Sendable` class), never `self`, so it's safe on the capture thread. Called on the
    /// main actor while wiring a stream, before that stream's capture starts.
    private func makeWriterTap(
        basename: String,
        assignTo keyPath: ReferenceWritableKeyPath<MeetingRecorder, MeetingAudioFileWriter?>
    ) -> @Sendable (AVAudioPCMBuffer) -> Void {
        let writer = MeetingAudioFileWriter(
            url: AppPaths.meetingsDirectory().appendingPathComponent(basename))
        self[keyPath: keyPath] = writer
        return { buffer in writer.append(buffer) }
    }

    /// Close both keep-audio writers (idempotent) and record `audioFiles` entries only
    /// for streams that produced a usable file. Safe to call from ANY start()/stop()
    /// exit path — a nil writer is a no-op, and closing twice is harmless. `record`
    /// gates whether the produced files become part of the meeting: a real stop
    /// closes+records; a cancelled/failed start closes and DELETES the partials so a
    /// discarded recording leaves nothing behind. Uses the filenames fixed at start(),
    /// so they always match the note's basename.
    private func closeAudioWriters(record: Bool) {
        if let mic = micWriter {
            let ok = mic.close()
            if record, ok, !micAudioName.isEmpty { keepAudioFiles["Me"] = micAudioName }
            micWriter = nil
        }
        if let far = farWriter {
            let ok = far.close()
            if record, ok, !farAudioName.isEmpty { keepAudioFiles["Them"] = farAudioName }
            farWriter = nil
        }
        if !record {
            // A discarded start: remove any partial files the writers may have created so
            // a cancelled recording leaves nothing behind.
            for name in [micAudioName, farAudioName] where !name.isEmpty {
                try? FileManager.default.removeItem(
                    at: AppPaths.meetingsDirectory().appendingPathComponent(name))
            }
            keepAudioFiles = [:]
        }
    }

    /// Delete any kept-audio files already written for THIS recording and forget them —
    /// used when a recording produced no transcript, so a notes-only/empty meeting doesn't
    /// leave orphan audio on disk that delete could never reach. Best-effort; the writers
    /// were already closed by `closeAudioWriters(record: true)`.
    private func discardKeptAudioFiles() {
        for name in keepAudioFiles.values where !name.isEmpty {
            try? FileManager.default.removeItem(
                at: AppPaths.meetingsDirectory().appendingPathComponent(name))
        }
        keepAudioFiles = [:]
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)

        // Zero-PCM far-end tap watchdog (plan 01 §4.2a). Only meaningful while we
        // believe we're capturing the far end: poll its health, passing the mic-alive
        // cross-check so a genuinely quiet call isn't mistaken for a dead tap. The
        // watchdog rebuilds a dead tap transparently; if it stays dead past the cap it
        // gives up, and we honestly downgrade the record card to "Recording (mic
        // only)…" (MeetingsView flips automatically off `capturingFarEnd`). Run it
        // BEFORE the partial flush so a same-tick downgrade is reflected in `farEnd`.
        if capturingFarEnd {
            let micAge = audio.secondsSinceLastBuffer()
            if systemAudio.checkHealth(micSecondsSinceLastBuffer: micAge) == .gaveUp {
                capturingFarEnd = false
                talkieDebugLog("MeetingRecorder: far-end capture gave up (dead tap) — now recording mic only.")
            }
        }

        // Analyzer rotation (far-end diarization-stall fix): periodically retire and
        // rebuild the live multilingual analyzers so none runs long enough to stop
        // finalizing (~30 min in) and collapse the rest of the transcript under one
        // timecode. A no-op when there are no lanes; single-locale streams rely on the
        // renderer's stall-collapse safeguard. The rotation runs off the main actor;
        // `stop()` awaits `rotationTask` before finalizing so the two never overlap.
        //
        // Gated on `!isFinishing`: a tick queued on the run loop before `stop()`
        // invalidated the timer can still fire (and this `tick()` body run) while
        // `stop()` is suspended at one of its later `await`s — `isFinishing` flips
        // true synchronously at the very top of `stop()`, before any of those awaits,
        // so a tick landing in that window sees it and must not START a new rotation:
        // one racing `mic.rotate()`/`far.rotate()` against `stop()`'s own
        // `mic.finish()`/`farM.finish()` on the same transcriber actor is exactly the
        // reentrancy that can wedge `isFinishing` forever. The in-flight-rotation
        // guards below re-check `!isFinishing` after each await, before touching the
        // analyzers, so a rotation that started just before `stop()` set the flag
        // still bails rather than mutating lane state `stop()` is about to finalize.
        if !isFinishing, elapsed - lastRotationElapsed >= Self.meetingRotationInterval,
           micMulti != nil || farMulti != nil {
            lastRotationElapsed = elapsed
            let far = farMulti, mic = micMulti
            rotationTask = Task { @MainActor [weak self] in
                guard self?.isFinishing != true else { return }
                await far?.rotate()
                guard self?.isFinishing != true else { return }
                await mic?.rotate()
            }
        }

        // Periodic crash-safety flush of the structured partial (C7): transcript AND
        // the user's typed live notes AND the far-end flag, so a crash loses nothing.
        // `notes` is @Published main-actor state and `tick()` is main-actor, so this
        // read is in-isolation with no hop. Cheap dirty-check: skip the (re-)serialize
        // and write entirely when nothing observable changed since the last flush —
        // a 2-hour meeting must not re-write an identical partial 7200 times.
        flushPartialIfDirty()
    }

    /// Serialize and atomically write the crash partial only when it has changed since
    /// the last flush. The dirty-check compares the notes string, the turn count, and
    /// the far-end flag — the three things that can move a partial's content — so
    /// steady state (nothing said, nothing typed) costs a couple of comparisons, not a
    /// full JSON encode + disk write, every second.
    private func flushPartialIfDirty() {
        guard let turnLog, let partialURL, let startedAt else { return }
        let turns = turnLog.snapshot()
        let farEnd = capturingFarEnd
        // Nothing observable changed → don't re-serialize identical bytes.
        if lastFlushedNotes == notes,
           lastFlushedTurnCount == turns.count,
           lastFlushedFarEnd == farEnd {
            return
        }
        let partial = RecordingPartial(
            startedAt: startedAt.timeIntervalSince1970,
            farEnd: farEnd,
            notes: notes,
            transcript: MeetingTranscriptRenderer.render(turns)
        )
        guard let data = Self.encodePartial(partial) else { return }
        try? data.write(to: partialURL, options: .atomic)
        lastFlushedNotes = notes
        lastFlushedTurnCount = turns.count
        lastFlushedFarEnd = farEnd
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
        // Capture is fully stopped (both stop()s drained their in-flight buffers), so the
        // keep-audio tee has seen its last buffer — close the writers now and record which
        // streams produced a usable file. `close()` blocks only here (its serial queue),
        // never the capture thread. The resulting `keepAudioFiles` is folded into the
        // meeting below; if the recording turns out empty, the files are discarded there.
        closeAudioWriters(record: true)

        let start = startedAt ?? Date()
        let duration = Date().timeIntervalSince(start)
        let log = turnLog
        let langs = langsAtStart
        let userNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        // Snapshot the chapters SYNCHRONOUSLY here, before the first `await` below, so
        // the ordering trap is closed: the `$isRecording` sink (which fires the moment
        // we set `isRecording = false` above) resets the subtopic engine, but the
        // boundaries it already accepted live in this main-actor array and are captured
        // now. Any accept still queued as a main-actor task runs either before this line
        // or after `stop()` next suspends — never torn. `nil` (not `[]`) when empty so a
        // meeting with no topic shifts decodes/persists exactly like a pre-D8 note.
        let chapters = pendingChapters.isEmpty ? nil : pendingChapters
        pendingChapters = []

        // Await any in-flight analyzer rotation before finalizing: rotation and finish
        // both mutate lane state on the transcriber actor and must not overlap. The
        // timer is already invalidated above, so no new rotation can start after this.
        await rotationTask?.value
        rotationTask = nil

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
            // Gate on `farEverActive` — whether the far stream ran at ANY point this
            // meeting — not the live `capturingFarEnd`: a mid-meeting watchdog give-up
            // already flipped that to false, and gating here on the live flag used to
            // silently discard a real far-end multilingual merge whenever the far tap
            // died before stop().
            if let log, farEverActive { applyMergedSpans(spans, speaker: .them, log: log) }
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
            // Same `farEverActive` gate as above — a watchdog give-up mid-meeting must
            // not skip the language correction for a far stream that genuinely ran.
            if !farWasMulti, let far, farEverActive {
                await correctStreamLanguage(.them, engine: far, buffers: systemAudio.bufferedAudio(),
                                            streamLocale: farLocale, langs: langs, log: log)
            }
        }
        farEngine = nil

        startedAt = nil
        turnLog = nil

        let finalTurns = log?.snapshot() ?? []
        // Pass the meeting `duration` so the renderer can de-collapse a stalled-recognizer
        // timestamp collapse (a long run of one speaker's turns frozen under a single
        // timecode) into readable, spread-out lines. A no-op on healthy transcripts.
        let transcript = MeetingTranscriptRenderer.render(finalTurns, duration: duration)
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Per-segment audio-clock timings for captions/click-to-play/chapters. Built
        // from the SAME final snapshot as the transcript, so they never disagree; the
        // rendered transcript and `.md` are unchanged (segments live only in the index).
        let segments = MeetingTranscriptRenderer.segments(from: finalTurns, duration: duration)
        guard !clean.isEmpty else {
            // Nothing was transcribed → any kept audio has no transcript to verify against
            // and no meeting will reference it (a notes-only meeting has no segments, so it
            // isn't playable). Discard the files so we never orphan audio on disk that
            // delete could never reach.
            discardKeptAudioFiles()
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

        // Participants reflect whether the far end was EVER captured this meeting
        // (`farEverActive`), not just who happened to speak or whether capture was
        // still live at the moment of stop() — so a captured-but-silent far end is
        // still reported honestly, and a mid-meeting watchdog give-up no longer
        // mislabels a meeting that genuinely captured both sides as mic-only (stays
        // consistent with `source` below and with the merge/correction gates above).
        let participants = farEverActive ? ["Me", "Them"] : ["Me"]

        // Granola magic: if you jotted notes during the call, fuse them with the
        // transcript (expanded, never invented); otherwise the plain on-device summary.
        // If fusion is unavailable (the on-device model isn't ready / returns nil),
        // `composeSummary` still preserves the raw notes so the user's typed work is
        // never silently discarded.
        let fused: String?
        if !userNotes.isEmpty {
            fused = await MeetingNotesFusion().fuse(notes: userNotes, transcript: clean, using: PrivacyWall.assertLocal(OnDeviceLLM()))?.bodyMarkdown
        } else {
            fused = nil
        }
        // Summarize AND get back a condensed view (transcript when short, else the
        // map partials) sized for the Stage-2 extractor's 4000-char cap.
        let (transcriptSummaryOpt, condensed) = await summarizer.summarizeCondensed(clean)
        let transcriptSummary = transcriptSummaryOpt ?? ""
        var summary = Self.composeSummary(userNotes: userNotes, transcriptSummary: transcriptSummary, fused: fused)

        // Stage-2 LLM extraction: pull real people / projects / commitments out of
        // the meeting so the graph, the Brief, and `list_commitments` have data
        // worth querying — layered on top of the Stage-1 heuristics below. Runs the
        // extractor over each ≤4000-char chunk of `condensed` (already within budget
        // for short meetings; the joined map partials for long ones), then dedupes
        // by (kind, lowercased name). When Apple Intelligence is unavailable the
        // extractor returns [] for every chunk → no section, Stage-1-only ingest →
        // finalize output is byte-identical to today. ALL of these awaits happen
        // BEFORE store.add so the store.add→partial-removal block stays await-free
        // (crash-atomic), per plan 01's finalize ordering.
        var graphCandidates: [ContextGraphExtractor.Candidate] = []
        if contextGraph != nil, OnDeviceLLM.isAvailable {
            let extractor = GraphLLMExtractor(summarizer: PrivacyWall.assertLocal(OnDeviceLLM(temperature: 0.1)))
            var seenGraph = Set<String>()
            for chunk in MeetingSummarizer.chunkForSinglePass(condensed) {
                for candidate in await extractor.extract(from: chunk) {
                    let key = "\(candidate.kind.rawValue)|\(candidate.displayName.lowercased())"
                    if seenGraph.insert(key).inserted { graphCandidates.append(candidate) }
                }
            }
        }

        // Append an "## Action items" section built from the extracted commitments,
        // but only when there's ≥1 AND the summary doesn't already list action items
        // (the summarizer/fusion prompts emit their own best-effort bullets).
        if let section = Self.actionItemsSection(
            commitments: graphCandidates, existingSummary: summary
        ) {
            summary = summary.isEmpty ? section : summary + "\n\n" + section
        }

        // Reuse the id fixed at start() so the `.md` basename matches the kept-audio
        // filenames (only meaningful when keep-audio was on; harmless otherwise).
        let id = pendingMeetingID ?? UUID()
        pendingMeetingID = nil
        // Fold in the kept-audio map, if this recording produced any files. Empty →
        // nil, so a no-keep-audio meeting persists exactly like before (no key).
        let audioFiles = keepAudioFiles.isEmpty ? nil : keepAudioFiles
        let meeting = Meeting(
            id: id,
            title: eventTitle ?? Self.makeTitle(start: start),
            startUnix: start.timeIntervalSince1970,
            durationSec: duration,
            transcript: clean,
            summary: summary,
            participants: participants,
            source: farEverActive ? "talkie (mic + system audio)" : "talkie (mic-only)",
            fileName: MeetingStore.fileName(for: start, id: id),
            segments: segments,
            chapters: chapters,
            audioFiles: audioFiles
        )
        store.add(meeting)
        keepAudioFiles = [:]
        // The meeting is durably persisted only now — so the crash-partial can only
        // be dropped here, AFTER store.add (not before the summarization awaits, where
        // a crash would lose the whole transcript). No `await` between store.add and
        // this delete: it stays atomic on the main actor.
        if let partialURL { try? FileManager.default.removeItem(at: partialURL) }
        partialURL = nil

        // Feed the context graph: calendar attendees as people + Stage-1 heuristic
        // entities + the Stage-2 LLM candidates extracted above. `ingest` upserts
        // with dedupe, so overlaps between the stages collapse. Stays await-free
        // (single `@MainActor` `ingest` call) — the extraction awaits already ran
        // before store.add.
        if let graph = contextGraph {
            let provenance = Provenance(source: .meeting, sourceID: meeting.id.uuidString,
                                        dateUnix: start.timeIntervalSince1970, snippet: nil)
            var candidates = eventAttendees.map {
                ContextGraphExtractor.Candidate(kind: .person, displayName: $0)
            }
            candidates += ContextGraphExtractor.candidates(from: clean)
            candidates += graphCandidates
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

    // MARK: Crash-safe partial (encode / decode / recovery mapping)

    /// The on-disk crash-recovery record, flushed every second while recording and
    /// parsed once on the next launch. It carries everything a faithful recovery
    /// needs that the old plaintext partial threw away: the true start time (so the
    /// recovered note isn't stamped "now"), the far-end capture flag (so participants
    /// are right without sniffing the transcript for a "Them:" label), and — the real
    /// gap C7 closes — the user's typed live notes, which a crash used to lose.
    /// Written atomically to a hidden dotfile in the meetings folder; `version` lets a
    /// future format change be detected rather than mis-parsed.
    struct RecordingPartial: Codable, Equatable, Sendable {
        var version: Int = 1
        /// Recording start, unix seconds — the honest `startUnix` for recovery.
        var startedAt: Double
        /// Whether the far end was being captured at the last flush (C6 can downgrade
        /// mid-meeting, so this tracks the live flag rather than being fixed at start).
        var farEnd: Bool
        /// The user's typed live notes at the last flush.
        var notes: String
        /// The rendered transcript through the last flush.
        var transcript: String
    }

    /// Deterministic JSON for the partial (sorted keys) so the cheap dirty-check in
    /// `tick()` — which compares the *encoded bytes* against the last flush — never
    /// sees a spurious diff from dictionary key-order churn and re-writes identical
    /// data. `nonisolated` + pure so it's unit-testable and callable off the actor.
    nonisolated static func encodePartial(_ partial: RecordingPartial) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(partial)
    }

    /// Parse a partial's bytes, tolerantly: the structured JSON first, then — for one
    /// release — the legacy plaintext partial an app crashed while writing before this
    /// upgrade. Returns nil when neither yields a recoverable record. Pure/testable.
    nonisolated static func decodePartial(_ data: Data) -> RecordingPartial? {
        if let partial = try? JSONDecoder().decode(RecordingPartial.self, from: data) {
            return partial
        }
        // Legacy shim: a pre-C7 partial was plain rendered-transcript text with no
        // start time or notes. Recover the transcript; stamp start = 0 so the caller
        // falls back to the file's modification date for the timeline (an honest floor,
        // same as the duration floor), and infer far-end from the old "] Them:" sniff.
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        return recoverLegacyPlaintext(raw)
    }

    /// Build a `RecordingPartial` from a legacy plaintext partial (rendered transcript
    /// only). `startedAt = 0` signals "no embedded start time" so recovery uses the
    /// file's modification date; far-end is inferred from the interleaved "] Them:"
    /// label the old renderer emitted for two-speaker calls. Returns nil if empty.
    nonisolated static func recoverLegacyPlaintext(_ raw: String) -> RecordingPartial? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return RecordingPartial(
            version: 0,
            startedAt: 0,
            farEnd: trimmed.contains("] Them:"),
            notes: "",
            transcript: trimmed
        )
    }

    /// The recovered timeline + content derived PURELY from a partial (no actor state,
    /// no I/O) so the start-time / duration-floor / far-end / notes-composition mapping
    /// is unit-testable directly. Returns nil when there is nothing worth recovering
    /// (no transcript AND no notes):
    /// - `start` = the true recorded start (`startedAt`), or `modified` for a legacy
    ///   partial that carried none (`startedAt <= 0`).
    /// - `duration` = an honest floor: the partial file's last-write time minus the
    ///   start (the recording ran at least that long), clamped to ≥ 0.
    /// - `participants` from the `farEnd` flag (no transcript string-sniff).
    /// - `summary` = the raw notes under "## Your notes" via `composeSummary` (or empty
    ///   when there were none) — recovery stays summary-less (no launch-time model call).
    nonisolated static func recoveryPlan(
        from partial: RecordingPartial,
        modified: Date
    ) -> (start: Date, duration: Double, transcript: String, participants: [String], summary: String)? {
        let transcript = partial.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = partial.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty || !notes.isEmpty else { return nil }

        let start = partial.startedAt > 0
            ? Date(timeIntervalSince1970: partial.startedAt)
            : modified
        // Honest duration floor: the file was last flushed at `modified`, so the
        // recording ran at least start→modified. Never negative (clock skew / a
        // legacy partial whose start we defaulted to `modified` → 0).
        let duration = max(0, modified.timeIntervalSince(start))
        return (
            start: start,
            duration: duration,
            transcript: transcript,
            participants: partial.farEnd ? ["Me", "Them"] : ["Me"],
            // Summary-less by design; the raw notes land under "## Your notes" so the
            // user's typed work survives the crash.
            summary: Self.composeSummary(userNotes: notes, transcriptSummary: "", fused: nil)
        )
    }

    /// Assemble the recovered `Meeting` from a parsed partial, or nil when there is
    /// nothing worth recovering. `@MainActor` only because it reaches the main-actor
    /// `MeetingStore.fileName` / `titleFormatter`; all the mapping logic lives in the
    /// pure `recoveryPlan` above, which the tests exercise directly.
    @MainActor
    static func makeRecoveredMeeting(from partial: RecordingPartial, modified: Date) -> Meeting? {
        guard let plan = recoveryPlan(from: partial, modified: modified) else { return nil }
        let id = UUID()
        return Meeting(
            id: id,
            title: "Recovered meeting · " + titleFormatter.string(from: plan.start),
            startUnix: plan.start.timeIntervalSince1970,
            durationSec: plan.duration,
            transcript: plan.transcript,
            summary: plan.summary,
            participants: plan.participants,
            source: "talkie (recovered)",
            fileName: MeetingStore.fileName(for: plan.start, id: id)
        )
    }

    /// Compose the "## Action items" note section from Stage-2 commitment
    /// candidates. Pure (no actor state) so it's unit-testable, mirroring
    /// `composeSummary`. Returns the section markdown, or `nil` — no empty
    /// heading — when it must not be appended:
    /// - No commitment candidates → `nil` (Stage-1-only / model-unavailable path).
    /// - `existingSummary` already contains "action items" (case-insensitively)
    ///   → `nil`, the duplication guard: the `MeetingSummarizer` /
    ///   `MeetingNotesFusion` prompts already ask for best-effort action-item
    ///   bullets, so we don't stack a second heading on top of theirs.
    ///
    /// Candidates are de-duplicated case-insensitively (preserving first-seen
    /// order and surface form) so a repeated commitment yields one bullet.
    nonisolated static func actionItemsSection(
        commitments: [ContextGraphExtractor.Candidate],
        existingSummary: String
    ) -> String? {
        // Only COMMITMENT candidates become action items; ignore any other kind
        // the caller may pass through.
        let clauses = commitments
            .filter { $0.kind == .commitment }
            .map { $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clauses.isEmpty else { return nil }

        // Duplication guard: don't add our heading if the summary already speaks
        // of action items (the summarizer/fusion prompts emit their own).
        guard !existingSummary.lowercased().contains("action items") else { return nil }

        var seen = Set<String>()
        var unique: [String] = []
        for clause in clauses where seen.insert(clause.lowercased()).inserted {
            unique.append(clause)
        }

        let bullets = unique.map { "- \($0)" }.joined(separator: "\n")
        return "## Action items\n\(bullets)"
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

    /// On launch, recover a recording left behind by a crash mid-meeting into a
    /// Meeting (summary-less). Must run before any new recording overwrites the file,
    /// and it's idempotent: the partial is removed right after parse — BEFORE the
    /// `store.add` — so a double launch (or a crash between parse and add) can never
    /// recover the same meeting twice.
    ///
    /// Reads the structured `.recording.partial.json` (C7); for one release it also
    /// falls back to a legacy plaintext `.recording.partial.txt` an older build may
    /// have left behind. The recovered note carries the TRUE start time and an honest
    /// duration floor (from the partial's last-write time), the far-end flag drives
    /// participants, and the user's typed notes are preserved under "## Your notes".
    func recoverPartialIfNeeded() {
        let dir = AppPaths.meetingsDirectory()
        let jsonURL = dir.appendingPathComponent(".recording.partial.json")
        let legacyURL = dir.appendingPathComponent(".recording.partial.txt")
        let fm = FileManager.default

        // Prefer the structured partial; fall back to the legacy plaintext shim.
        let url = fm.fileExists(atPath: jsonURL.path) ? jsonURL : legacyURL
        guard let data = try? Data(contentsOf: url) else {
            // No structured partial and no legacy one to read — but still sweep any
            // stray legacy file so it can't linger and mis-recover on a later launch.
            try? fm.removeItem(at: legacyURL)
            return
        }
        // The file's last-write time is the honest duration-floor anchor: the recording
        // ran at least start→(last flush). Read it BEFORE deleting the file.
        let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? Date()

        // Remove BOTH candidate files now, before store.add, so recovery is idempotent
        // and a leftover legacy file can't shadow a future recording.
        try? fm.removeItem(at: jsonURL)
        try? fm.removeItem(at: legacyURL)

        guard let partial = Self.decodePartial(data),
              let meeting = Self.makeRecoveredMeeting(from: partial, modified: modified)
        else { return }
        store.add(meeting)
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
