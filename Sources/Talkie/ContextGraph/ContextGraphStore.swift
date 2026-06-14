import Foundation

/// The on-device **Personal Context Graph** — the keystone shared brain. It
/// accumulates entities (people, projects, terms, commitments) extracted from
/// dictations and meetings, each with provenance, persisted as inspectable JSON
/// under `~/Library/Application Support/Talkie/graph/`. Read through `snapshot()`;
/// every recall / Brief / command / search / MCP consumer reads that one surface
/// rather than re-deriving context.
///
/// 100% local — no network, ever. Follows the `XxxStore: ObservableObject`
/// convention; extraction is pure (`ContextGraphExtractor`) and runs off-actor.
@MainActor
final class ContextGraphStore: ObservableObject {
    @Published private(set) var entities: [EntityID: Entity] = [:]

    private let fileURL: URL
    private let provenanceCap = 12

    init() {
        let dir = AppPaths.supportDirectory().appendingPathComponent("graph", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("entities.json")
        load()
    }

    /// The immutable read surface every consumer uses.
    func snapshot() -> ContextGraphSnapshot {
        ContextGraphSnapshot(entities: Array(entities.values))
    }

    // MARK: Ingest

    /// Fold extracted candidates into the graph, attaching provenance. Call after a
    /// dictation or meeting from the candidates of `ContextGraphExtractor`.
    func ingest(_ candidates: [ContextGraphExtractor.Candidate], provenance: Provenance) {
        guard !candidates.isEmpty else { return }
        for candidate in candidates { upsert(candidate.kind, candidate.displayName, provenance) }
        save()
    }

    /// Pin a user-curated term (e.g. a dictionary entry) so it always biases.
    func pinTerm(_ name: String) {
        let display = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return }
        upsert(.term, display,
               Provenance(source: .dictionary, sourceID: nil,
                          dateUnix: Date().timeIntervalSince1970, snippet: nil),
               pin: true)
        save()
    }

    // MARK: Backfill (collision-free: reads existing stores, writes only the graph)

    /// Seed the graph from already-stored dictations + meetings so it is useful
    /// immediately without changing any producer. (A processed-source watermark to
    /// make this fully idempotent across launches is a follow-up; until producers
    /// are wired to `ingest`, this is the only writer.)
    func backfill(dictations: [DictationEntry], meetings: [Meeting]) {
        for entry in dictations {
            let prov = Provenance(source: .dictation, sourceID: entry.id.uuidString,
                                  dateUnix: entry.timestampUnix, snippet: String(entry.text.prefix(120)))
            for candidate in ContextGraphExtractor.candidates(from: entry.text) {
                upsert(candidate.kind, candidate.displayName, prov)
            }
        }
        for meeting in meetings {
            let prov = Provenance(source: .meeting, sourceID: meeting.id.uuidString,
                                  dateUnix: meeting.startUnix, snippet: nil)
            for name in meeting.participants where name != "Me" && name != "Them" {
                upsert(.person, name, prov)
            }
            for candidate in ContextGraphExtractor.candidates(from: meeting.transcript) {
                upsert(candidate.kind, candidate.displayName, prov)
            }
        }
        save()
    }

    // MARK: Upsert / persistence

    private func upsert(_ kind: EntityKind, _ displayName: String, _ provenance: Provenance, pin: Bool = false) {
        let display = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return }
        let id = EntityID(kind: kind, key: display.lowercased())
        if var existing = entities[id] {
            existing.mentions += 1
            existing.lastSeenUnix = max(existing.lastSeenUnix, provenance.dateUnix)
            if pin { existing.pinned = true }
            existing.provenance.append(provenance)
            if existing.provenance.count > provenanceCap {
                existing.provenance.removeFirst(existing.provenance.count - provenanceCap)
            }
            entities[id] = existing
        } else {
            entities[id] = Entity(
                id: id, displayName: display, aliases: [], mentions: 1, pinned: pin,
                firstSeenUnix: provenance.dateUnix, lastSeenUnix: provenance.dateUnix,
                provenance: [provenance]
            )
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Entity].self, from: data) else { return }
        entities = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func save() {
        // Persist as an array (JSON can't key an object by the composite EntityID).
        guard let data = try? JSONEncoder().encode(Array(entities.values)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
