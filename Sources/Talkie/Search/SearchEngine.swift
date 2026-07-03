import Foundation

/// Builds and holds a `SemanticIndex` over the user's dictations, meetings, and
/// graph entities, and answers queries — the "second brain" recall surface
/// (feature 19). On-device only. The search UI / command-palette is the serial
/// wiring pass; this is the headless engine, unit-testable in isolation.
@MainActor
final class SearchEngine: ObservableObject {
    @Published private(set) var recordCount = 0
    private var index = SemanticIndex(records: [])
    /// The in-flight rebuild, so a newer request can cancel an older one (debounce).
    private var rebuildTask: Task<Void, Never>?
    /// The on-disk sentence-vector cache (L13-a). A rebuild loads it to reuse
    /// unchanged records' vectors, then persists the merged set for the CURRENT
    /// records — so relaunch/rebuild re-embeds only new/changed text instead of the
    /// whole corpus. `nil` disables persistence (the pre-L13-a "always cold"
    /// behavior); tests pass a temp dir or `nil`.
    private let sidecar: VectorSidecar

    /// - Parameter sidecarDirectory: the app's Application Support dir (the sidecar
    ///   lives in its `search/` subfolder). Defaults to the real support dir so the
    ///   live app persists vectors; pass a temp dir in tests for hermetic runs, or
    ///   `nil` to disable persistence entirely.
    init(sidecarDirectory: URL? = AppPaths.supportDirectory()) {
        sidecar = VectorSidecar(supportDirectory: sidecarDirectory)
    }

    // MARK: Building the index

    /// Flatten the value-type inputs into `SearchRecord`s and build a `SemanticIndex`,
    /// reusing any cached vectors in `reuse` (keyed by the sidecar's stable content
    /// hash) so unchanged records aren't re-embedded. `nonisolated` + pure: it
    /// captures only `Sendable` value types and touches no `@MainActor` state, so
    /// it's safe to run off the main actor (the embedding work that dominates the
    /// cost happens here, off-main). The returned index exposes `vectorsByHash` for
    /// the caller to persist.
    nonisolated static func makeIndex(
        dictations: [DictationEntry], meetings: [Meeting], graph: ContextGraphSnapshot,
        reuse: [String: [Double]] = [:]
    ) -> SemanticIndex {
        var records: [SearchRecord] = []
        for d in dictations {
            records.append(SearchRecord(id: "dictation:\(d.id.uuidString)", text: d.text,
                                        kind: .dictation, dateUnix: d.timestampUnix))
        }
        for m in meetings {
            let text = m.summary.isEmpty ? m.transcript : m.summary + "\n\n" + m.transcript
            records.append(SearchRecord(id: "meeting:\(m.id.uuidString)", text: text,
                                        kind: .meeting, dateUnix: m.startUnix))
        }
        for e in graph.entities {
            records.append(SearchRecord(id: "entity:\(e.kind.rawValue):\(e.id.key)",
                                        text: e.displayName, kind: .entity, dateUnix: e.lastSeenUnix))
        }
        return SemanticIndex(records: records, reuse: reuse)
    }

    /// Swap in a freshly built index. The ONLY place `index`/`recordCount` are
    /// mutated, and it's `@MainActor`, so the detached compute never touches them.
    func apply(_ newIndex: SemanticIndex, recordCount: Int) {
        index = newIndex
        self.recordCount = recordCount
    }

    /// Reactive rebuild: debounce a burst of store changes (~200ms), build the index
    /// off the main actor from the captured value-type snapshots, then assign it back
    /// strictly on `@MainActor`. Cancels any prior in-flight rebuild so only the latest
    /// snapshot wins (and a cancelled build never clobbers a newer one).
    func scheduleRebuild(dictations: [DictationEntry], meetings: [Meeting], graph: ContextGraphSnapshot) {
        rebuildTask?.cancel()
        let sidecar = self.sidecar
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            // Build off-main: `makeIndex` is pure over Sendable value types. Load the
            // persisted vectors first (off-main disk I/O) so unchanged records reuse
            // their cached embedding instead of re-embedding — the whole point of the
            // sidecar. Then, after building, persist the merged set for exactly the
            // current records (deleted/pruned hashes are simply not re-written, so
            // they age out on this atomic overwrite).
            let newIndex = await Task.detached(priority: .utility) {
                let reuse = sidecar.load()
                let index = SearchEngine.makeIndex(dictations: dictations, meetings: meetings,
                                                   graph: graph, reuse: reuse)
                sidecar.save(vectorsByHash: index.vectorsByHash)
                return index
            }.value
            guard !Task.isCancelled else { return }
            let count = dictations.count + meetings.count + graph.entities.count
            // Assign back strictly on the main actor.
            self?.apply(newIndex, recordCount: count)
        }
    }

    /// Delete the on-disk vector sidecar immediately. Called by the "Clear
    /// everything" flow so the wipe doesn't wait on the debounced rebuild to
    /// eventually rewrite an empty cache. The next rebuild repopulates it.
    func clearSidecar() {
        sidecar.clear()
    }

    func search(_ query: String, limit: Int = 20) -> [SearchHit] {
        index.search(query, limit: limit)
    }
}
