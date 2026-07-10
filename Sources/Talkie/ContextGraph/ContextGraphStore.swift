import Foundation

/// Serializes the graph's encode+write off the main actor so folding in a
/// dictation/meeting's extracted candidates never blocks the UI on JSON + disk
/// I/O for the (up to ~2 000-entity) graph. Mirrors `HistoryFileWriter`
/// (`HistoryStore.swift`): each write carries a monotonic `generation`; a write
/// whose generation is already stale (a newer snapshot arrived first) is
/// dropped, so a burst of ingests collapses to the last state and writes can't
/// reorder. `Entity`/`Provenance`/`ProvenanceSource` are all Sendable value
/// types, so the snapshots handed across the actor boundary copy, never share.
actor ContextGraphWriter {
    private let fileURL: URL
    private let watermarkURL: URL
    private var latestWritten = 0

    init(fileURL: URL, watermarkURL: URL) {
        self.fileURL = fileURL
        self.watermarkURL = watermarkURL
    }

    func write(entities: [Entity], watermark: [ProvenanceSource: Double], generation: Int) {
        guard generation > latestWritten else { return }
        latestWritten = generation
        // Persist as an array (JSON can't key an object by the composite EntityID).
        if let data = try? JSONEncoder().encode(entities) {
            try? data.write(to: fileURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(watermark) {
            try? data.write(to: watermarkURL, options: .atomic)
        }
    }
}

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
    /// Hard ceiling on stored entities. 2 000 mirrors `HistoryStore`'s dictation cap
    /// — far beyond any realistic personal vocabulary, while keeping `entities.json`
    /// small enough to load and re-encode in full on every `save()`. Beyond this,
    /// the lowest-value non-pinned entities are evicted.
    private let entityCap = 2000
    /// Non-pinned entities unseen for this long are pruned on `load()`. Generous
    /// (the dictation log itself only keeps 7 days), so the graph stays a long-lived
    /// memory without growing without bound from one-off mentions.
    private let stalenessSeconds: Double = 180 * 24 * 60 * 60 // 180 days

    /// Highest `dateUnix` already ingested per source. Backfill skips anything at or
    /// below the watermark, so re-running it over the same stores is a no-op rather
    /// than re-ingesting (and inflating `mentions` on) every source each launch.
    private var backfillWatermark: [ProvenanceSource: Double] = [:]

    /// Off-main JSON encode + atomic write. Callers are unchanged: `save()` still
    /// looks synchronous to them, but it only schedules — the cost moves here.
    private let writer: ContextGraphWriter
    /// Debounce so a burst of mutations coalesces into one disk write. Mirrors
    /// `HistoryStore`'s `saveDebounce`.
    private let saveDebounce: Duration = .milliseconds(250)
    private var pendingSave: Task<Void, Never>?
    /// Monotonic save token; the writer drops any write older than the newest.
    private var saveGeneration = 0

    convenience init() {
        self.init(directory: AppPaths.supportDirectory().appendingPathComponent("graph", isDirectory: true))
    }

    /// Designated init taking the storage directory. The default `init()` uses the
    /// app's support dir; tests pass a temporary directory so they stay hermetic.
    init(directory dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("entities.json")
        watermarkURL = dir.appendingPathComponent("backfill-watermark.json")
        writer = ContextGraphWriter(fileURL: fileURL, watermarkURL: watermarkURL)
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

    // MARK: Purge (true delete — the provenance join key is `Provenance.sourceID`)

    /// Forget everything the graph learned from a deleted source, so deleting a
    /// dictation or meeting also erases the provenance snippets that quoted its text.
    /// `sourceID == nil` purges the whole source class (used by "Clear all history").
    /// Delegates the decision to the pure `ContextGraphPolicy.purge`, then persists —
    /// the write matters: `entities.json` holds the literal snippets on disk, so a
    /// `grep` of the deleted text over the support directory must come up empty.
    func purge(source: ProvenanceSource, sourceID: String?) {
        let kept = ContextGraphPolicy.purge(entities: Array(entities.values),
                                            source: source, sourceID: sourceID)
        entities = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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
        // entities.json: absent -> start empty (normal first run). Present but
        // undecodable -> `loadOutcome` has already quarantined it to a `.corrupt`
        // sibling; the graph starts empty here too, but see the watermark reset
        // below — otherwise the graph would stay empty forever.
        let entitiesOutcome = StoreLoad.loadOutcome([Entity].self, from: fileURL)
        if case .loaded(let decoded) = entitiesOutcome {
            // Prune stale, low-value entities on load so the graph self-heals from
            // older files that predate the cap (and so eviction has headroom).
            let now = Date().timeIntervalSince1970
            let kept = ContextGraphPolicy.prune(decoded, nowUnix: now,
                                                stalenessSeconds: stalenessSeconds, cap: entityCap)
            entities = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }

        if let decoded = StoreLoad.loadJSONWithQuarantine([ProvenanceSource: Double].self, from: watermarkURL) {
            backfillWatermark = decoded
        }

        // entities.json existed but was just quarantined (undecodable), so the
        // graph above starts empty. If the watermark file just loaded above still
        // records dictations/meetings as "already ingested" from BEFORE the
        // corruption, `backfill(dictations:meetings:)` would see every entry at or
        // below those marks and skip it — permanently leaving the newly-emptied
        // graph empty, since the very sources that could re-seed it are treated as
        // already-done. Reset the two backfill-tracked sources (regardless of what
        // the watermark file said) so the next backfill call re-ingests everything
        // still retained in history/meetings. Persisted immediately — not left to
        // the next `save()` — so a crash before any mutation can't leave the stale,
        // pre-corruption marks on disk to reproduce the same dead end next launch.
        if case .quarantined = entitiesOutcome {
            backfillWatermark[.dictation] = nil
            backfillWatermark[.meeting] = nil
            if let data = try? JSONEncoder().encode(backfillWatermark) {
                try? data.write(to: watermarkURL, options: .atomic)
            }
        }
    }

    /// Schedule a coalesced, off-main persist. Synchronous to callers — it only
    /// snapshots the current entities/watermark and debounces; the JSON encode +
    /// atomic writes run on `ContextGraphWriter`, never on the main actor. Mirrors
    /// `HistoryStore.save()`.
    private func save() {
        // Enforce the hard cap before persisting: evict the lowest-value non-pinned
        // entities so neither the file nor the in-memory map grows without bound.
        // This mutates the @Published `entities` dictionary, so it stays here on
        // the main actor; only the encode+write below moves off it.
        if entities.count > entityCap {
            let now = Date().timeIntervalSince1970
            let kept = ContextGraphPolicy.enforceCap(Array(entities.values), nowUnix: now, cap: entityCap)
            entities = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        saveGeneration += 1
        let generation = saveGeneration
        let entitiesSnapshot = Array(entities.values)     // value-type copy — Sendable across the hop
        let watermarkSnapshot = backfillWatermark          // value-type copy — Sendable across the hop
        let writer = self.writer
        let delay = saveDebounce
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await writer.write(entities: entitiesSnapshot, watermark: watermarkSnapshot, generation: generation)
            // Only clear the handle if a newer save hasn't already replaced it.
            if let self, self.saveGeneration == generation { self.pendingSave = nil }
        }
    }

    /// Force any pending debounced save to complete now (app teardown / tests that
    /// need to observe the on-disk file synchronously after a mutation). Mirrors
    /// `HistoryStore.flush()`.
    func flush() async {
        pendingSave?.cancel()
        pendingSave = nil
        saveGeneration += 1
        await writer.write(entities: Array(entities.values), watermark: backfillWatermark, generation: saveGeneration)
    }
}

/// Pure, `@MainActor`-free policy helpers for the context graph, extracted so they
/// can be unit-tested without disk, a clock, or actor isolation. The store calls
/// into these for all of its non-trivial decisions (identity keys, provenance
/// dedupe, staleness pruning, and capacity eviction).
enum ContextGraphPolicy {
    /// The normalized identity key for an entity of a given kind. People, projects,
    /// and terms key on their lowercased display form. Commitments key on a stable,
    /// bounded hash of the normalized clause rather than the full clause text, so the
    /// key never grows with the sentence and minor whitespace/case differences in the
    /// same action collapse to one entity.
    static func key(_ kind: EntityKind, _ display: String) -> String {
        switch kind {
        case .commitment:
            return "c:" + stableHash(normalizeClause(display))
        case .person, .project, .term:
            return display.lowercased()
        }
    }

    /// A provenance is "new" only if its `(source, sourceID)` pair is not already
    /// recorded on the entity. Re-ingesting the same source (e.g. backfill running
    /// again over an already-seen dictation) is therefore a no-op for `mentions`.
    static func isNewProvenance(_ candidate: Provenance, in existing: [Provenance]) -> Bool {
        !existing.contains { $0.source == candidate.source && $0.sourceID == candidate.sourceID }
    }

    /// True-delete the graph's memory of one source. This is the join key that makes
    /// "delete a dictation and its extracted facts are gone" honest: `Provenance`
    /// carries the originating `source` (dictation / meeting / …) and `sourceID`
    /// (`DictationEntry.id` / `Meeting.id`), so a deleted source can be matched and
    /// its snippets — up to 120 chars of the literal dictation text — physically
    /// removed from every entity.
    ///
    /// - `sourceID != nil` purges just that one source (one deleted dictation/meeting).
    /// - `sourceID == nil` purges the WHOLE source class (e.g. "Clear all history"
    ///   removes every `.dictation` provenance at once).
    ///
    /// For each entity: drop the matching provenance, decrement `mentions` by exactly
    /// the number removed (floored at 0 — a corrupt over-count can never underflow),
    /// and drop the entity entirely once it has no provenance left to justify it —
    /// UNLESS it is `pinned`. A pinned entity is a term the user explicitly taught
    /// (a dictionary rule); it survives even when the mention that first surfaced it
    /// is deleted, because the user curated it directly, not the deleted source.
    /// Pure and actor-free so the delete semantics can be unit-tested without disk.
    static func purge(entities: [Entity], source: ProvenanceSource, sourceID: String?) -> [Entity] {
        var result: [Entity] = []
        result.reserveCapacity(entities.count)
        for var entity in entities {
            let before = entity.provenance.count
            entity.provenance.removeAll { p in
                p.source == source && (sourceID == nil || p.sourceID == sourceID)
            }
            let removed = before - entity.provenance.count
            if removed > 0 {
                entity.mentions = max(0, entity.mentions - removed)
            }
            // Keep the entity if it still has provenance, or if the user pinned it
            // (a taught dictionary term outlives the source that first mentioned it).
            if !entity.provenance.isEmpty || entity.pinned {
                result.append(entity)
            }
        }
        return result
    }

    /// How "valuable" an entity is, for eviction ranking. Higher survives. Driven by
    /// mention count plus a recency bonus that decays linearly over `stalenessSeconds`
    /// — a frequently- or recently-seen entity outranks a one-off old mention. Pinned
    /// entities are handled by the callers (they are never evicted), so they are not
    /// special-cased here.
    static func evictionScore(_ entity: Entity, nowUnix: Double,
                              stalenessSeconds: Double = 180 * 24 * 60 * 60) -> Double {
        let age = max(0, nowUnix - entity.lastSeenUnix)
        let recency = max(0, 1 - age / stalenessSeconds) // 1 (just now) → 0 (>= staleness)
        return Double(entity.mentions) + recency
    }

    /// Drop non-pinned entities unseen for longer than `stalenessSeconds`, then apply
    /// the hard cap. Pinned (user-curated) entities are always kept and never count
    /// against staleness. Used on load to self-heal older, uncapped files.
    static func prune(_ entities: [Entity], nowUnix: Double,
                      stalenessSeconds: Double, cap: Int) -> [Entity] {
        let fresh = entities.filter { $0.pinned || (nowUnix - $0.lastSeenUnix) <= stalenessSeconds }
        return enforceCap(fresh, nowUnix: nowUnix, cap: cap, stalenessSeconds: stalenessSeconds)
    }

    /// Enforce the hard entity cap by evicting the lowest-value **non-pinned**
    /// entities. Pinned entities are always retained even if that pushes the total
    /// above `cap` (the user explicitly curated them). Among non-pinned entities the
    /// lowest `evictionScore` is dropped first.
    static func enforceCap(_ entities: [Entity], nowUnix: Double, cap: Int,
                           stalenessSeconds: Double = 180 * 24 * 60 * 60) -> [Entity] {
        guard entities.count > cap else { return entities }
        let pinned = entities.filter { $0.pinned }
        let evictable = entities.filter { !$0.pinned }
        let room = max(0, cap - pinned.count)
        let survivors = evictable
            .sorted { evictionScore($0, nowUnix: nowUnix, stalenessSeconds: stalenessSeconds)
                    > evictionScore($1, nowUnix: nowUnix, stalenessSeconds: stalenessSeconds) }
            .prefix(room)
        return pinned + Array(survivors)
    }

    // MARK: Helpers

    /// Normalize a commitment clause for keying: lowercased, whitespace-collapsed.
    private static func normalizeClause(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A stable, process-independent hash. `Swift.Hashable` is per-run seeded, so it
    /// would make commitment keys differ across launches; this FNV-1a hash is stable
    /// across runs and machines so the same clause always keys to the same entity.
    private static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
