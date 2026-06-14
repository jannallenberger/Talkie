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

    /// Probe for whether a dictation session is live (the mic engine is shared, so
    /// the two can't run at once). Injected by AppDelegate.
    var isDictating: (() -> Bool)?
    /// The primary locale id for the far-end transcriber. Injected by AppDelegate
    /// so it tracks the user's language setting.
    var primaryLocale: (() -> String)?

    private let engine: TranscriptionEngine // shared mic engine ("Me")
    private let store: MeetingStore
    private let summarizer = MeetingSummarizer()
    private let audio = AudioCapture()
    private let systemAudio = SystemAudioCapture()

    /// A dedicated engine for the far-end stream ("Them"); built per recording and
    /// torn down on stop. Nil when recording mic-only.
    private var farEngine: TranscriptionEngine?

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

    init(engine: TranscriptionEngine, store: MeetingStore) {
        self.engine = engine
        self.store = store
    }

    /// Start recording. Returns false if the mic is denied, speech is unavailable,
    /// or a session is already in progress.
    @discardableResult
    func start() async -> Bool {
        guard !isRecording, !isFinishing, !isStarting, TranscriptionEngine.isAvailable else { return false }
        // Reverse exclusivity: never start over a live dictation (shared mic engine).
        guard isDictating?() != true else { return false }
        isStarting = true
        cancelStart = false
        defer { isStarting = false }

        guard await AudioCapture.requestMicrophoneAccess() else { return false }
        if cancelStart { return false } // stopped during the permission prompt; nothing built yet

        let start = Date()
        let log = TurnLog(startedAt: start)
        let pURL = AppPaths.meetingsDirectory().appendingPathComponent(".recording.partial.txt")
        try? Data().write(to: pURL)

        // 1. Mic stream → "Me" on the shared engine.
        do {
            await engine.setContextualStrings([])
            let session = try await engine.beginSession(segmentHandler: { segment in
                log.add(.me, segment)
            })
            try audio.start(targetFormat: session.format, continuation: session.continuation)
        } catch {
            await engine.cancelSession()
            try? FileManager.default.removeItem(at: pURL)
            return false
        }
        // Stopped while the mic session was spinning up → tear the mic back down.
        if cancelStart {
            audio.stop()
            _ = await engine.finishSession()
            try? FileManager.default.removeItem(at: pURL)
            return false
        }

        // 2. Far-end stream → "Them" on a dedicated engine. Best-effort: any failure
        //    (unsupported OS, permission denied, two analyzers not allowed) degrades
        //    cleanly to mic-only — the mic is already running.
        var farActive = false
        if SystemAudioCapture.isSupported {
            let locale = primaryLocale?() ?? "en-US"
            let far = TranscriptionEngine(localeIdentifier: locale)
            do {
                await far.setContextualStrings([])
                let farSession = try await far.beginSession(segmentHandler: { segment in
                    log.add(.them, segment)
                })
                try systemAudio.start(targetFormat: farSession.format, continuation: farSession.continuation)
                farEngine = far
                farActive = true
            } catch {
                await far.cancelSession()
            }
        }
        // Stopped while the far-end was spinning up → tear everything back down.
        if cancelStart {
            systemAudio.stop()
            audio.stop()
            _ = await engine.finishSession()
            if let farEngine { _ = await farEngine.finishSession(); self.farEngine = nil }
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

    private func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        // Periodic crash-safety flush of the running transcript.
        if let turnLog, let partialURL {
            let text = MeetingTranscriptRenderer.render(turnLog.snapshot())
            try? text.data(using: .utf8)?.write(to: partialURL, options: .atomic)
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
        timer?.invalidate()
        timer = nil

        // Stop capture first so no more buffers arrive, then finalize each engine
        // (finishSession flushes the last volatile tail into the turn log).
        systemAudio.stop()
        audio.stop()
        _ = await engine.finishSession()
        if let farEngine {
            _ = await farEngine.finishSession()
        }
        farEngine = nil

        let start = startedAt ?? Date()
        let duration = Date().timeIntervalSince(start)
        let log = turnLog
        let wasFarEnd = capturingFarEnd
        startedAt = nil
        turnLog = nil
        if let partialURL { try? FileManager.default.removeItem(at: partialURL) }
        partialURL = nil

        let transcript = MeetingTranscriptRenderer.render(log?.snapshot() ?? [])
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { isFinishing = false; capturingFarEnd = false; return }

        // Participants reflect what was *captured*, not just who happened to speak,
        // so a captured-but-silent far end is still reported honestly (and stays
        // consistent with `source`).
        let participants = wasFarEnd ? ["Me", "Them"] : ["Me"]
        let summary = await summarizer.summarize(clean) ?? ""
        let meeting = Meeting(
            title: Self.makeTitle(start: start),
            startUnix: start.timeIntervalSince1970,
            durationSec: duration,
            transcript: clean,
            summary: summary,
            participants: participants,
            source: wasFarEnd ? "talkie (mic + system audio)" : "talkie (mic-only)",
            fileName: MeetingStore.fileName(for: start)
        )
        store.add(meeting)
        isFinishing = false
        capturingFarEnd = false
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
        store.add(Meeting(
            title: "Recovered meeting · " + Self.titleFormatter.string(from: date),
            startUnix: date.timeIntervalSince1970,
            durationSec: 0,
            transcript: trimmed,
            summary: "",
            participants: recoveredFarEnd ? ["Me", "Them"] : ["Me"],
            source: "talkie (recovered)",
            fileName: MeetingStore.fileName(for: date)
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
