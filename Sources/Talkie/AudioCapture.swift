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

/// Captures the default microphone via `AVAudioEngine`, converts each buffer to
/// the format `SpeechAnalyzer` requested, and yields it into the analyzer's
/// input stream. Marked `@unchecked Sendable` because the tap block and the
/// converter are only ever touched on the single real-time audio thread.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning = false

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
    func start(
        targetFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        guard !isRunning else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        converter?.primeMethod = .none // avoid timestamp drift on streamed buffers
        self.converter = converter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            guard let converted = Self.convert(buffer: buffer, using: converter, to: targetFormat) else { return }
            if converted.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
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
