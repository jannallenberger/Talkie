@preconcurrency import AVFoundation
import Foundation

/// File import transcribes a long recording as a series of independent recognizer
/// SESSIONS, one per window of audio (`windowSeconds`), instead of one session for the
/// whole file.
///
/// Why: the live recognition paths are tuned for audio that arrives in real time. Import
/// decodes ~100x faster than real time, so by the time the last chunk is fed the
/// recognizer is minutes behind, and the live paths' bounded finalize (4 s single-locale,
/// 10 s per lane) hard-cancels it, discarding everything not yet finalized. A 2 h file
/// came back as its first ~34 minutes. A single analyzer over one long stream can also
/// stop promoting results (~30 min in). Windowing fixes both: each window's backlog is
/// small, is finished with a generous bound (`finalizeTimeout`) rather than cancelled, and
/// no analyzer lives long enough to stall. Window offsets are exact (frames fed / sample
/// rate, the same clock the diarization tee uses), so segment times stay on one timeline.

/// One recognized span with its audio-clock range and (optionally) word timings.
struct ImportChunk: Sendable, Equatable {
    var text: String
    var start: Double
    var end: Double
    var words: [SegmentWord]?

    func shifted(by offset: Double) -> ImportChunk {
        ImportChunk(text: text, start: start + offset, end: end + offset,
                    words: words?.map { SegmentWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) })
    }
}

/// One recognizer session over one window: audio goes in through `feed`; `finish` closes
/// the input, finalizes (bounded) and returns the window's chunks on the WINDOW's clock
/// (0 = the window's first sample).
struct ImportSession {
    var feed: (AVAudioPCMBuffer) -> Void
    var finish: () async -> [ImportChunk]
}

enum ImportWindowing {
    /// Audio per recognizer session. Small enough that the finalize backlog is bounded
    /// (and memory with it), large enough that a window cut rarely lands mid-sentence.
    static let windowSeconds: Double = 600
    /// Longest a window's finalize + drain may take before it is hard-cancelled. A healthy
    /// window needs seconds to a couple of minutes (it is a backlog of `windowSeconds`
    /// of audio); this only bounds Apple's finalize silently never returning.
    static let finalizeTimeout: Double = 900
}

/// Feeds consecutive buffers through consecutive `ImportSession`s, rolling to a fresh one
/// every `windowSeconds` of audio. `first` is the already-open window-0 session; `open`
/// makes each later one, lazily (on the first buffer of the window), so a boundary that
/// lands exactly at end of file never opens, and then has to finalize, a session that got
/// no audio. Confined to the caller's isolation (the import actor): every method runs on
/// it, so the non-Sendable buffers and closures never cross an isolation boundary.
final class ImportWindower {
    private let windowFrames: Int
    private let sampleRate: Double
    private let open: () async throws -> ImportSession
    private var session: ImportSession?
    private var framesInWindow = 0
    private var offset = 0.0
    private(set) var chunks: [ImportChunk] = []

    init(sampleRate: Double, windowSeconds: Double = ImportWindowing.windowSeconds,
         first: ImportSession, open: @escaping () async throws -> ImportSession) {
        self.sampleRate = max(1, sampleRate)
        self.windowFrames = max(1, Int(windowSeconds * max(1, sampleRate)))
        self.session = first
        self.open = open
    }

    func feed(_ buffer: AVAudioPCMBuffer, isolation: isolated (any Actor)? = #isolation) async throws {
        if session == nil { session = try await open() }
        session?.feed(buffer)
        framesInWindow += Int(buffer.frameLength)
        guard framesInWindow >= windowFrames, let full = session else { return }
        session = nil
        chunks += await full.finish().map { $0.shifted(by: offset) }
        offset += Double(framesInWindow) / sampleRate
        framesInWindow = 0
    }

    /// Close the open window (if any) and return every chunk on the file's clock.
    func finish(isolation: isolated (any Actor)? = #isolation) async -> [ImportChunk] {
        if let open = session {
            session = nil
            chunks += await open.finish().map { $0.shifted(by: offset) }
        }
        return chunks
    }

    /// Close the open window and drop its output (decode failed or was cancelled).
    func abort(isolation: isolated (any Actor)? = #isolation) async {
        if let open = session { session = nil; _ = await open.finish() }
    }
}
