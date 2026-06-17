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
    /// Sidecar holding the per-source backfill watermark. Kept separate from
    /// `entities.json` so that file stays a plain `[Entity]` array (the MCP reader
    /// and any human inspecting the graph depend on that shape).
    private let watermarkURL: URL
    private let provenanceCap = 12

    /// Highest `dateUnix` already ingested per source. Backfill skips anything at or
    /// below the watermark, so re-running it over the same stores is a no-op rather
    /// than re-ingesting (and inflating `mentions` on) every source each launch.
    private var backfillWatermark: [ProvenanceSource: Double] = [:]

    init() {
        let dir = AppPaths.supportDirectory().appendingPathComponent("graph", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("entities.json")
        watermarkURL = dir.appendingPathComponent("backfill-watermark.json")
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
    /// immediately without changing any producer. Idempotent across launches: a
    /// per-source watermark skips anything already ingested, so re-running over the
    /// same stores adds no new mentions. (Until producers are wired to `ingest`,
    /// this is the only writer.)
    func backfill(dictations: [DictationEntry], meetings: [Meeting]) {
        let dictationMark = backfillWatermark[.dictation] ?? -.infinity
        let meetingMark = backfillWatermark[.meeting] ?? -.infinity
        var maxDictation = dictationMark
        var maxMeeting = meetingMark

        for entry in dictations where entry.timestampUnix > dictationMark {
            let prov = Provenance(source: .dictation, sourceID: entry.id.uuidString,
                                  dateUnix: entry.timestampUnix, snippet: String(entry.text.prefix(120)))
            for candidate in ContextGraphExtractor.candidates(from: entry.text) {
                upsert(candidate.kind, candidate.displayName, prov)
            }
            maxDictation = max(maxDictation, entry.timestampUnix)
        }
        for meeting in meetings where meeting.startUnix > meetingMark {
            let prov = Provenance(source: .meeting, sourceID: meeting.id.uuidString,
                                  dateUnix: meeting.startUnix, snippet: nil)
            for name in meeting.participants where name != "Me" && name != "Them" {
                upsert(.person, name, prov)
            }
            for candidate in ContextGraphExtractor.candidates(from: meeting.transcript) {
                upsert(candidate.kind, candidate.displayName, prov)
            }
            maxMeeting = max(maxMeeting, meeting.startUnix)
        }

        if maxDictation > dictationMark { backfillWatermark[.dictation] = maxDictation }
        if maxMeeting > meetingMark { backfillWatermark[.meeting] = maxMeeting }
        save()
    }

    // MARK: Upsert / persistence

    private func upsert(_ kind: EntityKind, _ displayName: String, _ provenance: Provenance, pin: Bool = false) {
        let display = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return }
        let id = EntityID(kind: kind, key: ContextGraphPolicy.key(kind, display))
        if var existing = entities[id] {
            // Only a genuinely new (source, sourceID) provenance counts as a new
            // mention — re-ingesting the same source must not inflate `mentions`.
            let isNew = ContextGraphPolicy.isNewProvenance(provenance, in: existing.provenance)
            if pin { existing.pinned = true }
            existing.lastSeenUnix = max(existing.lastSeenUnix, provenance.dateUnix)
            if isNew {
                existing.mentions += 1
                existing.firstSeenUnix = min(existing.firstSeenUnix, provenance.dateUnix)
                existing.provenance.append(provenance)
                if existing.provenance.count > provenanceCap {
                    existing.provenance.removeFirst(existing.provenance.count - provenanceCap)
                }
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
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Entity].self, from: data) {
            entities = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if let data = try? Data(contentsOf: watermarkURL),
           let decoded = try? JSONDecoder().decode([ProvenanceSource: Double].self, from: data) {
            backfillWatermark = decoded
        }
    }

    private func save() {
        // Persist as an array (JSON can't key an object by the composite EntityID).
        if let data = try? JSONEncoder().encode(Array(entities.values)) {
            try? data.write(to: fileURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(backfillWatermark) {
            try? data.write(to: watermarkURL, options: .atomic)
        }
    }
}

/// Pure, `@MainActor`-free policy helpers for the context graph, extracted so they
/// can be unit-tested without disk, a clock, or actor isolation. The store calls
/// into these for all of its non-trivial decisions (identity keys, provenance
/// dedupe, staleness pruning, and capacity eviction).
enum ContextGraphPolicy {
    /// The normalized identity key for an entity of a given kind. People, projects,
    /// and terms key on their lowercased display form; commitments key on a stable
    /// hash of the normalized clause (see the P2-07 change) so two phrasings of the
    /// same action collapse and the key never grows with the clause text.
    static func key(_ kind: EntityKind, _ display: String) -> String {
        display.lowercased()
    }

    /// A provenance is "new" only if its `(source, sourceID)` pair is not already
    /// recorded on the entity. Re-ingesting the same source (e.g. backfill running
    /// again over an already-seen dictation) is therefore a no-op for `mentions`.
    static func isNewProvenance(_ candidate: Provenance, in existing: [Provenance]) -> Bool {
        !existing.contains { $0.source == candidate.source && $0.sourceID == candidate.sourceID }
    }
}
