import Foundation

/// One swappable LLM seam behind the on-device Foundation-Models default
/// (`OnDeviceLLM`, in `Backends/`) and the opt-in cloud bridge (feature 18,
/// `ClaudeBridge`). Unifies the near-identical Foundation-Models call sites
/// (`CleanupEngine`, `MeetingSummarizer`, `ContextSummaryEngine`, and the future
/// context-graph extractor) so the cloud bridge is a drop-in.
///
/// `requiresNetwork` gates the privacy wall (feature 15). Map-reduce for long
/// inputs lives ABOVE this protocol as a helper that chains `generate` calls, so
/// it works with either backend.
protocol Summarizer: Sendable {
    /// Whether this summarizer is usable right now.
    static var isAvailable: Bool { get }
    /// `false` = on-device; `true` gates the sandbox/consent wall.
    var requiresNetwork: Bool { get }

    /// One constrained generation. `instructions` is the system prompt; `input`
    /// the user text. The implementation pins determinism (greedy / low-temp).
    /// Returns `nil` on unavailability, empty input, or failure.
    func generate(instructions: String, input: String) async -> String?
}
