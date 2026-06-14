import Foundation

/// Builds and holds a `SemanticIndex` over the user's dictations, meetings, and
/// graph entities, and answers queries — the "second brain" recall surface
/// (feature 19). On-device only. The search UI / command-palette is the serial
/// wiring pass; this is the headless engine, unit-testable in isolation.
@MainActor
final class SearchEngine: ObservableObject {
    @Published private(set) var recordCount = 0
    private var index = SemanticIndex(records: [])

    /// Rebuild the index from the current data. Embedding is synchronous; for large
    /// histories the caller can hop this off the main actor (the inputs are value
    /// types, so it's safe to compute a `SemanticIndex` in a detached task and
    /// assign it back). Cheap for a few thousand records.
    func rebuild(dictations: [DictationEntry], meetings: [Meeting], graph: ContextGraphSnapshot) {
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
        index = SemanticIndex(records: records)
        recordCount = records.count
    }

    func search(_ query: String, limit: Int = 20) -> [SearchHit] {
        index.search(query, limit: limit)
    }
}
