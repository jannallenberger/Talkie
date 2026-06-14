@preconcurrency import AVFoundation
import Foundation
import Speech

/// Hands a single buffer to `AVAudioConverter` exactly once. Reference type so
/// the converter's input block doesn't capture mutable locals (Swift 6 clean).
private final class SingleShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Thread-safe accumulator of converted PCM buffers, capped by total frames, so
/// a session can be re-transcribed in a different language. Appended on the
/// real-time tap thread, drained on the main thread.
private final class CapturedAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var totalFrames: AVAudioFramePosition = 0
    private let maxFrames: AVAudioFramePosition

    init(maxFrames: AVAudioFramePosition) { self.maxFrames = maxFrames }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        buffers.append(buffer)
        totalFrames += AVAudioFramePosition(buffer.frameLength)
        // Drop-oldest rolling window: always keep the most-recent `maxFrames`
        // (better than freezing at cap — a long capture keeps recent speech).
        while totalFrames > maxFrames, let first = buffers.first {
            totalFrames -= AVAudioFramePosition(first.frameLength)
            buffers.removeFirst()
        }
    }

    func drain() -> [AVAudioPCMBuffer] {
        lock.lock(); defer { lock.unlock() }
        let out = buffers
        buffers = []
        totalFrames = 0
        return out
    }
}

/// Captures the default microphone via `AVAudioEngine`, converts each buffer to
/// the format `SpeechAnalyzer` requested, and yields it into the analyzer's
/// input stream. The converter is captured by value inside the tap block (never
/// read from a mutable property on the render thread), so start/stop on the main
/// thread can't race the real-time callback.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var isRunning = false // touched only on the main thread (start/stop)
    private var captured: CapturedAudio?

    /// Ask for microphone access. Returns true if granted.
    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Begin tapping the mic, pushing converted buffers into `continuation`.
    /// `onLevel` is called ~12×/sec with a normalized 0…1 mic level for the HUD
    /// waveform. Both `onLevel` and `converter` are captured by value so the
    /// render thread never reads a property the main thread mutates.
    func start(
        targetFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        bufferAudio: Bool = false,
        bufferSeconds: Double = 90,
        onLevel: (@Sendable (Float) -> Void)? = nil
    ) throws {
        guard !isRunning else { return }

        let inputNode = engine.inputNode
        engine.prepare() // resolve the input device/format before we read it

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw TalkieEngineError.noCompatibleAudioFormat
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw TalkieEngineError.noCompatibleAudioFormat
        }
        converter.primeMethod = .none // avoid timestamp drift on streamed buffers

        // Retain a rolling window of converted audio when language auto-detect is on
        // (dictation: ~90 s; meetings pass a larger window).
        let capture = bufferAudio
            ? CapturedAudio(maxFrames: AVAudioFramePosition(targetFormat.sampleRate * bufferSeconds))
            : nil
        self.captured = capture

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            if let onLevel {
                onLevel(Self.level(of: buffer))
            }
            guard let converted = Self.convert(buffer: buffer, using: converter, to: targetFormat) else { return }
            if converted.frameLength > 0 {
                capture?.append(converted)
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }

        try engine.start()
        isRunning = true
    }

    /// The converted audio captured during the last session (for re-transcription).
    func bufferedAudio() -> [AVAudioPCMBuffer] {
        captured?.drain() ?? []
    }

    /// Perceptual 0…1 level (dB-mapped RMS) of a mic buffer, for the HUD waveform.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let samples = channels[0]
        var sumSquares: Float = 0
        for i in 0..<frames {
            let s = samples[i]
            sumSquares += s * s
        }
        let rms = (sumSquares / Float(frames)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7)) // ~ -140…0
        return max(0, min(1, (db + 55) / 55)) // -55 dB → 0, 0 dB → 1
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Convert one PCM buffer from the hardware format to the analyzer format.
    private static func convert(
        buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        let source = SingleShotInput(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, statusPtr in
            if let next = source.take() {
                statusPtr.pointee = .haveData
                return next
            }
            statusPtr.pointee = .noDataNow
            return nil
        }

        if status == .error || error != nil {
            return nil
        }
        return output
    }
}
