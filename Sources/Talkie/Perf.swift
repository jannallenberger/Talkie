import Foundation
import OSLog

/// Opt-in performance tracing for the dictation processing pipeline — the work
/// that happens *after* you release the key (finalize → optional re-transcribe →
/// cleanup → insert). Signposts are always emitted (free unless Instruments is
/// recording); the human-readable per-stage summary logs only when the
/// `TALKIE_PERF` environment variable is set, so it's silent in normal use.
///
/// Why this exists: the processing step had no instrumentation, so the split
/// between speech finalization, language re-transcription, and on-device LLM
/// cleanup was a guess. With this we can see exactly where the time goes.
enum Perf {
    static let signposter = OSSignposter(subsystem: "com.talkie.app", category: "dictation")
    static let log = Logger(subsystem: "com.talkie.app", category: "perf")
    static let isVerbose = ProcessInfo.processInfo.environment["TALKIE_PERF"] != nil
}

/// Accumulates per-stage wall-clock timings for one processing pass and logs a
/// single one-liner when finished. Cheap: a few `CFAbsoluteTimeGetCurrent`
/// reads and a string join, all gated behind `Perf.isVerbose`.
struct ProcessingTrace {
    private let start = CFAbsoluteTimeGetCurrent()
    private var last = CFAbsoluteTimeGetCurrent()
    private var stages: [(name: String, ms: Double)] = []

    /// Record the time elapsed since the previous mark under `name`.
    mutating func stage(_ name: String) {
        guard Perf.isVerbose else { return }
        let now = CFAbsoluteTimeGetCurrent()
        stages.append((name, (now - last) * 1000))
        last = now
    }

    /// Emit the summary line: `processing finalize=12 cleanup=340 insert=2 total=360ms …`.
    func finish(chars: Int, streamed: Bool) {
        guard Perf.isVerbose else { return }
        let total = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let parts = stages.map { "\($0.name)=\(Int($0.ms.rounded()))" }.joined(separator: " ")
        Perf.log.log("processing \(parts) total=\(Int(total.rounded()))ms chars=\(chars) streamed=\(streamed)")
    }
}
