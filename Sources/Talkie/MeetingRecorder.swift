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
        guard !isRecording, TranscriptionEngine.isAvailable else { return false }
        guard await AudioCapture.requestMicrophoneAccess() else { return false }

        let buffer = DictationAssembler(clean: { _ in nil }) // raw transcript, no per-segment LLM
        let start = Date()
        let pURL = AppPaths.meetingsDirectory().appendingPathComponent(".recording.partial.txt")
        try? Data().write(to: pURL)

        do {
            await engine.setSegmentHandler { segment in buffer.add(segment) }
            await engine.setContextualStrings([])
            let session = try await engine.beginSession()
            try audio.start(targetFormat: session.format, continuation: session.continuation)
        } catch {
            await engine.cancelSession()
            await engine.setSegmentHandler(nil)
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

        let transcript = await engine.finishSession()
        await engine.setSegmentHandler(nil)

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

    private static func makeTitle(start: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Meeting · \(f.string(from: start))"
    }
}
