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
final class CaptureWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var totalFrames: AVAudioFramePosition = 0
    private var droppedFrames: AVAudioFramePosition = 0
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
            droppedFrames += AVAudioFramePosition(first.frameLength)
            buffers.removeFirst()
        }
    }

    /// Whether the window still holds the WHOLE capture (nothing rolled off the
    /// front). Re-decoding an incomplete window would silently lose the opening.
    var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return droppedFrames == 0
    }

    /// Seconds of audio currently held.
    var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        guard let rate = buffers.first?.format.sampleRate, rate > 0 else { return 0 }
        return Double(totalFrames) / rate
    }

    /// A non-destructive copy of the held buffers (unlike `drain`).
    func snapshot() -> [AVAudioPCMBuffer] {
        lock.lock(); defer { lock.unlock() }
        return buffers
    }

    func drain() -> [AVAudioPCMBuffer] {
        lock.lock(); defer { lock.unlock() }
        let out = buffers
        buffers = []
        totalFrames = 0
        droppedFrames = 0
        return out
    }
}

/// Where the mic tap delivers each converted buffer: the rolling capture window
/// and the live analyzer's input stream, behind ONE lock. That single lock is what
/// makes a live language restart lossless — `handOff(to:)` replays the captured
/// audio into the new analyzer and retargets the tap in one critical section, so no
/// buffer can land in the old stream after the snapshot or jump ahead of the replay.
final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation
    let captured: CaptureWindow?

    init(continuation: AsyncStream<AnalyzerInput>.Continuation, captured: CaptureWindow?) {
        self.continuation = continuation
        self.captured = captured
    }

    /// Real-time tap thread: record + forward one buffer.
    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        captured?.append(buffer)
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// Replay everything captured so far into `next`, then make it the live target.
    /// Yields are non-blocking (unbounded stream), so the tap waits only for the
    /// copy loop — a few hundred microseconds for the ~seconds of audio involved.
    func handOff(to next: AsyncStream<AnalyzerInput>.Continuation) {
        lock.lock(); defer { lock.unlock() }
        for buffer in captured?.snapshot() ?? [] {
            next.yield(AnalyzerInput(buffer: buffer))
        }
        continuation = next
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
    private var captured: CaptureWindow?

    /// Monotonic host time (`DispatchTime` uptime nanoseconds) of the most recent
    /// buffer the mic tap delivered, or 0 if none since the last `start()`. Written on
    /// the realtime tap thread, read on the main thread, so every access is guarded by
    /// `bufferClockLock` — the documented lock discipline for this `@unchecked Sendable`
    /// (the class already relies on `CaptureWindow`'s own lock for its buffer ring; this
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
    private var feed: AudioFeed?
    private var preferredDeviceUID: String?
    /// UID of the device the tap is currently bound to, so a config change can ask
    /// `AudioDevices.resolveSwap` whether the active device actually changed.
    private var currentDeviceUID: String?
    /// The hardware input format the live tap's converter was built for, so a
    /// configuration change that leaves device AND format untouched (the one
    /// `setDeviceID` itself posts on the first start) needn't rebuild the tap.
    private var tapInputFormat: AVAudioFormat?
    private var onLevel: (@Sendable (Float) -> Void)?
    /// Optional passive tap on the CONVERTED analyzer-format PCM (D9 keep-audio tee),
    /// fired for every non-empty converted buffer just like `captured?.append`. Retained
    /// so the shared `installAndStart` (also used by config-change recovery) captures it
    /// by value into the render block. The tee is deliberately passive — it never blocks
    /// the capture path (the writer behind it hops to its own serial queue) and never
    /// changes what's yielded to the analyzer, so transcription is byte-for-byte
    /// unaffected whether it's set or nil.
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
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
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        onCaptureFailed: (@Sendable (Error) -> Void)? = nil
    ) throws {
        guard !isRunning else { return }

        // Retain a rolling window of converted audio when language auto-detect is on
        // (dictation: ~90 s; meetings pass a larger window). Built once here and
        // *kept* across a hot device swap so the re-transcription window isn't lost.
        let capture = bufferAudio
            ? CaptureWindow(maxFrames: AVAudioFramePosition(targetFormat.sampleRate * bufferSeconds))
            : nil
        self.captured = capture

        // Stash the session parameters so a mid-session device/config change can
        // rebuild the tap without the caller re-driving start().
        self.targetFormat = targetFormat
        self.feed = AudioFeed(continuation: continuation, captured: capture)
        self.preferredDeviceUID = preferredDeviceUID
        self.onLevel = onLevel
        self.onBuffer = onBuffer
        self.onCaptureFailed = onCaptureFailed

        // Fresh session: clear any stale mic-alive stamp from a prior recording so the
        // watchdog doesn't read a live mic before the first new buffer actually lands.
        bufferClockLock.lock()
        lastBufferHostTime = 0
        bufferClockLock.unlock()

        do {
            try installAndStart()
        } catch {
            // installAndStart may have installed the tap before `engine.start()`
            // threw (a device flake) — remove it now. Left in place, the next
            // `start()` installs a second tap on the same bus, which is an
            // uncatchable NSException ("nullptr == Tap()"), not a throwable error —
            // it crashes the process instead of merely failing the next session.
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            throw error
        }

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
        guard let targetFormat, let feed else {
            throw TalkieEngineError.noCompatibleAudioFormat
        }

        // Belt-and-braces: a tap can only be leaked here if a previous
        // `installAndStart()` installed one and then failed before `start()`'s
        // catch could remove it (or before this guard existed). Removing
        // unconditionally is a safe no-op when no tap exists, and guarantees we
        // never call `installTap` on a bus that already has one.
        let started = Date()
        func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
        engine.inputNode.removeTap(onBus: 0)

        let inputNode = engine.inputNode
        let nodeMs = ms(started)

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
        let deviceMs = ms(started)

        engine.prepare() // resolve the input device/format before we read it
        let prepareMs = ms(started)

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

        let onLevel = self.onLevel
        let onBuffer = self.onBuffer
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
                // Passive keep-audio tee (D9): hand the converted buffer to the writer,
                // which copies it and hops to its own serial queue — so this stays a
                // non-blocking, transcription-neutral side effect.
                onBuffer?(converted)
                feed.push(converted)
            }
        }

        tapInputFormat = inputFormat
        try engine.start()
        // Where a slow first pill spends its time (cumulative ms). A cold start after
        // the audio hardware sat idle measured ~2.5 s once, ~0.1 s warm.
        talkieDebugLog("mic: started in \(ms(started)) ms — node \(nodeMs), device \(deviceMs), prepare \(prepareMs), engine.start \(ms(started))")
    }

    /// Do the expensive, mic-free part of starting capture ahead of time — resolve
    /// the input device, instantiate the input node, prepare the engine — so the
    /// first dictation after launch doesn't pay it while the pill waits. Never
    /// starts the engine, so the microphone stays off (no recording indicator).
    func prewarm(preferredDeviceUID: String?) {
        guard !isRunning else { return }
        let started = Date()
        let inputNode = engine.inputNode
        if let device = AudioDevices.resolveInput(preferredUID: preferredDeviceUID) {
            try? inputNode.auAudioUnit.setDeviceID(device.id)
        }
        engine.prepare()
        talkieDebugLog("mic: prewarmed in \(Int(Date().timeIntervalSince(started) * 1000)) ms (mic stays off)")
    }

    /// Recover capture after a mid-session input-device/config change. Always on the
    /// main thread (the observer uses `queue: .main`). Removes the now-dead tap,
    /// re-resolves the input device, rebuilds the converter against the (possibly
    /// changed) format, reinstalls the tap, and restarts the engine. The rolling
    /// `CaptureWindow` buffer is deliberately *kept* so the re-transcription window
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

        // A change that left the engine running on the same device with the same input
        // format — e.g. the one `setDeviceID` posts right after the first start — needs
        // no rebuild. Rebuilding anyway re-ran the whole setup on every first start.
        if case .keep = decision, engine.isRunning,
           let tapInputFormat, engine.inputNode.outputFormat(forBus: 0) == tapInputFormat {
            talkieDebugLog("mic: config change, same device + format, still running — no rebuild")
            return
        }

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
    /// DRAINS the window — a second call returns nothing.
    func bufferedAudio() -> [AVAudioPCMBuffer] {
        captured?.drain() ?? []
    }

    /// Whether the capture window still holds the whole session (nothing rolled off
    /// the front). Read BEFORE `bufferedAudio()`, which resets it.
    var bufferedAudioIsComplete: Bool { captured?.isComplete ?? false }

    /// Seconds of audio captured so far this session (0 when not buffering).
    var bufferedSeconds: Double { captured?.seconds ?? 0 }

    /// A non-destructive copy of the captured audio, for the mid-dictation language
    /// probe. Leaves the window intact for the handoff and the stop-time check.
    func bufferedAudioSnapshot() -> [AVAudioPCMBuffer] {
        captured?.snapshot() ?? []
    }

    /// Live language restart: replay the whole captured session into `continuation`
    /// (a freshly started analyzer's input) and retarget the tap to it, atomically.
    /// Works after `stop()` too (the window survives until drained) — a restart
    /// that races the key release still gets every buffer. Returns false, doing
    /// nothing, when there's no complete window to replay (buffering off, or audio
    /// already rolled off the front) — the new analyzer would miss the opening.
    @discardableResult
    func handOff(to continuation: AsyncStream<AnalyzerInput>.Continuation) -> Bool {
        guard let captured, captured.isComplete else { return false }
        if let feed {
            feed.handOff(to: continuation)
        } else {
            for buffer in captured.snapshot() { continuation.yield(AnalyzerInput(buffer: buffer)) }
        }
        return true
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
        feed = nil
        onLevel = nil
        onBuffer = nil
        onCaptureFailed = nil
        currentDeviceUID = nil
        tapInputFormat = nil
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
