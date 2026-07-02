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

    /// Monotonic host time (`DispatchTime` uptime nanoseconds) of the most recent
    /// buffer the mic tap delivered, or 0 if none since the last `start()`. Written on
    /// the realtime tap thread, read on the main thread, so every access is guarded by
    /// `bufferClockLock` — the documented lock discipline for this `@unchecked Sendable`
    /// (the class already relies on `CapturedAudio`'s own lock for its buffer ring; this
    /// covers the one scalar the render thread and main thread both touch).
    ///
    /// This is the far-end watchdog's *mic-alive* cross-check (C6 / plan 01 §4.2a): a
    /// dead system-audio tap is distinguished from a genuinely quiet call by asking
    /// whether the mic is still producing buffers. We stamp on *every* mic buffer
    /// (not just non-silent ones): the question is "is the recording pipeline alive",
    /// not "is the user speaking" — a silent-but-live mic still proves the app runs.
    private let bufferClockLock = NSLock()
    private var lastBufferHostTime: UInt64 = 0

    /// Observer for `.AVAudioEngineConfigurationChange`, registered in `start()` and
    /// removed in `stop()`. Cleared symmetrically with `isRunning` so a stopped
    /// capture never reacts to a stray config change.
    private var configObserver: NSObjectProtocol?
    /// Re-entrancy guard so a config-change storm (e.g. AirPods bouncing) can't stack
    /// taps or recurse — a change that arrives while we're mid-rebuild is ignored.
    private var isHandlingConfigChange = false

    /// The session parameters retained across a hot device swap, so
    /// `handleConfigurationChange()` can reinstall the tap and restart the engine
    /// without the caller re-driving `start()`. Set in `start()`, cleared in `stop()`.
    private var targetFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var preferredDeviceUID: String?
    /// UID of the device the tap is currently bound to, so a config change can ask
    /// `AudioDevices.resolveSwap` whether the active device actually changed.
    private var currentDeviceUID: String?
    private var onLevel: (@Sendable (Float) -> Void)?
    /// Surfaces a recoverable capture failure (e.g. the active mic vanished mid-session
    /// and none remains) to the caller, which routes it to its error/HUD path. Called
    /// on the main thread from `handleConfigurationChange()`.
    private var onCaptureFailed: (@Sendable (Error) -> Void)?

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
        preferredDeviceUID: String? = nil,
        bufferAudio: Bool = false,
        bufferSeconds: Double = 90,
        onLevel: (@Sendable (Float) -> Void)? = nil,
        onCaptureFailed: (@Sendable (Error) -> Void)? = nil
    ) throws {
        guard !isRunning else { return }

        // Retain a rolling window of converted audio when language auto-detect is on
        // (dictation: ~90 s; meetings pass a larger window). Built once here and
        // *kept* across a hot device swap so the re-transcription window isn't lost.
        let capture = bufferAudio
            ? CapturedAudio(maxFrames: AVAudioFramePosition(targetFormat.sampleRate * bufferSeconds))
            : nil
        self.captured = capture

        // Stash the session parameters so a mid-session device/config change can
        // rebuild the tap without the caller re-driving start().
        self.targetFormat = targetFormat
        self.continuation = continuation
        self.preferredDeviceUID = preferredDeviceUID
        self.onLevel = onLevel
        self.onCaptureFailed = onCaptureFailed

        // Fresh session: clear any stale mic-alive stamp from a prior recording so the
        // watchdog doesn't read a live mic before the first new buffer actually lands.
        bufferClockLock.lock()
        lastBufferHostTime = 0
        bufferClockLock.unlock()

        try installAndStart()

        // Watch for mid-session device/config changes. When the active input device
        // changes (unplug a headset, AirPods connect, default flips), AVAudioEngine
        // posts this notification, internally stops, and the tap stops firing — but
        // `isRunning` stays true and no error surfaces, so capture would silently go
        // dead. `queue: .main` delivers the handler on the main thread; we re-assert
        // that isolation to touch our @MainActor-confined state safely.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }

        isRunning = true
    }

    /// Install the tap and start the engine using the retained session parameters.
    /// Shared by `start()` and `handleConfigurationChange()` so the device-resolve →
    /// format-read → converter-build → tap-install → engine-start sequence lives in
    /// one place. Pins a *real* microphone instead of trusting the system default,
    /// which can be a 0-channel device (e.g. a Bluetooth speaker that's output-only)
    /// and would make the engine fail to start.
    private func installAndStart() throws {
        guard let targetFormat, let continuation else {
            throw TalkieEngineError.noCompatibleAudioFormat
        }

        let inputNode = engine.inputNode

        // Pin to a real input device. Must happen before `prepare()` reads the
        // device format. If the Mac has no input device at all, surface that
        // explicitly rather than failing with a format error.
        guard let device = AudioDevices.resolveInput(preferredUID: preferredDeviceUID) else {
            throw TalkieEngineError.noInputDevice
        }
        do {
            try inputNode.auAudioUnit.setDeviceID(device.id)
        } catch {
            // Couldn't bind the chosen device — fall back to the engine default and
            // let the format guard below decide whether it's usable.
            talkieDebugLog("AudioCapture: setDeviceID(\(device.name)) failed: \(error)")
        }
        currentDeviceUID = device.uid

        engine.prepare() // resolve the input device/format before we read it

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw TalkieEngineError.noCompatibleAudioFormat
        }
        // The device may have changed, so the input format may differ from the last
        // session — rebuild the converter against the freshly read format.
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw TalkieEngineError.noCompatibleAudioFormat
        }
        converter.primeMethod = .none // avoid timestamp drift on streamed buffers

        let capture = self.captured
        let onLevel = self.onLevel
        // Captured by value (a reference type, safe across the RT boundary) so the
        // render thread stamps mic-liveness without touching `self`.
        let clockLock = self.bufferClockLock
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // Mic-alive stamp for the far-end watchdog: record that a buffer arrived,
            // regardless of level. Guarded write; cheap enough for the RT thread.
            let host = DispatchTime.now().uptimeNanoseconds
            clockLock.lock()
            self?.lastBufferHostTime = host
            clockLock.unlock()
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
    }

    /// Recover capture after a mid-session input-device/config change. Always on the
    /// main thread (the observer uses `queue: .main`). Removes the now-dead tap,
    /// re-resolves the input device, rebuilds the converter against the (possibly
    /// changed) format, reinstalls the tap, and restarts the engine. The rolling
    /// `CapturedAudio` buffer is deliberately *kept* so the re-transcription window
    /// survives the hot swap. On failure (e.g. the only mic vanished) it surfaces a
    /// recoverable error via `onCaptureFailed` instead of dying silently.
    func handleConfigurationChange() {
        guard isRunning else { return }
        // Re-entrancy guard: a config-change storm (AirPods bouncing) can post several
        // notifications in quick succession; ignore any that arrive while we rebuild.
        guard !isHandlingConfigChange else { return }
        isHandlingConfigChange = true
        defer { isHandlingConfigChange = false }

        // Decide what the change means for the active device. `.noDevice` means the
        // Mac lost every mic — surface it directly instead of churning the engine.
        // `.keep`/`.swap` both still need a tap rebuild (even an unchanged device can
        // change format, e.g. sample-rate), so they fall through to installAndStart().
        let decision = AudioDevices.resolveSwap(
            preferred: preferredDeviceUID,
            devices: AudioDevices.inputDevices(),
            currentUID: currentDeviceUID,
            defaultID: AudioDevices.defaultInputDeviceID()
        )

        // The engine internally stopped on the config change; remove the stale tap
        // before reinstalling so taps can't stack.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        if case .noDevice = decision {
            isRunning = false
            removeConfigObserver()
            onCaptureFailed?(TalkieEngineError.noInputDevice)
            return
        }

        do {
            try installAndStart()
        } catch {
            // No usable mic (or no compatible format) after the change. Tear the
            // capture down and surface a recoverable error rather than leaving a
            // half-dead engine that reports nothing.
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
            removeConfigObserver()
            onCaptureFailed?(error)
        }
    }

    private func removeConfigObserver() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
    }

    /// The converted audio captured during the last session (for re-transcription).
    func bufferedAudio() -> [AVAudioPCMBuffer] {
        captured?.drain() ?? []
    }

    /// Seconds since the mic tap last delivered a buffer, on the caller's monotonic
    /// clock (`DispatchTime` uptime seconds), or `nil` if no buffer has arrived since
    /// the last `start()`. The far-end watchdog's mic-alive probe: a fresh timestamp
    /// means the recording pipeline is live, so far-end silence implies a dead tap
    /// rather than a quiet call. Safe to call from the main thread while the RT tap
    /// runs (guarded read).
    func secondsSinceLastBuffer(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> TimeInterval? {
        bufferClockLock.lock()
        let last = lastBufferHostTime
        bufferClockLock.unlock()
        guard last != 0 else { return nil }
        // Monotonic clock: `now` can only be ≥ `last`. Guard anyway so a paranoid
        // caller never sees a negative age.
        guard now >= last else { return 0 }
        return TimeInterval(now - last) / 1_000_000_000
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
        removeConfigObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        // Release retained session state (the callbacks capture caller closures).
        targetFormat = nil
        continuation = nil
        onLevel = nil
        onCaptureFailed = nil
        currentDeviceUID = nil
        // Clear the mic-alive stamp so a stopped capture never reads as "alive".
        bufferClockLock.lock()
        lastBufferHostTime = 0
        bufferClockLock.unlock()
        // `captured` is intentionally left intact: bufferedAudio() drains it after stop().
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
