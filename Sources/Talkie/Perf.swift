import Foundation
import OSLog

/// Performance tracing for the dictation processing pipeline — the work that
/// happens *after* you release the key (finalize → optional re-transcribe →
/// cleanup → insert). Per-stage wall-clock timings are ALWAYS accumulated (a
/// couple of `CFAbsoluteTimeGetCurrent` reads per stage — negligible) so the
/// data layer can persist them; the human-readable per-stage summary is only
/// *logged* when the `TALKIE_PERF` environment variable is set, so console
/// output stays silent in normal use.
///
/// Why this exists: the processing step had no instrumentation, so the split
/// between speech finalization, language re-transcription, and on-device LLM
/// cleanup was a guess. With this we can see exactly where the time goes.
enum Perf {
    static let signposter = OSSignposter(subsystem: "com.talkie.app", category: "dictation")
    static let log = Logger(subsystem: "com.talkie.app", category: "perf")
    static let isVerbose = ProcessInfo.processInfo.environment["TALKIE_PERF"] != nil
}

/// Accumulates per-stage wall-clock timings for one processing pass. The stages
/// array is always populated (cheap: one `CFAbsoluteTimeGetCurrent` + append per
/// stage) so callers can read `report`; `finish(...)` additionally logs a single
/// one-liner, but only when `TALKIE_PERF` is set.
struct ProcessingTrace {
    private let start = CFAbsoluteTimeGetCurrent()
    private var last = CFAbsoluteTimeGetCurrent()
    private var stages: [(name: String, ms: Double)] = []

    /// Record the time elapsed since the previous mark under `name`. Always runs
    /// (unguarded) so the timings exist for the data layer in normal runs.
    mutating func stage(_ name: String) {
        let now = CFAbsoluteTimeGetCurrent()
        stages.append((name, (now - last) * 1000))
        last = now
    }

    /// The accumulated per-stage timings plus the total elapsed since the trace
    /// began, in milliseconds. Read by the latency store on the dictation path.
    var report: (stages: [(name: String, ms: Double)], totalMs: Double) {
        (stages, (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    /// Emit the summary line: `processing finalize=12 cleanup=340 insert=2 total=360ms …`.
    /// Only logs when `TALKIE_PERF` is set (the timings themselves are always kept).
    func finish(chars: Int, streamed: Bool) {
        guard Perf.isVerbose else { return }
        let total = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let parts = stages.map { "\($0.name)=\(Int($0.ms.rounded()))" }.joined(separator: " ")
        Perf.log.log("processing \(parts) total=\(Int(total.rounded()))ms chars=\(chars) streamed=\(streamed)")
    }
}
