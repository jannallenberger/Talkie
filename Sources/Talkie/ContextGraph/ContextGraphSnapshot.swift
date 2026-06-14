import Foundation

/// An immutable, `Sendable` view of the context graph — the single query surface
/// every consumer (recall, the Brief, voice commands, search, the MCP server)
/// reads, so none of them reinvents it. Produced by `ContextGraphStore.snapshot()`.
struct ContextGraphSnapshot: Sendable {
    /// All entities, most-recently-seen first.
    let entities: [Entity]

    init(entities: [Entity]) {
        self.entities = entities.sorted { $0.lastSeenUnix > $1.lastSeenUnix }
    }

    static let empty = ContextGraphSnapshot(entities: [])

    func entities(of kind: EntityKind) -> [Entity] {
        entities.filter { $0.kind == kind }
    }

    /// Phrases to bias the recognizer toward — the people, projects, and terms the
    /// user actually uses, pinned first then by mention count. This replaces the
    /// ad-hoc bias union currently assembled in `AppDelegate.beginDictation`
    /// (callers move to `graph.biasPhrases()`).
    func biasPhrases(limit: Int = 60) -> [String] {
        let biasable = entities
            .filter { $0.kind != .commitment }
            .sorted { ($0.pinned ? 1 : 0, $0.mentions) > ($1.pinned ? 1 : 0, $1.mentions) }
        var out: [String] = []
        var seen = Set<String>()
        for entity in biasable {
            for name in [entity.displayName] + entity.aliases where seen.insert(name.lowercased()).inserted {
                out.append(name)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// Open commitments / action items, newest first.
    func commitments(limit: Int = 20) -> [Entity] {
        Array(entities(of: .commitment).prefix(limit))
    }

    /// Look up an entity by display name or alias (case-insensitive) — the basis of
    /// "who is X / what is Y" recall.
    func lookup(_ name: String) -> Entity? {
        let key = name.lowercased()
        return entities.first {
            $0.displayName.lowercased() == key || $0.aliases.contains { $0.lowercased() == key }
        }
    }
}
