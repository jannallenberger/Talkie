@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Speech

/// Hands a single buffer to `AVAudioConverter` exactly once (reference type so the
/// converter's input block doesn't capture mutable locals — Swift 6 clean).
private final class SingleShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Thread-safe rolling buffer of converted far-end PCM, used to re-transcribe a
/// stream in another language at stop. Unlike the mic's dictation buffer (which
/// freezes at its cap), this DROPS the oldest frames so a long meeting always
/// retains the most-recent window — bounded memory regardless of duration.
/// Appended on the Core Audio realtime thread, drained on the main thread.
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

enum SystemAudioError: LocalizedError {
    case translateSelfFailed
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case noTapFormat
    case noConverter
    case ioProcFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .translateSelfFailed: return "Could not resolve Talkie's audio process object."
        case .tapCreationFailed(let s): return "Failed to create the system-audio tap (\(s))."
        case .aggregateCreationFailed(let s): return "Failed to create the capture aggregate device (\(s))."
        case .noTapFormat: return "The system-audio tap reported no usable format."
        case .noConverter: return "No converter from the tap format to the analyzer format."
        case .ioProcFailed(let s): return "Failed to start the capture I/O proc (\(s))."
        }
    }
}

/// Captures the Mac's **system output audio** — what the far end of a call plays
/// through the speakers — via a Core Audio *global process tap that excludes
/// Talkie's own process*, so our own UI sounds / TTS never leak in. The tap is
/// wrapped in a private aggregate device; its PCM is converted to the analyzer's
/// format and yielded into a second `SpeechTranscriber` (labeled "Them").
///
/// Why a global tap (not per-app / not ScreenCaptureKit): WebRTC apps (Zoom,
/// Teams, Meet-in-a-browser) emit far-end audio from helper subprocesses, so a
/// per-app tap records silence. A global tap excluding self is the reliable path
/// and only needs the light "Audio Recording" permission, not Screen Recording.
///
/// Requires macOS 14.4+ (we target 26). `NSAudioCaptureUsageDescription` must be
/// present in Info.plist or tap creation fails / prompts silently.
final class SystemAudioCapture: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false // main-thread only (start/stop, checkHealth rebuild)
    private let ioQueue = DispatchQueue(label: "com.coralate.talkie.system-audio")
    private var captured: CapturedAudio? // retains far-end PCM for language re-transcription

    // MARK: Retained session parameters (for watchdog rebuild)
    //
    // The far-end tap can die on a long session while its IOProc keeps firing all-zero
    // PCM (plan 01 §4.2a); the only reliable recovery is a full tap+aggregate teardown
    // and rebuild. To rebuild without the caller re-driving `start()`, we retain the
    // exact session parameters here — mirroring `AudioCapture`'s retained-session
    // pattern. Set in `start()`, cleared in `stop()`. Touched only on the main thread
    // (start / stop / checkHealth-driven rebuild), so no lock is needed for these.
    private var targetFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var bufferAudio = false
    private var bufferSeconds: Double = 600
    private var onLevel: (@Sendable (Float) -> Void)?

    // MARK: Tap-health counters (written on the RT thread, read on main)
    //
    // The realtime IOProc stamps liveness here; `checkHealth` reads it on the main
    // thread. Both sides go through `healthLock` — the documented lock discipline for
    // this `@unchecked Sendable` (like `CapturedAudio`'s own lock for the PCM ring).
    // Times are `DispatchTime` uptime nanoseconds (monotonic; RT-safe; no allocation).
    private let healthLock = NSLock()
    /// Host time of the last buffer whose RMS cleared the silence floor; 0 = none yet.
    private var lastNonSilentHostTime: UInt64 = 0
    /// True once any non-silent far-end buffer has arrived for the current tap.
    private var everReceivedNonSilent = false

    // MARK: Watchdog bookkeeping (main-thread only)
    private let watchdog = FarEndWatchdog()
    /// When the current capture (this tap) started, monotonic seconds; nil when idle.
    private var captureStartHostTime: UInt64 = 0
    /// Rebuilds performed this meeting (reset in `start()`, preserved across rebuilds).
    private var rebuildCount = 0
    /// Host time of the last rebuild; 0 = none yet. Gates the watchdog's backoff.
    private var lastRebuildHostTime: UInt64 = 0

    /// RMS floor below which a far-end buffer counts as "silent" for the watchdog.
    /// Matches the plan's ~1e-4 threshold: comfortably above float denormal noise,
    /// well below real speech, so an all-zero (dead-tap) stream never clears it while
    /// genuine call audio always does.
    private static let silenceFloor: Float = 1e-4

    /// Best-effort: process taps exist on macOS 14.4+. We deploy to 26, so this is
    /// always true, but the check documents the requirement and guards a future
    /// lower target.
    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    /// Begin capturing system output. Pushes converted buffers (in `targetFormat`,
    /// typically 16 kHz mono) into `continuation`. `onLevel` is called with a
    /// normalized 0…1 level for an optional far-end activity indicator. Throws if
    /// the tap / aggregate / converter can't be built, so the caller can fall back
    /// to mic-only capture.
    func start(
        targetFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        bufferAudio: Bool = false,
        bufferSeconds: Double = 600,
        onLevel: (@Sendable (Float) -> Void)? = nil
    ) throws {
        guard !isRunning else { return }

        // Retain the session parameters so the watchdog can rebuild the tap+aggregate
        // against the SAME continuation without the caller re-driving start().
        self.targetFormat = targetFormat
        self.continuation = continuation
        self.bufferAudio = bufferAudio
        self.bufferSeconds = bufferSeconds
        self.onLevel = onLevel

        // Fresh meeting: reset the watchdog's per-meeting bookkeeping (rebuild cap,
        // last-rebuild time) and the RT health counters. A rebuild (below) does NOT
        // reset these — the cap must span the whole meeting.
        rebuildCount = 0
        lastRebuildHostTime = 0
        resetHealthCounters()

        do {
            try buildAndStart()
        } catch {
            // Nothing came up — release the retained params so a stopped/failed capture
            // never looks half-configured to a later checkHealth.
            clearSessionParameters()
            throw error
        }
        isRunning = true
    }

    /// Build the tap + aggregate + IOProc from the retained session parameters and
    /// start the device. Shared by `start()` and `rebuild()` so the exact
    /// resolve-self → create-tap → read-format → create-aggregate → build-converter →
    /// install-IOProc → device-start sequence lives in one place (mirroring
    /// `AudioCapture.installAndStart`). On any failure it tears down partial Core Audio
    /// state and throws; the caller decides whether to degrade to mic-only.
    private func buildAndStart() throws {
        guard let targetFormat, let continuation else {
            throw SystemAudioError.noConverter
        }

        // 1. Resolve our own process as an AudioObjectID so the tap can exclude us.
        let selfObject = try Self.audioObject(forPID: getpid())

        // 2. A global tap of every process EXCEPT Talkie. Private (doesn't appear as
        //    a selectable device) and unmuted (we still hear the call normally).
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfObject])
        tapDescription.name = "Talkie Far-End Capture"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTap)
        guard tapStatus == noErr, newTap != kAudioObjectUnknown else {
            throw SystemAudioError.tapCreationFailed(tapStatus)
        }
        tapID = newTap

        // 3. Read the tap's native stream format → an AVAudioFormat we can convert from.
        guard let sourceFormat = Self.tapFormat(tapID) else {
            cleanUpCoreAudio()
            throw SystemAudioError.noTapFormat
        }

        // 4. A private aggregate device that owns the tap, with drift compensation
        //    so the tap clock can't slowly skew against the mic clock.
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Talkie Far-End Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ],
            ],
        ]

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregate)
        guard aggStatus == noErr, newAggregate != kAudioObjectUnknown else {
            cleanUpCoreAudio()
            throw SystemAudioError.aggregateCreationFailed(aggStatus)
        }
        aggregateID = newAggregate

        // 5. Converter from the tap's format (usually 2ch float @ 48k) to the
        //    analyzer's mono 16k. Captured by value in the realtime block so the
        //    render thread never reads a property the main thread mutates.
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            cleanUpCoreAudio()
            throw SystemAudioError.noConverter
        }
        converter.primeMethod = .none

        // Optionally retain converted far-end PCM so the stream can be
        // re-transcribed in another language at stop (drop-oldest rolling window).
        let capture = bufferAudio
            ? CapturedAudio(maxFrames: AVAudioFramePosition(targetFormat.sampleRate * bufferSeconds))
            : nil
        captured = capture

        // Mark this tap's start for the watchdog's grace window.
        captureStartHostTime = DispatchTime.now().uptimeNanoseconds

        let onLevel = self.onLevel
        let floor = Self.silenceFloor

        // 6. Install the I/O proc. It fires on a realtime thread with the tap's PCM.
        //    `[weak self]` so the RT block can stamp the (lock-guarded) health counters
        //    without retaining the capture.
        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, aggregateID, ioQueue
        ) { [weak self] _, inInputData, _, _, _ in
            guard let wrapped = AVAudioPCMBuffer(pcmFormat: sourceFormat, bufferListNoCopy: inInputData) else {
                return
            }
            guard wrapped.frameLength > 0 else { return }
            let level = Self.level(of: wrapped)
            // Watchdog health stamp: record the host time of any non-silent buffer.
            // An all-zero (dead-tap) stream never clears the floor, so this timestamp
            // stops advancing exactly when the documented bug strikes.
            if level > floor {
                self?.markNonSilent(at: DispatchTime.now().uptimeNanoseconds)
            }
            if let onLevel { onLevel(level) }
            guard let converted = Self.convert(buffer: wrapped, using: converter, to: targetFormat),
                  converted.frameLength > 0 else { return }
            capture?.append(converted)
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        guard procStatus == noErr, let procID = newProcID else {
            cleanUpCoreAudio()
            throw SystemAudioError.ioProcFailed(procStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            cleanUpCoreAudio()
            throw SystemAudioError.ioProcFailed(startStatus)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        cleanUpCoreAudio()
        clearSessionParameters()
        resetHealthCounters()
    }

    /// The converted far-end audio captured during the last recording, drained for
    /// language re-transcription. Survives `stop()` (the Core Audio teardown does
    /// not touch it); cleared on the next `start()`.
    func bufferedAudio() -> [AVAudioPCMBuffer] { captured?.drain() ?? [] }

    // MARK: Zero-PCM watchdog (plan 01 §4.2a)

    /// The outcome of a `checkHealth` poll, for the recorder's honest-UI decision.
    enum HealthOutcome: Equatable, Sendable {
        /// The far-end tap looks healthy (or the watchdog isn't yet decidable).
        case healthy
        /// The tap looked dead and was rebuilt in place — transcription continues
        /// transparently on the same continuation.
        case rebuilt
        /// The tap stayed dead past the rebuild cap (or a rebuild failed). Far-end is
        /// given up; the recorder should set `capturingFarEnd = false` (mic-only).
        case gaveUp
    }

    /// Poll the far-end tap's health and act on the watchdog's decision. Called ~1 Hz
    /// from `MeetingRecorder.tick()` on the main actor.
    ///
    /// `micSecondsSinceLastBuffer` is the mic-alive cross-check: seconds since the mic
    /// last delivered a buffer (nil = never / stopped). It distinguishes "the call is
    /// genuinely silent" from "the far-end tap died" — a dead tap while the mic is
    /// still producing audio is the signal to rebuild; a quiet call with a quiet mic is
    /// left alone. See `FarEndWatchdog` for the full decision.
    ///
    /// Returns `.healthy` when nothing was done, `.rebuilt` when the tap was torn down
    /// and rebuilt in place, or `.gaveUp` when far-end capture is abandoned. A no-op
    /// (`.healthy`) when not running.
    @discardableResult
    func checkHealth(micSecondsSinceLastBuffer: TimeInterval?) -> HealthOutcome {
        guard isRunning else { return .healthy }

        let now = DispatchTime.now().uptimeNanoseconds
        let (lastNonSilent, everReceived) = healthSnapshot()

        let micAlive: Bool
        if let mic = micSecondsSinceLastBuffer {
            micAlive = mic <= watchdog.thresholds.micAliveWindow
        } else {
            micAlive = false
        }

        let input = FarEndWatchdog.Input(
            now: seconds(now),
            startedAt: seconds(captureStartHostTime),
            lastNonSilentAt: lastNonSilent == 0 ? nil : seconds(lastNonSilent),
            everReceivedNonSilent: everReceived,
            rebuildCount: rebuildCount,
            lastRebuildAt: lastRebuildHostTime == 0 ? nil : seconds(lastRebuildHostTime),
            micAliveRecently: micAlive
        )

        switch watchdog.decide(input) {
        case .ok:
            return .healthy
        case .rebuild:
            let ok = rebuild()
            lastRebuildHostTime = DispatchTime.now().uptimeNanoseconds
            rebuildCount += 1
            if ok {
                talkieDebugLog("FarEndWatchdog: far-end tap looked dead (silent while mic alive) — rebuilt tap+aggregate (rebuild \(rebuildCount)/\(watchdog.thresholds.maxRebuilds)).")
                return .rebuilt
            } else {
                // A rebuild that can't come back means far-end is gone for this meeting.
                talkieDebugLog("FarEndWatchdog: rebuild \(rebuildCount) FAILED to restart the tap — giving up on far-end (mic-only).")
                isRunning = false
                clearSessionParameters()
                return .gaveUp
            }
        case .giveUp:
            talkieDebugLog("FarEndWatchdog: far-end tap stayed dead past the rebuild cap (\(watchdog.thresholds.maxRebuilds)) — degrading to mic-only.")
            stop()
            return .gaveUp
        }
    }

    /// Full teardown + rebuild of the tap AND aggregate against the retained session
    /// parameters (plan 01 §4.2a: only a complete tap+aggregate rebuild recovers the
    /// all-zero-PCM bug — restarting the IOProc or rebuilding just the aggregate is not
    /// reliable). The far-end engine and `TurnLog` sit upstream of the continuation, so
    /// this is transparent to transcription — the stream simply resumes. Returns false
    /// if the rebuild couldn't restart (caller degrades to mic-only). Resets the RT
    /// health counters so the fresh tap gets its own grace window; the per-meeting
    /// rebuild cap is deliberately preserved.
    ///
    /// `cleanUpCoreAudio()` does `ioQueue.sync {}`, briefly blocking the main thread
    /// while the last in-flight IOProc buffer drains — the same block that already
    /// happens at every `stop()`; acceptable at ~1 Hz from `tick()`.
    private func rebuild() -> Bool {
        guard isRunning else { return false }
        cleanUpCoreAudio()
        // A rebuilt tap starts its own grace window; the meeting-wide cap is untouched.
        // (`buildAndStart` re-stamps `captureStartHostTime`, so the grace measures from
        // the fresh tap, not the original start.)
        resetHealthCounters()
        do {
            try buildAndStart()
            return true
        } catch {
            return false
        }
    }

    // MARK: Watchdog state helpers

    /// Record (from the RT thread) that a non-silent far-end buffer arrived. Guarded;
    /// the only RT-thread writer of the health counters.
    private func markNonSilent(at host: UInt64) {
        healthLock.lock()
        lastNonSilentHostTime = host
        everReceivedNonSilent = true
        healthLock.unlock()
    }

    /// Read the health counters under the lock (main-thread reader).
    private func healthSnapshot() -> (lastNonSilentHostTime: UInt64, everReceived: Bool) {
        healthLock.lock()
        defer { healthLock.unlock() }
        return (lastNonSilentHostTime, everReceivedNonSilent)
    }

    /// Clear the RT health counters (new tap gets a clean slate). Does NOT reset the
    /// per-meeting rebuild cap.
    private func resetHealthCounters() {
        healthLock.lock()
        lastNonSilentHostTime = 0
        everReceivedNonSilent = false
        healthLock.unlock()
    }

    /// Release the retained session parameters (called on stop / give-up / failed
    /// start) so a torn-down capture never looks half-configured.
    private func clearSessionParameters() {
        targetFormat = nil
        continuation = nil
        onLevel = nil
        captureStartHostTime = 0
    }

    /// Convert monotonic host nanoseconds to seconds for the pure watchdog. A zero
    /// origin maps to 0 (the watchdog only reads it when the paired flag says valid).
    private func seconds(_ host: UInt64) -> TimeInterval {
        TimeInterval(host) / 1_000_000_000
    }

    /// Tear down whatever Core Audio objects exist, in dependency order. Safe to
    /// call from a partially-constructed state (every step is guarded).
    private func cleanUpCoreAudio() {
        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            // AudioDeviceStop only stops *new* callbacks — an in-flight I/O block can
            // still be appending. Drain the serial I/O queue so the last buffer lands
            // before bufferedAudio() reads it and before we destroy the proc.
            ioQueue.sync {}
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Core Audio helpers

    /// Translate a process id into its `AudioObjectID` (needed to exclude ourselves
    /// from the global tap).
    private static func audioObject(forPID pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else {
            throw SystemAudioError.translateSelfFailed
        }
        return objectID
    }

    /// Read the tap's stream format and wrap it as an `AVAudioFormat`.
    private static func tapFormat(_ tap: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    /// Convert one PCM buffer from the tap format to the analyzer format.
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
        if status == .error || error != nil { return nil }
        return output
    }

    /// Perceptual 0…1 level (dB-mapped RMS) of a far-end buffer, for an indicator.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let samples = channels[0]
        var sumSquares: Float = 0
        for i in 0..<frames { sumSquares += samples[i] * samples[i] }
        let rms = (sumSquares / Float(frames)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 55) / 55))
    }
}
