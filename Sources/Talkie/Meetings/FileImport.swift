@preconcurrency import AVFoundation
import Foundation
import Speech

/// Turns an imported audio/video file into a normal Meeting — transcript,
/// on-device summary, graph entities, exported note — with zero network.
///
/// Two pieces:
/// - `FileImportEngine` (actor): opens the file, decodes+resamples it **incrementally**
///   (never the whole file into memory), streams the chunks through the on-device
///   recognizer, and returns a finished, timed transcript. All of the CPU-heavy decode
///   loop runs off the main actor inside the actor's isolation.
/// - `FileImportCoordinator` (`@MainActor ObservableObject`): the UI-facing orchestrator.
///   Enforces model exclusivity (no import while a dictation or recording is live —
///   imports spin up 1–4 extra analyzers and must not compete), drives one import at a
///   time, publishes progress, and on success persists the Meeting + folds it into the
///   context graph exactly the way `MeetingRecorder.stop()` does.
///
/// This is the "drop an m4a on the Meetings tab and it becomes a meeting" feature; the
/// recognition path is reused read-only (a fresh `TranscriptionEngine`, or the
/// multilingual `MultiLangStreamTranscriber`), so there is no new model behavior to gate.

// MARK: - Errors

enum FileImportError: LocalizedError, Sendable {
    case unsupportedType(String)
    case cannotOpen(String)
    case noAudioTrack(String)
    case speechUnavailable
    case emptyTranscript
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let name):
            return "Talkie can’t import “\(name)” — it isn’t an audio or video file it recognizes."
        case .cannotOpen(let name):
            return "Talkie couldn’t open “\(name)”."
        case .noAudioTrack(let name):
            return "“\(name)” has no audio track to transcribe."
        case .speechUnavailable:
            return "On-device speech recognition isn’t available on this Mac."
        case .emptyTranscript:
            return "Talkie couldn’t make out any speech in that file."
        case .cancelled:
            return "Import cancelled."
        }
    }
}

// MARK: - Supported types

/// The file kinds `FileImportEngine` accepts. Audio opens with `AVAudioFile`; video
/// (which carries an audio track) is demuxed with `AVAssetReader`. Kept as a plain
/// extension allowlist so the drop target and the open panel agree on one source of
/// truth, and an unknown drop is rejected loudly rather than silently no-op'd.
enum ImportableMedia {
    /// Container extensions that hold PCM-decodable audio directly.
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "flac", "caf", "aac"]
    /// Video containers whose audio track we demux + transcribe.
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static var allExtensions: Set<String> { audioExtensions.union(videoExtensions) }

    static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }
    static func isAudio(_ url: URL) -> Bool { audioExtensions.contains(url.pathExtension.lowercased()) }
    static func isSupported(_ url: URL) -> Bool { allExtensions.contains(url.pathExtension.lowercased()) }

    /// Filter a dropped/opened batch to just the files we can transcribe. Pure so the
    /// drop target can be unit-tested without touching the filesystem.
    static func supported(in urls: [URL]) -> [URL] { urls.filter(isSupported) }

    /// Is `url` a directory? Best-effort resource-value probe; false for a plain file or
    /// anything unreadable. Used to route a dropped folder into a shallow enumeration.
    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// The supported media files directly inside `folder` — a **shallow** walk (no
    /// recursion, per D5's out-of-scope note), skipping hidden files (dotfiles and the
    /// Finder's hidden flag), sorted by name so the batch processes in a stable, obvious
    /// order. Returns `[]` for an unreadable or empty folder rather than throwing — a
    /// folder with nothing to import is a no-op, not an error.
    static func mediaFiles(inFolderAt folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return contents
            .filter { isSupported($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Expand a dropped/picked batch into a flat, ordered list of importable files:
    /// folders are shallow-enumerated (sorted by name), loose files kept in the order
    /// given, and duplicate paths collapsed (dropping the same file twice, or a file that
    /// also lives in a dropped folder, imports it once). Pure enough to unit-test with a
    /// real temp directory; the filesystem touch is confined to reading directory listings.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        var seen: Set<String> = []
        func take(_ u: URL) {
            let key = u.standardizedFileURL.path
            if seen.insert(key).inserted { out.append(u) }
        }
        for url in urls {
            if isDirectory(url) {
                for file in mediaFiles(inFolderAt: url) { take(file) }
            } else if isSupported(url) {
                take(url)
            }
        }
        return out
    }
}

// MARK: - Result

/// The finished, `Sendable` product of one import — everything the coordinator needs
/// to construct a `Meeting` on the main actor. The transcript is already rendered and
/// trimmed; the summary is generated by the coordinator (it owns the model-exclusivity
/// window and the `MeetingSummarizer`), keeping the engine focused on decode+recognize.
struct FileImportResult: Sendable {
    /// Rendered transcript body (solo-speaker → plain text, per `MeetingTranscriptRenderer`).
    var transcript: String
    /// Audio length in seconds, measured from the source file (before resample).
    var durationSec: Double
    /// Per-segment audio-clock timings (single speaker) for the imported meeting's
    /// `Meeting.segments`. Nil when there was nothing timed to persist.
    var segments: [MeetingSegment]? = nil
}

// MARK: - Importer seam

/// The one operation the coordinator needs from an importer: turn a file into a finished
/// `FileImportResult`. Extracted as a protocol so the batch-queue logic (ordering, the
/// generation token, per-file failure collection, the duplicate guard, cancellation)
/// can be unit-tested with a fake that never touches Speech / Core Audio — the real
/// `FileImportEngine` needs the on-device model and is out of scope for pure tests.
protocol FileImporting: Sendable {
    func importFile(
        url: URL,
        primaryLocale: String,
        localeIDs: [String],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> FileImportResult
}

// MARK: - Engine

/// Decodes + transcribes one file. An `actor` so the decode loop — genuinely CPU-heavy
/// — runs off the main actor, and the non-`Sendable` `AVAudioFile`/`AVAssetReader`
/// stay confined to its isolation (never crossing an isolation boundary).
actor FileImportEngine: FileImporting {
    /// ~1 second of audio per decode step at the analyzer's sample rate, so we feed the
    /// recognizer incrementally (like live audio) instead of buffering the whole file.
    /// A frame count is derived from the actual analyzer format at decode time.
    private static let chunkSeconds: Double = 1.0

    static var isAvailable: Bool { TranscriptionEngine.isAvailable }

    /// Import `url`, streaming progress (0…1, fraction of audio fed) to `onProgress`.
    /// `localeIDs` is the user's spoken languages; when ≥2 distinct and the multilingual
    /// transcriber is available, lanes are started and the per-language vote resolves the
    /// transcript. Otherwise a single fresh `TranscriptionEngine` pinned to `primaryLocale`
    /// does the work. Throws `FileImportError.cancelled` if the surrounding Task is
    /// cancelled between chunks — leaving nothing persisted.
    func importFile(
        url: URL,
        primaryLocale: String,
        localeIDs: [String],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> FileImportResult {
        guard TranscriptionEngine.isAvailable else { throw FileImportError.speechUnavailable }
        guard ImportableMedia.isSupported(url) else {
            throw FileImportError.unsupportedType(url.lastPathComponent)
        }

        let distinct = LanguageDetector.distinctByCode(localeIDs)
        let useMulti = distinct.count > 1 && MultiLangStreamTranscriber.isAvailable

        // Try the multilingual lanes first when the user speaks several languages; if
        // the lanes can't start (models missing, analyzer cap), fall back to a single
        // fresh engine — never the shared mic engine.
        if useMulti {
            if let result = try await transcribeMultiLang(
                url: url, primaryLocale: primaryLocale, distinct: distinct, onProgress: onProgress
            ) {
                return result
            }
        }
        return try await transcribeSingle(url: url, primaryLocale: primaryLocale, onProgress: onProgress)
    }

    /// Single-locale path: a fresh `TranscriptionEngine` (never the shared mic engine),
    /// fed chunk-by-chunk as they're decoded, then finalized. The segment handler stamps
    /// each finalized segment into a `TurnLog` so the rendered transcript matches a
    /// recording's shape.
    private func transcribeSingle(
        url: URL,
        primaryLocale: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> FileImportResult {
        let engine = TranscriptionEngine(localeIdentifier: primaryLocale)
        let log = TurnLog(startedAt: Date())
        let session: (format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation)
        do {
            // Timed handler: the recognizer's audio-clock span drives both the turn's
            // time and `Meeting.segments`, so an imported file's segments are as real
            // as a live recording's (the whole file is one "Me" speaker).
            session = try await engine.beginSession(timedSegmentHandler: { seg in
                log.add(.me, seg.text, at: seg.start, end: seg.end)
            })
        } catch {
            throw FileImportError.speechUnavailable
        }

        let duration: Double
        do {
            duration = try await decodeAndFeed(url: url, target: session.format, onProgress: onProgress) { buffer in
                session.continuation.yield(AnalyzerInput(buffer: buffer))
            }
        } catch {
            session.continuation.finish()
            _ = await engine.finishSessionDetailed()
            throw error
        }

        session.continuation.finish()
        _ = await engine.finishSessionDetailed()

        let snapshot = log.snapshot()
        let transcript = MeetingTranscriptRenderer.render(snapshot)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw FileImportError.emptyTranscript }
        let segments = MeetingTranscriptRenderer.segments(from: snapshot)
        return FileImportResult(transcript: transcript, durationSec: duration, segments: segments)
    }

    /// Multilingual path: fan the decoded chunks into `MultiLangStreamTranscriber`'s
    /// continuation (identical to how `MeetingRecorder` feeds it), then resolve the
    /// per-language vote at the end. Returns nil if the lanes couldn't start (the caller
    /// then uses the single-locale path).
    private func transcribeMultiLang(
        url: URL,
        primaryLocale: String,
        distinct: [String],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> FileImportResult? {
        let multi = MultiLangStreamTranscriber()
        guard let session = try? await multi.start(localeIDs: distinct) else {
            await multi.cancel()
            return nil
        }

        let duration: Double
        do {
            duration = try await decodeAndFeed(url: url, target: session.format, onProgress: onProgress) { buffer in
                session.continuation.yield(AnalyzerInput(buffer: buffer))
            }
        } catch {
            session.continuation.finish()
            _ = await multi.finish(anchorLocale: primaryLocale)
            throw error
        }

        session.continuation.finish()
        let spans = await multi.finish(anchorLocale: primaryLocale)

        // Rebuild a turn log from the language-routed spans, one timed turn per span, so
        // mid-file language switches survive into the rendered transcript AND the
        // persisted per-segment timings.
        let log = TurnLog(startedAt: Date())
        log.replace(.me, withTimedTurns: spans.map { (elapsed: $0.start, text: $0.text, end: $0.end) })
        let snapshot = log.snapshot()
        let transcript = MeetingTranscriptRenderer.render(snapshot)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw FileImportError.emptyTranscript }
        let segments = MeetingTranscriptRenderer.segments(from: snapshot)
        return FileImportResult(transcript: transcript, durationSec: duration, segments: segments)
    }

    // MARK: Incremental decode

    /// Decode `url` to `target`'s format in ~1s chunks, handing each converted chunk to
    /// `feed`, and report progress as `framesFed / totalFrames`. Returns the source
    /// audio's duration in seconds. Dispatches to the audio-file or video-demux reader.
    /// Never materializes the whole file: exactly one chunk is resident at a time.
    private func decodeAndFeed(
        url: URL,
        target: AVAudioFormat,
        onProgress: @escaping @Sendable (Double) -> Void,
        feed: (AVAudioPCMBuffer) -> Void
    ) async throws -> Double {
        if ImportableMedia.isVideo(url) {
            return try await decodeVideo(url: url, target: target, onProgress: onProgress, feed: feed)
        }
        return try decodeAudioFile(url: url, target: target, onProgress: onProgress, feed: feed)
    }

    /// Incremental `AVAudioFile` reader: reads a fixed frame count per iteration,
    /// resamples that chunk to `target`, feeds it, and checks for cancellation between
    /// chunks. Progress is source-frames-read / total.
    private func decodeAudioFile(
        url: URL,
        target: AVAudioFormat,
        onProgress: @escaping @Sendable (Double) -> Void,
        feed: (AVAudioPCMBuffer) -> Void
    ) throws -> Double {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw FileImportError.cannotOpen(url.lastPathComponent)
        }
        let sourceFormat = file.processingFormat
        let totalFrames = file.length
        let duration = sourceFormat.sampleRate > 0 ? Double(totalFrames) / sourceFormat.sampleRate : 0
        guard totalFrames > 0 else { throw FileImportError.emptyTranscript }

        // A chunk of source frames sized to ~chunkSeconds of the SOURCE audio (the read
        // happens in the source format; `conform` handles the resample afterwards).
        let chunkFrames = AVAudioFrameCount(max(1, Int(sourceFormat.sampleRate * Self.chunkSeconds)))
        var framesRead: AVAudioFramePosition = 0

        while framesRead < totalFrames {
            try Task.checkCancellation()
            guard let chunk = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else { break }
            do {
                try file.read(into: chunk, frameCount: chunkFrames)
            } catch {
                throw FileImportError.cannotOpen(url.lastPathComponent)
            }
            let got = chunk.frameLength
            guard got > 0 else { break }
            framesRead += AVAudioFramePosition(got)

            for converted in TranscriptionEngine.conform([chunk], to: target) where converted.frameLength > 0 {
                feed(converted)
            }
            let fraction = totalFrames > 0 ? min(1, Double(framesRead) / Double(totalFrames)) : 1
            onProgress(fraction)
        }
        onProgress(1)
        return duration
    }

    /// Incremental video-audio demux with `AVAssetReader`: pulls the audio track as
    /// LinearPCM float32 sample buffers one at a time (`copyNextSampleBuffer`), converts
    /// each to a PCM buffer, resamples to `target`, and feeds it. Fails loudly when the
    /// file has no audio track (a visible, friendly error — never a silent no-op).
    private func decodeVideo(
        url: URL,
        target: AVAudioFormat,
        onProgress: @escaping @Sendable (Double) -> Void,
        feed: (AVAudioPCMBuffer) -> Void
    ) async throws -> Double {
        let asset = AVURLAsset(url: url)
        // macOS 13+ prefers the async loaders over the deprecated sync `.tracks`/`.duration`.
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard let track = tracks.first else {
            throw FileImportError.noAudioTrack(url.lastPathComponent)
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw FileImportError.cannotOpen(url.lastPathComponent)
        }

        // Ask the reader for deinterleaved float32 PCM so we can wrap each output sample
        // buffer as an AVAudioPCMBuffer and reuse the existing `conform` resampler.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FileImportError.cannotOpen(url.lastPathComponent) }
        reader.add(output)
        guard reader.startReading() else { throw FileImportError.cannotOpen(url.lastPathComponent) }

        let totalDuration = (try? await asset.load(.duration).seconds) ?? 0
        let duration = totalDuration.isFinite ? max(0, totalDuration) : 0

        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sample = output.copyNextSampleBuffer() else { break }
            guard let pcm = Self.pcmBuffer(from: sample) else { continue }
            for converted in TranscriptionEngine.conform([pcm], to: target) where converted.frameLength > 0 {
                feed(converted)
            }
            // Progress by presentation time / total duration — the reader has no frame
            // count up front, but sample timestamps map cleanly onto the known duration.
            if duration > 0 {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if pts.isFinite { onProgress(min(1, max(0, pts / duration))) }
            }
        }

        if reader.status == .failed {
            throw FileImportError.cannotOpen(url.lastPathComponent)
        }
        onProgress(1)
        return duration
    }

    /// Wrap one decoder-produced CMSampleBuffer (LinearPCM float32, non-interleaved) as
    /// an `AVAudioPCMBuffer`, copying its samples out so nothing aliases the CM block
    /// buffer after this returns. Returns nil for a sample with no usable audio.
    private static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sample),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)

        // Copy the decoded PCM into the AVAudioPCMBuffer's channel buffers via
        // CMSampleBufferCopyPCMDataIntoAudioBufferList (handles interleave/layout for us).
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }
}

// MARK: - Coordinator

/// Drives imports for the Meetings tab: a FIFO batch queue that works through dropped
/// files (and shallow-enumerated dropped folders) one at a time, off the main actor, with
/// live "N of M" progress, cancellation, and hard model-exclusivity. `@MainActor` because
/// it owns `@Published` UI state and calls the main-actor `MeetingStore`/`ContextGraphStore`.
///
/// Concurrency shape copied from `ProjectIndexStore.rescan` (VibeCoding.swift): a
/// monotonic **generation token** lets a Cancel (or a fresh batch) supersede the in-flight
/// run so a late callback can't mutate state for a batch the user already abandoned, plus a
/// **retained `runTask`** that gets `cancel()`ed so the decode/recognize loop actually stops
/// between chunks. One analyzer set at a time — sequential is a hard requirement from D1's
/// model-exclusivity notes (an import spins up 1–4 extra analyzers; two at once would
/// contend), and parallel transcription is explicitly out of scope for D5.
@MainActor
final class FileImportCoordinator: ObservableObject {
    /// One in-flight or queued import, surfaced to the progress row.
    struct Item: Identifiable, Sendable {
        let id = UUID()
        let url: URL
        var fileName: String { url.lastPathComponent }
    }

    /// The file currently being imported (nil when idle).
    @Published private(set) var active: Item?
    /// 0…1 progress of `active` (fraction of that file's audio transcribed).
    @Published private(set) var progress: Double = 0
    /// Files waiting because a dictation/recording is live, or the current file is running.
    @Published private(set) var queued: [Item] = []
    /// The most recent user-facing error (import failures are never silent).
    @Published private(set) var lastError: String?
    /// A one-shot completion summary for the finished batch ("11 imported, 1 skipped: …"),
    /// shown once at the end. Nil while a batch runs or after the user dismisses it.
    @Published private(set) var lastCompletion: String?
    /// True while an import is deferred waiting for a live dictation/recording to end.
    @Published private(set) var waitingForSession = false

    /// How many files this batch has already finished (imported OR skipped). Drives the
    /// "3 of 12" row together with `batchTotal`.
    @Published private(set) var batchDone = 0
    /// Total files in the current batch (files enqueued while a batch is already running
    /// grow this — they join the same batch).
    @Published private(set) var batchTotal = 0

    private let importer: FileImporting
    private let meetingStore: MeetingStore
    private let contextGraph: ContextGraphStore
    /// On-device summarization of a finished transcript, injected so the queue logic can be
    /// unit-tested without the Foundation Models model (which is machine-dependent and
    /// slow). Defaults to the real `MeetingSummarizer`; returns "" when the model isn't
    /// available, exactly as before.
    private let summarize: @Sendable (String) async -> String

    /// The user's spoken-language config + live-session probes, injected from AppDelegate
    /// (mirrors how `MeetingRecorder` is wired). Imports must not run while any of these
    /// report a live session — an import spins up 1–4 extra analyzers.
    private let primaryLocale: () -> String
    private let spokenLanguages: () -> [String]
    private let isDictating: () -> Bool
    private let isProcessing: () -> Bool
    private let isRecording: () -> Bool

    /// The in-flight per-file work. Retained so `cancel()` can stop the decode loop now
    /// (the generation token alone only *ignores* a stale result; the walk would keep
    /// churning), exactly like `ProjectIndexStore.scanTask`.
    private var runTask: Task<Void, Never>?
    /// Bumped on every `cancel()` (and when a drained queue resets the batch). A per-file
    /// run captures the value at its start and re-checks after each `await`; a mismatch
    /// means "this batch was cancelled/superseded — discard, don't persist, don't advance".
    private var generation = 0

    /// Names of files skipped this batch, with the reason, collected and shown once at the
    /// end rather than interrupting the run per-file (D5: per-file failures never abort the
    /// whole queue). `(fileName, reason)`.
    private var skipped: [(name: String, reason: String)] = []
    /// How many files this batch imported successfully — for the completion summary.
    private var importedCount = 0
    /// Set when the retention cap evicted an older meeting from the index during this batch
    /// (importing a big archive past `MeetingStore.maxRetainedMeetings`), so the completion
    /// message can note it once — the `.md` files survive; only the index is capped.
    private var evictionOccurred = false

    init(
        meetingStore: MeetingStore,
        contextGraph: ContextGraphStore,
        primaryLocale: @escaping () -> String,
        spokenLanguages: @escaping () -> [String],
        isDictating: @escaping () -> Bool,
        isProcessing: @escaping () -> Bool,
        isRecording: @escaping () -> Bool,
        importer: FileImporting = FileImportEngine(),
        summarize: (@Sendable (String) async -> String)? = nil
    ) {
        self.meetingStore = meetingStore
        self.contextGraph = contextGraph
        self.primaryLocale = primaryLocale
        self.spokenLanguages = spokenLanguages
        self.isDictating = isDictating
        self.isProcessing = isProcessing
        self.isRecording = isRecording
        self.importer = importer
        // Default: the real on-device summarizer (map-reduce is in-core now, so imports get
        // full summaries). A fresh actor per call matches the recorder's usage.
        self.summarize = summarize ?? { transcript in
            await MeetingSummarizer().summarize(transcript) ?? ""
        }
    }

    var isImporting: Bool { active != nil }

    /// True when a live dictation, its post-stop processing, or a meeting recording is in
    /// flight — imports defer rather than compete for the speech model / analyzers.
    private var sessionBusy: Bool { isDictating() || isProcessing() || isRecording() }

    /// Queue one or more dropped/picked entries. Folders are shallow-enumerated (sorted by
    /// name); loose files keep their order; duplicates within the drop collapse. Files
    /// added while a batch is running join that batch (its "of M" total grows). Starts the
    /// pump if idle; otherwise they wait their turn.
    func enqueue(_ urls: [URL]) {
        let items = ImportableMedia.expand(urls).map { Item(url: $0) }
        guard !items.isEmpty else { return }
        lastError = nil
        lastCompletion = nil
        // Starting fresh (nothing active/queued): reset the batch counters + collectors.
        if active == nil, queued.isEmpty {
            batchDone = 0
            batchTotal = 0
            skipped.removeAll()
            importedCount = 0
            evictionOccurred = false
        }
        queued.append(contentsOf: items)
        batchTotal += items.count
        pump()
    }

    /// Cancel the batch: supersede the in-flight run (generation bump), stop its decode
    /// loop (`runTask.cancel()`), and clear the queue. Already-completed meetings are kept;
    /// the file that was mid-transcription discards its partial work — nothing is persisted
    /// until a file's transcript is complete, so a cancelled file leaves no Meeting.
    func cancel() {
        generation += 1
        runTask?.cancel()
        runTask = nil
        queued.removeAll()
        active = nil
        progress = 0
        waitingForSession = false
        batchDone = 0
        batchTotal = 0
        skipped.removeAll()
        importedCount = 0
        evictionOccurred = false
    }

    /// Dismiss the completion summary (the user has read "11 imported, 1 skipped: …").
    func dismissCompletion() { lastCompletion = nil }

    /// Start the next queued file if nothing is running. If a session is live, mark
    /// "waiting" and retry shortly — imports never interleave with a live session (D1's
    /// exclusivity). When the queue drains, publish the batch's completion summary.
    private func pump() {
        guard runTask == nil, active == nil else { return }
        guard !queued.isEmpty else {
            finishBatchIfNeeded()
            return
        }

        if sessionBusy {
            waitingForSession = true
            // Re-check off a short delay rather than subscribing to three probes: the
            // wait is user-visible ("waiting for dictation to finish") and cheap. Tag the
            // retry with the current generation so a Cancel during the wait is a no-op.
            let generationAtWait = generation
            runTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                guard generationAtWait == self.generation else { return }
                self.runTask = nil
                self.pump()
            }
            return
        }

        waitingForSession = false
        let item = queued.removeFirst()
        active = item
        progress = 0
        let primary = primaryLocale()
        let langs = spokenLanguages()
        let generationAtStart = generation

        runTask = Task { [weak self] in
            await self?.run(item: item, primaryLocale: primary, localeIDs: langs,
                            generation: generationAtStart)
        }
    }

    /// Publish the once-at-end completion summary when a batch finished with more than one
    /// file, or with any skips — a single clean import doesn't need a banner (its Meeting
    /// simply appears). Called when the queue drains with nothing active.
    private func finishBatchIfNeeded() {
        guard batchTotal > 0 else { return }
        let total = batchTotal
        let imported = importedCount
        let skips = skipped
        // Reset the batch so a subsequent drop starts a fresh count, but keep the summary
        // string we're about to publish.
        batchDone = 0
        batchTotal = 0
        importedCount = 0
        let evicted = evictionOccurred
        skipped.removeAll()
        evictionOccurred = false

        // A lone successful file: no banner (avoid nagging for the common single import).
        if total == 1, skips.isEmpty { return }

        lastCompletion = Self.completionMessage(
            imported: imported, skipped: skips, evicted: evicted)
    }

    /// Build the human completion line: "11 imported, 1 skipped: foo.mp3", appending a
    /// one-line eviction note when the retention cap trimmed the index. Second person,
    /// honest, no invented metrics — just what happened.
    static func completionMessage(
        imported: Int,
        skipped: [(name: String, reason: String)],
        evicted: Bool
    ) -> String {
        var parts: [String] = []
        parts.append(String(format: "%d imported".loc, imported))
        if !skipped.isEmpty {
            let names = skipped.map(\.name).joined(separator: ", ")
            parts.append(String(format: "%d skipped: %@".loc, skipped.count, names))
        }
        var message = parts.joined(separator: ", ")
        if evicted {
            message += " — " + String(
                format: "your meetings list keeps the most recent %d, so older imports rolled off the list (their notes are still on disk).".loc,
                MeetingStore.maxRetainedMeetings)
        }
        return message
    }

    /// Run one file end to end, then persist + ingest on the main actor and advance the
    /// queue. On failure it records the skip and moves on (a per-file failure never aborts
    /// the batch). Every early return still advances `batchDone` + pumps (unless the batch
    /// was cancelled), so the "N of M" count and the queue never wedge.
    private func run(item: Item, primaryLocale: String, localeIDs: [String], generation: Int) async {
        var advanced = false
        // Advance the queue exactly once for this file. Cancellation (generation bump)
        // suppresses the advance so a superseded run leaves the reset state untouched.
        func advance() {
            guard !advanced else { return }
            advanced = true
            guard generation == self.generation else { return }
            batchDone += 1
            runTask = nil
            active = nil
            progress = 0
            pump()
        }
        defer { advance() }

        // Best-effort duplicate guard: skip when an existing meeting's `source` already
        // embeds this filename. D1's format is `talkie (imported: <filename>)`, which ends
        // with a paren, so we match the whole "(imported: <name>)" fragment as a substring
        // (documented best-effort — no new persistence, survives across launches via the
        // stored `source`). Same-name files from different folders collide; acceptable for
        // a guard whose only cost is a skip the user is told about.
        let dupeMarker = "(imported: \(item.fileName))"
        if meetingStore.meetings.contains(where: { $0.source.contains(dupeMarker) }) {
            skipped.append((name: item.fileName, reason: "already imported"))
            return
        }

        let result: FileImportResult
        do {
            result = try await importer.importFile(
                url: item.url,
                primaryLocale: primaryLocale,
                localeIDs: localeIDs,
                onProgress: { [weak self] fraction in
                    Task { @MainActor in self?.updateProgress(item: item, fraction: fraction) }
                }
            )
        } catch is CancellationError {
            return // cancelled → nothing persisted, advance suppressed by generation check
        } catch let error as FileImportError {
            if case .cancelled = error { return }
            // Collect the per-file failure; surface it in the batch summary, not a modal.
            skipped.append((name: item.fileName, reason: error.errorDescription ?? "failed"))
            if batchTotal <= 1 { lastError = error.errorDescription } // lone file: show inline too
            return
        } catch {
            skipped.append((name: item.fileName, reason: error.localizedDescription))
            if batchTotal <= 1 { lastError = error.localizedDescription }
            return
        }

        guard generation == self.generation, !Task.isCancelled else { return }

        // Summarize on-device via the injected summarizer (real model in production, a fake
        // in queue tests).
        let summary = await summarize(result.transcript)
        guard generation == self.generation, !Task.isCancelled else { return }

        // Build the Meeting. Title from the filename (extension stripped); startUnix
        // from the file's content-creation date, falling back to now. `segments`
        // carries the imported file's per-segment audio-clock timings (D2); the
        // segment speaker label is the internal "Me" stream tag (a solo import),
        // while `participants` stays the user-facing "Imported".
        let id = UUID()
        let start = Self.contentCreationDate(of: item.url) ?? Date()
        let fileName = MeetingStore.fileName(for: start, id: id)
        // D9 — keep the imported audio beside its note so clicking a transcript
        // segment can play that exact moment. Copy (never re-encode) the ORIGINAL
        // file next to the `.md`, sharing its basename so the pair reads as one unit
        // in ~/Talkie Meetings/ (the visible, files-you-own folder — never Application
        // Support). Copying is a free win: no toggle, no privacy decision, because the
        // source file already exists on disk and the user chose to import it. A failed
        // copy (disk full, unreadable source) is non-fatal — the meeting is still
        // created, just without playback (`audioFiles` stays nil).
        let audioFiles = Self.copyImportedAudio(from: item.url, noteFileName: fileName)
        let meeting = Meeting(
            id: id,
            title: item.url.deletingPathExtension().lastPathComponent,
            startUnix: start.timeIntervalSince1970,
            durationSec: result.durationSec,
            transcript: result.transcript,
            summary: summary,
            participants: ["Imported"],
            source: "talkie (imported: \(item.url.lastPathComponent))",
            fileName: fileName,
            segments: result.segments,
            audioFiles: audioFiles
        )
        let countBefore = meetingStore.meetings.count
        meetingStore.add(meeting)
        importedCount += 1
        // The store caps the index at maxRetainedMeetings; if adding didn't grow the count,
        // an older meeting was evicted from the index (its .md survives) — note it once.
        if meetingStore.meetings.count <= countBefore { evictionOccurred = true }

        // Graph ingest exactly like MeetingRecorder.stop: candidates from the transcript,
        // tagged with meeting provenance, so imported meetings show up in recall/search.
        let provenance = Provenance(source: .meeting, sourceID: id.uuidString,
                                    dateUnix: start.timeIntervalSince1970, snippet: nil)
        contextGraph.ingest(ContextGraphExtractor.candidates(from: result.transcript), provenance: provenance)
    }

    private func updateProgress(item: Item, fraction: Double) {
        guard active?.id == item.id else { return }
        progress = min(1, max(0, fraction))
    }

    /// The file's content-creation date (when the audio was recorded, if the container
    /// carries it), falling back to nil so the caller uses "now". Read via URL resource
    /// values — no network, no extra frameworks.
    private static func contentCreationDate(of url: URL) -> Date? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return values.creationDate ?? values.contentModificationDate
    }

    /// Copy `source` into ~/Talkie Meetings/ under the note's basename + the source's
    /// own extension (`2026-07-03-…-meeting.mp3`), returning the `["Imported": name]`
    /// map for `Meeting.audioFiles`, or nil when the copy can't be made (so the meeting
    /// is still created, just without playback). A plain byte copy — the original codec
    /// is preserved, no re-encode — because it's the *source of truth* the user is
    /// verifying quotes against. `contentBasename` from the note keeps the audio and
    /// note filenames aligned even when the source's own name is arbitrary. If a file
    /// with that exact name somehow already exists (a re-import into the same second),
    /// it's removed first so `copyItem` can't throw on a stale collision.
    private static func copyImportedAudio(from source: URL, noteFileName: String) -> [String: String]? {
        let ext = source.pathExtension
        guard !ext.isEmpty else { return nil }
        let stem = (noteFileName as NSString).deletingPathExtension
        guard !stem.isEmpty else { return nil }
        let destName = "\(stem).\(ext)"
        let dest = AppPaths.meetingsDirectory().appendingPathComponent(destName)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        do {
            try fm.copyItem(at: source, to: dest)
        } catch {
            return nil
        }
        return ["Imported": destName]
    }
}
