import Foundation

/// The kind of thing the context graph remembers.
enum EntityKind: String, Codable, Sendable, CaseIterable {
    case person
    case project
    case term
    case commitment
}

/// A stable identity for an entity: its kind plus a normalized key (the lowercased
/// canonical display form). Two mentions that normalize to the same key are the
/// same entity.
struct EntityID: Codable, Sendable, Hashable {
    var kind: EntityKind
    var key: String
}

/// One thing the user talks about — a person, project, vocabulary term, or a
/// commitment — accumulated across every dictation and meeting, with provenance.
/// 100% local; nothing here ever leaves the Mac.
struct Entity: Codable, Sendable, Identifiable {
    var id: EntityID
    var displayName: String
    var aliases: [String] = []
    var mentions: Int = 0
    /// User-curated (e.g. a dictionary term) — always biases recognition.
    var pinned: Bool = false
    var firstSeenUnix: Double
    var lastSeenUnix: Double
    /// Capped recent provenance entries (the store trims to a cap).
    var provenance: [Provenance] = []

    var kind: EntityKind { id.kind }
    var lastSeen: Date { Date(timeIntervalSince1970: lastSeenUnix) }
}
