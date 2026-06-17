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

    // MARK: Building the index

    /// Flatten the value-type inputs into `SearchRecord`s and build a `SemanticIndex`.
    /// `nonisolated` + pure: it captures only `Sendable` value types and touches no
    /// `@MainActor` state, so it's safe to run off the main actor (the embedding work
    /// that dominates the cost happens here, off-main).
    nonisolated static func makeIndex(
        dictations: [DictationEntry], meetings: [Meeting], graph: ContextGraphSnapshot
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
        return SemanticIndex(records: records)
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
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            // Build off-main: `makeIndex` is pure over Sendable value types.
            let newIndex = await Task.detached(priority: .utility) {
                SearchEngine.makeIndex(dictations: dictations, meetings: meetings, graph: graph)
            }.value
            guard !Task.isCancelled else { return }
            let count = dictations.count + meetings.count + graph.entities.count
            // Assign back strictly on the main actor.
            self?.apply(newIndex, recordCount: count)
        }
    }

    func search(_ query: String, limit: Int = 20) -> [SearchHit] {
        index.search(query, limit: limit)
    }
}
