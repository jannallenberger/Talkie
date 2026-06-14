import AVFoundation
import Speech

/// `TranscriptionEngine` *is* the on-device Apple-Speech backend. The alias gives
/// it the spec name; the conformance below adds the protocol seam (consumed by
/// features 01 / 18 / 20) with **zero behavior change** — the new
/// `beginSession(onUpdate:onSegment:)` overload simply wires the update handler,
/// then defers to the existing `beginSession(segmentHandler:)`.
typealias AppleSpeechBackend = TranscriptionEngine

extension TranscriptionEngine: TranscriptionBackend {
    nonisolated var requiresNetwork: Bool { false }
    nonisolated var supportsContextualStrings: Bool { true }

    // `static isAvailable`, `setLocaleIdentifier`, `setContextualStrings`,
    // `finishSession`, and `cancelSession` are already satisfied by the actor's
    // existing members. Only the merged-signature `beginSession` is new.
    func beginSession(
        onUpdate: (@Sendable (TranscriptUpdate) -> Void)?,
        onSegment: (@Sendable (String) -> Void)?
    ) async throws -> (format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        if let onUpdate { setUpdateHandler(onUpdate) }
        return try await beginSession(segmentHandler: onSegment)
    }
}
