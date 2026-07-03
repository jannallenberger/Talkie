// =============================================================================
// `talkie dictate` — voice as a shell primitive (work package G5)
// =============================================================================
//
// Records from the microphone until you press Enter, then prints the raw
// transcript to STDOUT and exits. The whole point is composition:
//
//     git commit -m "$(talkie dictate)"
//     echo "$(talkie dictate)" | pbcopy
//
// For that to work, STDOUT must carry ONLY the final transcript. So every piece
// of chrome — the "recording…" banner, the live partial hypothesis, model-download
// progress, errors — goes to STDERR. Command substitution (`$(…)`) captures stdout
// only, so it sees just the words you spoke.
//
// It is deliberately a PRIMITIVE, not a second copy of the app:
//   • No cleanup, no dictionary rules, no styles — raw recognizer output. Smart
//     cleanup lives in the app; the CLI hands you exactly what the model heard.
//   • No HUD, no injection into other apps, no hotkey.
//   • No write to Talkie's history.json. A second process writing that file would
//     race the app's atomic writes, so it is explicitly forbidden here (per the G5
//     spec / playbook §3.1 persistence rules). `talkie dictate` reads nothing and
//     writes nothing but stdout/stderr.
//
// MICROPHONE PERMISSION — the surprising part (documented in --help too):
// macOS attributes a TCC microphone prompt to the *hosting application*, i.e. the
// terminal you ran `talkie` in (iTerm, Terminal.app, VS Code…), NOT to `talkie`
// itself — the CLI has no bundle identity of its own. So the first run pops a
// "<your terminal> would like to access the microphone" prompt, and the grant is
// remembered against the terminal. If it was denied, the fix is to grant
// Microphone to *the terminal* in System Settings ▸ Privacy & Security.

@preconcurrency import AVFoundation
import Foundation
import TalkieFileKit

// MARK: - Live mic tap

/// A minimal `AVAudioEngine` input tap that converts each mic buffer to the
/// analyzer's format and yields it into an `AsyncStream` continuation — the same
/// shape the app's `AudioCapture` uses, but stripped to the essentials for a CLI:
/// no device switching, no level metering, no auto-detect rolling buffer.
///
/// `@unchecked Sendable` with explicit lock discipline (playbook §3.1): the tap
/// callback runs on a Core Audio render thread, off any actor, while `stop()` may
/// be called from the main thread (Enter) or a signal-handler queue (SIGINT). The
/// only shared mutable state is `finished` (a one-shot latch guarding the
/// continuation so we finish it exactly once); every access takes `lock`. The
/// converter is created once and only ever touched from the render thread. This
/// is why the annotation is accurate.
final class MicTap: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    private let lock = NSLock()
    private var finished = false

    init(targetFormat: AVAudioFormat,
         continuation: AsyncStream<AVAudioPCMBuffer>.Continuation) {
        self.targetFormat = targetFormat
        self.continuation = continuation
    }

    /// Install the tap on the default input and start the engine. Throws if the
    /// input node has no usable format (e.g. no microphone) or the converter can't
    /// be built. Mic PERMISSION is handled before this (see `requestMicAccess`),
    /// so a throw here is a device/format problem, not a consent problem.
    func start() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw DictateError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw DictateError.noCompatibleFormat
        }
        converter.primeMethod = .none // avoid timestamp drift on streamed buffers

        let target = targetFormat
        let sink = continuation
        // Convert on the render thread and yield the analyzer-format buffer. We copy
        // nothing that isn't already a value/reference safe to cross the boundary;
        // the converted buffer is freshly allocated per call.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let converted = MicTap.convert(buffer: buffer, using: converter, to: target),
                  converted.frameLength > 0 else { return }
            sink.yield(converted)
        }

        try engine.start()
    }

    /// Stop the engine, remove the tap, and finish the stream exactly once. Safe to
    /// call from any thread and idempotent — Enter and a racing SIGINT both call it.
    func stop() {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
    }

    /// Convert one PCM buffer from the hardware format to the analyzer format.
    /// Mirrors `AudioCapture.convert` (playbook: reuse the app's proven shape).
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
        let source = SingleShotBuffer(buffer)
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
}

/// Hands a single buffer to `AVAudioConverter` exactly once, by value, so the
/// converter's input block doesn't capture a mutable local (Swift 6 clean).
/// Mirrors the helper in the app's AudioCapture / AudioFileLoader.
private final class SingleShotBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

// MARK: - Errors

enum DictateError: LocalizedError {
    case micPermissionDenied
    case noInputDevice
    case noCompatibleFormat

    var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            return """
            microphone access was denied.
              macOS attributes the mic prompt to your terminal app, not to `talkie`.
              Fix: grant Microphone to your terminal (iTerm, Terminal, VS Code, …) in
              System Settings ▸ Privacy & Security ▸ Microphone, then run this again.
            """
        case .noInputDevice:
            return "no usable microphone was found (the input device reported no audio format)."
        case .noCompatibleFormat:
            return "could not build an audio converter to the speech-analyzer format."
        }
    }
}

// MARK: - Permission

/// Ensure the process (via its hosting terminal) is authorized to use the mic.
/// Returns true if authorized, false if denied/restricted. `.notDetermined`
/// triggers the system prompt (attributed to the terminal) and awaits the answer.
func requestMicAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        return await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    case .denied, .restricted:
        return false
    @unknown default:
        return false
    }
}

// MARK: - Enter / SIGINT wiring

/// A one-shot signal to stop recording, delivered by whichever of Enter or SIGINT
/// fires first. Continuation-based so the async `dictate` flow can simply `await`
/// it. `@unchecked Sendable` + lock: `fire()` may be called from the readLine
/// thread and the signal queue concurrently; the latch resumes the continuation
/// exactly once.
final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock()
            if resumed {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func fire() {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

// MARK: - `talkie dictate`

/// Record from the mic until Enter (or SIGINT), print the raw transcript to stdout.
func runDictate(_ args: CLIArguments) async {
    guard FileTranscriber.isAvailable else {
        warn("error: on-device speech recognition (SpeechTranscriber) is not available on this Mac.")
        exit(1)
    }

    // 1. Permission (attributed to the terminal — see the file header / --help).
    //    On the very first run this pops a system prompt asking for microphone
    //    access *for your terminal app*. Announce it on stderr first so the pause
    //    (waiting on that prompt) isn't mistaken for a hang, and so the "grant it to
    //    the terminal, not to talkie" framing is on screen before the dialog is.
    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
        warn("Requesting microphone access — macOS will ask on behalf of your terminal app; please allow it.")
    }
    guard await requestMicAccess() else {
        warn("error: \(DictateError.micPermissionDenied.localizedDescription)")
        exit(1)
    }

    // 2. Resolve locale + install/reserve the model. A fresh locale may trigger a
    //    one-time on-device asset download; surface that on stderr so a long first
    //    run isn't mistaken for a hang.
    let engine = FileTranscriber(localeIdentifier: args.locale)
    warn("Preparing on-device model for \(args.locale) (first run may download it)…")
    let format: AVAudioFormat
    do {
        try await engine.prepare()
        format = try await engine.preferredAudioFormat()
    } catch {
        warn("error: \(error.localizedDescription)")
        exit(1)
    }

    // 3. Start the mic tap feeding a live buffer stream.
    let (bufferStream, bufferContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
    let tap = MicTap(targetFormat: format, continuation: bufferContinuation)
    do {
        try tap.start()
    } catch {
        warn("error: \(error.localizedDescription)")
        exit(1)
    }

    // 4. Wire the two ways to finish: Enter (readLine on a background thread) and
    //    SIGINT (Ctrl-C). Either one stops the tap, which finishes the buffer
    //    stream, which lets transcribeLive finalize.
    //
    //    Ctrl-C behavior (documented in --help): from HERE ON — i.e. once recording
    //    has started — SIGINT finalizes and prints whatever was captured, so a
    //    Ctrl-C'd dictation still yields its words. That's the useful primitive.
    //    (Before this point, during the mic-permission prompt and model prep, the
    //    default SIGINT disposition still applies: Ctrl-C exits with nothing on
    //    stdout — also fine, since you haven't said anything yet. Either way stdout
    //    stays clean, so command substitution never captures a partial line.)
    let stop = StopSignal()

    // Replace the default terminate-on-SIGINT with a handler that just fires the
    // stop signal. `signal(SIGINT, SIG_IGN)` first so the default action is off,
    // then a DispatchSource observes the signal on a background queue.
    signal(SIGINT, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigintSource.setEventHandler {
        warn("\n(interrupted — finalizing what was captured)")
        stop.fire()
    }
    sigintSource.resume()

    warn("Recording… press Enter to stop (Ctrl-C also finalizes).")

    // readLine blocks, so run it off the cooperative pool on a dedicated thread and
    // fire the stop signal when the user presses Enter (or stdin hits EOF, e.g.
    // piped input closes).
    let enterThread = Thread {
        _ = readLine(strippingNewline: true)
        stop.fire()
    }
    enterThread.stackSize = 1 << 16
    enterThread.start()

    // Consume live progress on stderr while recording. transcribeLive returns once
    // the buffer stream finishes (after tap.stop()).
    async let finalText = engine.transcribeLive(
        bufferStream: bufferStream,
        onProgress: { preview in
            guard !preview.isEmpty else { return }
            // Carriage-return overwrite so the volatile line updates in place on a
            // TTY without scrolling. Truncate very long previews so the line stays
            // one row. This is stderr, so it never contaminates the captured stdout.
            let oneLine = preview.replacingOccurrences(of: "\n", with: " ")
            let clipped = oneLine.count > 100 ? "…" + String(oneLine.suffix(99)) : oneLine
            FileHandle.standardError.write(Data("\r\u{1B}[2K  \(clipped)".utf8))
        }
    )

    // Block until Enter/SIGINT, then stop the tap (finishes the stream → lets
    // transcribeLive finalize).
    await stop.wait()
    sigintSource.cancel()
    tap.stop()

    let text: String
    do {
        text = try await finalText
    } catch {
        warn("\nerror: \(error.localizedDescription)")
        exit(1)
    }

    // Clear the volatile progress line so it doesn't linger above the result.
    FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))

    guard !text.isEmpty else {
        warn("(no speech recognized)")
        // Nothing to compose with; exit non-zero and print nothing on stdout so
        // `$(talkie dictate)` yields an empty string, not a stray blank line.
        exit(1)
    }

    // The one and only thing on stdout: the raw transcript, newline-terminated.
    print(text)
    exit(0)
}
