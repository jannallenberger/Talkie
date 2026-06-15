import Foundation

/// Cleans dictation transcript segments *as they finalize during recording*,
/// instead of in one big blocking pass after the key is released. Each segment
/// the recognizer commits is handed to the on-device cleanup model immediately;
/// by the time the speaker stops, the earlier segments are usually already
/// cleaned and only the final spoken tail still needs work — so the visible
/// "processing" step shrinks to roughly one segment's worth of latency instead
/// of the whole transcript's.
///
/// Trade-off vs. the old whole-transcript pass: a self-correction that spans a
/// *pause long enough to finalize a segment* ("Thursday … no, Friday") is now
/// cleaned per-segment and won't be merged across that boundary. Within-segment
/// corrections (the common case) are unaffected, and a single-segment dictation
/// is byte-for-byte identical to the old whole pass. The caller keeps the
/// whole/batch pass as a fallback for the language-re-transcription path.
///
/// Thread-safety: `ingest` is invoked synchronously from the transcription
/// engine's `@Sendable` segment handler, off the main actor. A lock guards the
/// task list so ingestion never blocks and never races the stop-time join.
final class StreamingCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<String, Never>] = []
    private let cleanOne: @Sendable (String) async -> String?
    /// When false, segments pass through untouched (cleanup disabled / model
    /// unavailable) — the assembled output is just the raw transcript rejoined.
    private let enabled: Bool

    init(enabled: Bool, cleanOne: @escaping @Sendable (String) async -> String?) {
        self.enabled = enabled
        self.cleanOne = cleanOne
    }

    /// Kick off cleanup of one freshly finalized segment. Returns immediately;
    /// the work runs concurrently. Order is preserved by arrival, not by
    /// completion, so the join reassembles the transcript in spoken order.
    func ingest(_ segment: String) {
        let raw = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let clean = cleanOne
        let run = enabled
        let task = Task<String, Never> {
            guard run else { return raw }
            // Never drop content: a failed/empty cleanup falls back to the raw.
            return (await clean(raw)) ?? raw
        }
        lock.withLock { tasks.append(task) }
    }

    /// How many segments finalized this session. 0 or 1 means the speaker never
    /// paused long enough to split the utterance, so the streamed result equals a
    /// whole-transcript pass; >1 means the caller should prefer a holistic pass so
    /// punctuation isn't fragmented at the pause boundaries.
    var segmentCount: Int { lock.withLock { tasks.count } }

    /// Await every segment's cleanup in arrival order and join. By stop-time the
    /// earlier segments are usually already done, so this mostly waits on the
    /// last one or two still in flight.
    func finishCleaned() async -> String {
        let snapshot = lock.withLock { tasks }
        var out: [String] = []
        out.reserveCapacity(snapshot.count)
        for t in snapshot { out.append(await t.value) }
        return out.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cancel and drop all in-flight work — used when the streamed result is
    /// abandoned (e.g. language auto-detect re-transcribed the whole utterance
    /// in another language, so the streamed cleanup is for the wrong text).
    func cancel() {
        let snapshot = lock.withLock { () -> [Task<String, Never>] in
            let s = tasks
            tasks.removeAll()
            return s
        }
        for t in snapshot { t.cancel() }
    }
}
