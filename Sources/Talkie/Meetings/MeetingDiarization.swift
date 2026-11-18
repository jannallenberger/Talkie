@preconcurrency import AVFoundation
import Foundation
import TalkieDiarization

// Post-stop speaker diarization for meetings: the per-lane 16 kHz tee, the
// time-boxed pass, and applying the result to a saved Meeting. Labelling decisions
// live in the pure `SpeakerLabelling`; everything here is plumbing around it.

// MARK: - Tee

/// Records one lane's converted PCM to a temp 16 kHz mono WAV for diarization.
///
/// It hangs off the capture classes' `onBuffer` hook, which fires on the realtime
/// capture thread, so `append` only bounces the buffer onto a private serial queue
/// and returns — like `MeetingAudioFileWriter`, whose pattern (fresh buffer per
/// convert, queue-confined state, `closed` latch) it copies. Resampling and file I/O
/// happen on that queue. Not RAM-resident: samples go straight to disk (16-bit PCM,
/// ~115 MB per hour).
///
/// TIME BASE. The lane's segment times are the recognizer's audio clock = cumulative
/// frames of the very buffers handed to the analyzer, divided by their sample rate
/// (the single-locale `SpeechAnalyzer` clock, and `MultiLangStreamTranscriber`'s
/// `audioSecondsFed` including its rotation offsets, are both exactly that). The
/// capture classes call `onBuffer(converted)` and then yield the SAME `converted`
/// buffer to the analyzer, so this tee sees the identical buffer sequence. It writes
/// every frame in order with no gaps, padding or trimming; a source that is not
/// already 16 kHz mono is resampled with a streaming `AVAudioConverter`
/// (`primeMethod = .none`, no priming delay), so file time t == analyzer time t to
/// within resampler rounding. Frame 0 of the file is the lane's first buffer, which is
/// also the analyzer's time 0. A capture gap (device change, tap rebuild) delivers no
/// buffers to either consumer, so both clocks skip it identically.
final class MeetingDiarizationTee: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    let url: URL
    private let queue = DispatchQueue(label: "com.coralate.talkie.meeting-diarization-tee")
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var failed = false
    private var closed = false
    private var sourceFrames: Int64 = 0
    private var writtenFrames: Int64 = 0

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    init(url: URL) { self.url = url }

    /// Hand one converted buffer over. Returns immediately (RT-safe: one closure
    /// allocation, no locks, no I/O).
    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard !failed, !closed, buffer.frameLength > 0 else { return }
            do { try write(buffer) } catch { failed = true }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        if file == nil {
            file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ],
                commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        let target = Self.targetFormat
        sourceFrames += Int64(buffer.frameLength)
        if Self.isTarget(buffer.format) {
            try file?.write(from: buffer)
            writtenFrames += Int64(buffer.frameLength)
            return
        }
        if converter == nil || sourceFormat != buffer.format {
            guard let c = AVAudioConverter(from: buffer.format, to: target) else { throw TeeError.noConverter }
            c.primeMethod = .none // no priming delay: keeps file time == analyzer time
            converter = c
            sourceFormat = buffer.format
        }
        guard let converter else { throw TeeError.noConverter }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw TeeError.noConverter }
        let source = OneShotBuffer(buffer)
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, inputStatus in
            if let next = source.take() {
                inputStatus.pointee = .haveData
                return next
            }
            inputStatus.pointee = .noDataNow
            return nil
        }
        if status == .error { throw convError ?? TeeError.noConverter }
        if out.frameLength > 0 {
            try file?.write(from: out)
            writtenFrames += Int64(out.frameLength)
        }
    }

    private static func isTarget(_ f: AVAudioFormat) -> Bool {
        f.sampleRate == sampleRate && f.channelCount == 1
            && f.commonFormat == .pcmFormatFloat32 && !f.isInterleaved
    }

    enum TeeError: Error { case noConverter }

    /// Hands the converter its one input buffer exactly once (the converter's input
    /// block is `@Sendable`; this keeps the mutation out of a captured `var`).
    private final class OneShotBuffer: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ b: AVAudioPCMBuffer) { buffer = b }
        func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
    }

    struct Summary: Sendable, Equatable {
        let url: URL
        /// Frames of the source buffers received / 16 kHz frames written.
        let sourceFrames: Int64
        let writtenFrames: Int64
        var seconds: Double { Double(writtenFrames) / MeetingDiarizationTee.sampleRate }
    }

    /// Flush and close; blocks only the caller. Idempotent. Returns the file's summary
    /// if a usable (non-empty, un-failed) file exists, else nil (and removes any stub).
    @discardableResult
    func close() -> Summary? {
        let state: (ok: Bool, source: Int64, written: Int64) = queue.sync {
            file = nil // releasing the AVAudioFile finalizes the WAV header
            closed = true
            return (!failed && writtenFrames > 0, sourceFrames, writtenFrames)
        }
        guard state.ok else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Summary(url: url, sourceFrames: state.source, writtenFrames: state.written)
    }
}

// MARK: - Temp files

enum MeetingDiarizationTemp {
    static func url(meetingID: UUID, lane: String, in dir: URL = AppPaths.diarizationTempDirectory()) -> URL {
        dir.appendingPathComponent("\(meetingID.uuidString)-\(lane == SpeakerLabels.me ? "mic" : "sys").wav")
    }

    static func remove(_ urls: [URL]) {
        for u in urls { try? FileManager.default.removeItem(at: u) }
    }

    /// Delete every file in the temp folder — what a crashed run left behind. Called
    /// once at launch, before any recording or pass can exist.
    @discardableResult
    static func sweepStale(in dir: URL = AppPaths.diarizationTempDirectory()) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var n = 0
        for name in names where (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil { n += 1 }
        return n
    }
}

// MARK: - Time box

/// Races `operation` against a timer WITHOUT waiting for it to finish: on timeout it
/// returns nil immediately and abandons the (cancelled, detached) operation. Needed
/// because a CoreML prediction ignores cooperative cancellation, and a structured
/// task group (see `withAsyncTimeout`) would block on it forever — the "stuck
/// forever" class of bug. The abandoned work runs to completion in the background and
/// its result is discarded.
enum TimeBox {
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var timer: Task<Void, Never>?
        init(_ c: CheckedContinuation<T?, Never>) { continuation = c }
        func setTimer(_ t: Task<Void, Never>) {
            lock.lock(); defer { lock.unlock() }
            if continuation == nil { t.cancel() } else { timer = t }
        }
        @discardableResult
        func finish(_ value: T?) -> Bool {
            lock.lock()
            let c = continuation
            continuation = nil
            let t = timer
            lock.unlock()
            guard let c else { return false }
            t?.cancel()
            c.resume(returning: value)
            return true
        }
    }

    static func run<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let gate = Gate<T>(cont)
            let work = Task.detached { gate.finish(await operation()) }
            gate.setTimer(Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if gate.finish(nil) { work.cancel() }
            })
        }
    }
}

// MARK: - Pipeline

/// Anything that can diarize a 16 kHz mono file (the real `SpeakerDiarizer`, or a
/// test fake).
protocol LaneDiarizing: Sendable {
    func diarize(fileURL: URL) async throws -> DiarizationOutput
}
extension SpeakerDiarizer: LaneDiarizing {}

enum MeetingDiarizationPipeline {
    struct LaneInput: Sendable {
        /// "Me" (mic) or "Them" (system audio).
        let lane: String
        let fileURL: URL
    }

    enum Outcome: Sendable {
        case labelled(SpeakerLabelling.Result)
        /// Nothing to diarize (no timed segments / no lane speech).
        case unavailable
        case timedOut
        case failed(String)
    }

    /// Time allowed for the whole pass (both lanes + model load). Real speed is
    /// ~0.025x real time (a 1 h lane ≈ 90 s) so 0.2 s per audio second plus a 60 s
    /// floor for first-run CoreML compilation is ~8x headroom; capped at 15 minutes.
    static func budget(audioSeconds: Double) -> Double {
        min(900, max(60, 60 + 0.2 * max(0, audioSeconds)))
    }

    static func run(
        inputs: [LaneInput],
        segments: [MeetingSegment],
        diarizer: any LaneDiarizing,
        budgetSeconds: Double,
        bleedThreshold: Double = SpeakerLabelling.defaultBleedThreshold,
        resolveMe: OwnVoiceResolver = SpeakerLabelling.noOwnVoice
    ) async -> Outcome {
        let lanesWithSpeech = Set(segments.map(\.speaker)).intersection([SpeakerLabels.me, SpeakerLabels.them])
        guard !lanesWithSpeech.isEmpty else { return .unavailable }
        // Both lanes are always analysed. If a lane has speech but no audio, labelling
        // half the meeting would mislabel it — keep Me/Them instead.
        let byLane = Dictionary(inputs.map { ($0.lane, $0.fileURL) }, uniquingKeysWith: { a, _ in a })
        guard lanesWithSpeech.allSatisfy({ byLane[$0] != nil }) else { return .failed("lane audio missing") }

        let work = lanesWithSpeech.sorted().map { (lane: $0, url: byLane[$0]!) }
        let raw = await TimeBox.run(seconds: budgetSeconds) { () -> Swift.Result<[String: DiarizationOutput], DiarizationFailure> in
            var outputs: [String: DiarizationOutput] = [:]
            for item in work {
                do { outputs[item.lane] = try await diarizer.diarize(fileURL: item.url) }
                catch { return .failure(DiarizationFailure(String(describing: error))) }
                if Task.isCancelled { return .failure(DiarizationFailure("cancelled")) }
            }
            return .success(outputs)
        }
        switch raw {
        case .none: return .timedOut
        case .some(.failure(let f)): return .failed(f.message)
        case .some(.success(let outputs)):
            return .labelled(SpeakerLabelling.label(
                segments: segments,
                mic: outputs[SpeakerLabels.me], system: outputs[SpeakerLabels.them],
                bleedThreshold: bleedThreshold, resolveMe: resolveMe))
        }
    }

    struct DiarizationFailure: Error, Sendable { let message: String; init(_ m: String) { message = m } }

    /// Fold a labelling result into a meeting: rewritten segments, re-rendered
    /// transcript and participants (the .md note and exports derive from these), plus
    /// the persisted metadata. A legacy-outcome result (`changed == false`) records
    /// metadata only; labels, transcript and participants stay byte-identical.
    static func apply(_ result: SpeakerLabelling.Result, to meeting: Meeting) -> Meeting {
        var m = meeting
        m.speakerCount = result.speakerCount
        guard result.changed else {
            m.diarizationState = DiarizationState.unchanged.rawValue
            return m
        }
        m.segments = result.segments
        m.transcript = MeetingTranscriptRenderer.render(segments: result.segments)
        m.participants = result.participants
        m.diarizationState = DiarizationState.applied.rawValue
        return m
    }
}
