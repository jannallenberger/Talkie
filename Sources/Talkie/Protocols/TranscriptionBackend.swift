import AVFoundation
import Speech

/// The seam that lets the mic engine, the far-end engine, a wider-hardware
/// fallback (feature 20), and an opt-in cloud accuracy mode (feature 18) all be
/// interchangeable. It is a *generalization* of `TranscriptionEngine`; that actor
/// conforms as `AppleSpeechBackend` with no behavior change (see
/// `Backends/AppleSpeechBackend.swift`).
///
/// `requiresNetwork` is load-bearing for the privacy wall (feature 15): the
/// composition root must refuse to instantiate any backend whose `requiresNetwork`
/// is `true` unless the user has flipped the explicit opt-in.
protocol TranscriptionBackend: Sendable {
    /// Whether on-device transcription exists at all on this hardware/OS.
    static var isAvailable: Bool { get }
    /// `false` for on-device backends; `true` gates the sandbox/consent wall.
    var requiresNetwork: Bool { get }
    /// Apple: `true`. whisper.cpp/Parakeet: `false` — callers must tolerate no biasing.
    var supportsContextualStrings: Bool { get }

    /// Switch the language used for subsequent live sessions (language auto-detect).
    func setLocaleIdentifier(_ id: String) async
    /// Phrases that bias recognition toward custom vocabulary (no-op where unsupported).
    func setContextualStrings(_ phrases: [String]) async

    /// Begin a live streaming session. Returns the audio format the caller must
    /// feed (e.g. `AudioCapture` / `SystemAudioCapture` convert to it) plus the
    /// continuation to push `AnalyzerInput` buffers into — exactly like
    /// `TranscriptionEngine.beginSession` today, so capture plugs in unchanged.
    /// `onUpdate` receives live partials (dictation HUD); `onSegment` fires once
    /// per finalized batch (incremental cleanup / meeting turn logging).
    func beginSession(
        onUpdate: (@Sendable (TranscriptUpdate) -> Void)?,
        onSegment: (@Sendable (String) -> Void)?
    ) async throws -> (format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation)

    /// Stop feeding audio, flush, and return the final transcript.
    func finishSession() async -> String
    /// Hard-cancel without producing a transcript.
    func cancelSession() async
}
