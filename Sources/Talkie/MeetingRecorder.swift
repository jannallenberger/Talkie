import AVFoundation
import Foundation

/// Records a mic-only meeting: streams finalized transcript segments (reusing the
/// shared transcription engine), flushes them to a `.partial` file for crash
/// safety, and on stop assembles the transcript, generates an on-device summary,
/// and saves a markdown meeting note.
@MainActor
final class MeetingRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var elapsed: TimeInterval = 0

    /// Probe for whether a dictation session is live (the engine is shared, so
    /// the two can't run at once). Injected by AppDelegate.
    var isDictating: (() -> Bool)?

    private let engine: TranscriptionEngine
    private let store: MeetingStore
    private let summarizer = MeetingSummarizer()
    private let audio = AudioCapture()

    private var buffer: DictationAssembler?
    private var startedAt: Date?
    private var partialURL: URL?
    private var timer: Timer?

    init(engine: TranscriptionEngine, store: MeetingStore) {
        self.engine = engine
        self.store = store
    }

    /// Start recording. Returns false if the mic is denied, speech is unavailable,
    /// or a session is already in progress.
    @discardableResult
    func start() async -> Bool {
        guard !isRecording, !isFinishing, TranscriptionEngine.isAvailable else { return false }
        // Reverse exclusivity: never start over a live dictation (shared engine).
        guard isDictating?() != true else { return false }
        guard await AudioCapture.requestMicrophoneAccess() else { return false }

        let buffer = DictationAssembler(clean: { _ in nil }) // raw transcript, no per-segment LLM
        let start = Date()
        let pURL = AppPaths.meetingsDirectory().appendingPathComponent(".recording.partial.txt")
        try? Data().write(to: pURL)

        do {
            await engine.setContextualStrings([])
            let session = try await engine.beginSession(segmentHandler: { segment in buffer.add(segment) })
            try audio.start(targetFormat: session.format, continuation: session.continuation)
        } catch {
            await engine.cancelSession()
            try? FileManager.default.removeItem(at: pURL)
            return false
        }

        self.buffer = buffer
        self.startedAt = start
        self.partialURL = pURL
        self.elapsed = 0
        self.isRecording = true
        self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return true
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        // Periodic crash-safety flush of the running transcript.
        if let buffer, let partialURL {
            try? buffer.raw().data(using: .utf8)?.write(to: partialURL, options: .atomic)
        }
    }

    /// Stop, transcribe-finalize, summarize, and save the meeting note.
    func stop() async {
        guard isRecording else { return }
        isRecording = false
        isFinishing = true
        timer?.invalidate()
        timer = nil
        audio.stop()

        let transcript = await engine.finishSession() // also clears the segment handler

        let start = startedAt ?? Date()
        let duration = Date().timeIntervalSince(start)
        startedAt = nil
        buffer = nil
        if let partialURL { try? FileManager.default.removeItem(at: partialURL) }
        partialURL = nil

        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { isFinishing = false; return }

        let summary = await summarizer.summarize(clean) ?? ""
        let meeting = Meeting(
            title: Self.makeTitle(start: start),
            startUnix: start.timeIntervalSince1970,
            durationSec: duration,
            transcript: clean,
            summary: summary,
            fileName: MeetingStore.fileName(for: start)
        )
        store.add(meeting)
        isFinishing = false
    }

    /// On launch, recover a transcript left behind by a crash mid-recording into
    /// a Meeting (no summary). Must run before any new recording overwrites the file.
    func recoverPartialIfNeeded() {
        let pURL = AppPaths.meetingsDirectory().appendingPathComponent(".recording.partial.txt")
        guard let raw = try? String(contentsOf: pURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: pURL)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let date = Date()
        store.add(Meeting(
            title: "Recovered meeting · " + Self.titleFormatter.string(from: date),
            startUnix: date.timeIntervalSince1970,
            durationSec: 0,
            transcript: trimmed,
            summary: "",
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
