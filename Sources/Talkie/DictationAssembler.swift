import Foundation

/// Accumulates finalized transcript segments ("batches") and cleans each one as
/// it arrives — so a long dictation is never processed as one huge transcript
/// (which would spike latency and overflow the on-device model's context). On
/// stop, the per-segment cleanups are joined in order ("combined when you press
/// the key again"). For a short dictation this is a single segment, identical to
/// a one-pass cleanup.
///
/// Lock-guarded (not an actor) so the transcription engine can feed segments
/// synchronously from its results loop — guaranteeing every segment is present
/// before `cleaned()` runs on stop.
final class DictationAssembler: @unchecked Sendable {
    /// Cleans a raw segment, or returns nil to keep it verbatim (cleanup off).
    private let cleanFn: @Sendable (String) async -> String?

    private let lock = NSLock()
    private var rawSegments: [String] = []
    private var cleanTasks: [Task<String, Never>] = []

    init(clean: @escaping @Sendable (String) async -> String?) {
        self.cleanFn = clean
    }

    /// Add a finalized segment. Its cleanup starts immediately, hidden behind the
    /// time the user keeps speaking.
    func add(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clean = cleanFn
        let task = Task { (await clean(trimmed)) ?? trimmed }
        lock.withLock {
            rawSegments.append(trimmed)
            cleanTasks.append(task)
        }
    }

    var segmentCount: Int {
        lock.withLock { rawSegments.count }
    }

    /// The joined RAW transcript (no cleanup).
    func raw() -> String {
        lock.withLock { rawSegments.joined(separator: " ") }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Await all in-flight segment cleanups and join them in order.
    func cleaned() async -> String {
        let tasks = lock.withLock { cleanTasks }
        var out: [String] = []
        out.reserveCapacity(tasks.count)
        for task in tasks {
            out.append(await task.value)
        }
        return out.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
