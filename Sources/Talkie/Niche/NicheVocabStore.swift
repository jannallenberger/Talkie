import Foundation

/// The on-device **niche vocabulary store** — the confidence-based database of the
/// rare, domain-specific words the user actually uses, accumulated across
/// dictations and meetings with provenance, persisted as inspectable JSON under
/// `~/Library/Application Support/Talkie/niche/`. Read through `snapshot()`; the
/// bias assembly consumes that one surface rather than re-deriving anything.
///
/// 100% local — no network, ever. Follows the `XxxStore: ObservableObject`
/// convention (cf. `ContextGraphStore`); the confidence math is pure
/// (`NicheConfidence`) and stored counts are the only on-disk state.
///
/// Deliberately **distinct from** `DictionaryStore`: the dictionary is
/// user-curated and always-on; this store is auto-learned and confidence-gated. A
/// graduated niche term may later be *promoted* into the dictionary on explicit
/// confirmation, but the two stores stay separate.
@MainActor
final class NicheVocabStore: ObservableObject {
    @Published private(set) var niches: [NicheID: Niche] = [:]
    /// Terms keyed by `nicheKey`.
    @Published private(set) var terms: [String: [NicheTerm]] = [:]

    private let fileURL: URL
    private let provenanceCap = 12
    private let termGuard = NicheTermGuard.default

    convenience init() {
        self.init(directory: AppPaths.supportDirectory().appendingPathComponent("niche", isDirectory: true))
    }

    /// Designated init taking the storage directory. The default `init()` uses the
    /// real support dir; tests inject a temporary one so disk state is hermetic.
    init(directory dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("vocab.json")
        load()
        ensureDefaultNiche()
    }

    /// The immutable read surface the bias assembly + UI consume.
    func snapshot(now: Date = Date()) -> NicheVocabSnapshot {
        NicheVocabSnapshot(
            niches: Array(niches.values),
            termsByNiche: terms,
            termGuard: termGuard,
            nowUnix: now.timeIntervalSince1970
        )
    }

    // MARK: Ingest

    /// Fold harvested candidate terms into a niche, incrementing `occurrences`. Call
    /// once per finalized session (batched — never per-term — to avoid write churn).
    func ingest(_ harvested: [String], into nicheKey: String = NicheID.default.key, provenance: Provenance) {
        guard !harvested.isEmpty else { return }
        for raw in harvested {
            upsert(raw, nicheKey: nicheKey, provenance: provenance) { $0.occurrences += 1 }
        }
        touchNiche(nicheKey, at: provenance.dateUnix)
        save()
    }

    /// Record that the user explicitly typed `term` over Talkie's output in this
    /// niche — the strongest signal; graduates the term immediately.
    func recordUserConfirmed(_ term: String, nicheKey: String = NicheID.default.key, provenance: Provenance) {
        upsert(term, nicheKey: nicheKey, provenance: provenance) { $0.userConfirmed += 1 }
        touchNiche(nicheKey, at: provenance.dateUnix)
        save()
    }

    /// Record that the user corrected *away* from a term we surfaced/biased.
    func recordRejection(_ term: String, nicheKey: String = NicheID.default.key) {
        let now = Date().timeIntervalSince1970
        upsert(term, nicheKey: nicheKey,
               provenance: Provenance(source: .dictation, sourceID: nil, dateUnix: now, snippet: nil)) {
            $0.rejections += 1
        }
        save()
    }

    // MARK: One-time sanitation

    /// One-time heal: remove auto-learned terms whose surface is an ordinary word
    /// (EN/DE) and that the user never explicitly curated. Ordinary words are never
    /// rare jargon — they only entered via a harvest/confirm bug — so removing them
    /// fixes a poisoned store and every fresh install. NEVER removes a term the user
    /// curated (in `protected`) or one confirmed repeatedly (userConfirmed >= 2), so
    /// a real ordinary-looking jargon word the user kept re-confirming survives.
    /// `isOrdinary` is injected (rather than calling `DictionaryStore` directly) so
    /// this store stays free of a MainActor spellchecker dependency in tests; the
    /// live call site passes `DictionaryStore.isOrdinaryPhraseOrWord`.
    @discardableResult
    func sanitizeOrdinaryWords(isOrdinary: (String) -> Bool, protected: Set<String>) -> [String] {
        var removed: [String] = []
        for (key, bucket) in terms {
            var kept: [NicheTerm] = []
            kept.reserveCapacity(bucket.count)
            for term in bucket {
                let isProtected = protected.contains(term.term.lowercased())
                if !isProtected, term.userConfirmed < 2, isOrdinary(term.term) {
                    removed.append(term.term)
                } else {
                    kept.append(term)
                }
            }
            terms[key] = kept
        }
        guard !removed.isEmpty else { return removed }
        save()
        talkieDebugLog("NicheVocabStore.sanitizeOrdinaryWords: removed \(removed.count) poisoned term(s): \(removed.joined(separator: ", "))")
        return removed
    }

    // MARK: Purge (true delete — the provenance join key is `Provenance.sourceID`)

    /// Forget everything harvested from one deleted dictation — the true-delete
    /// counterpart to `ingest`. For each term, drop the dictation-sourced provenance
    /// entries that quoted this dictation's text, decrement `occurrences` by exactly
    /// the number of snippets removed (floored at 0), and drop the term entirely once
    /// it has no provenance left AND the user never confirmed it directly — a
    /// user-confirmed term was taught, not merely harvested, so it outlives the
    /// dictation that happened to first surface it (same contract as
    /// `ContextGraphStore.purge`).
    func purge(sourceID: String) {
        var changed = false
        for (key, bucket) in terms {
            var kept: [NicheTerm] = []
            kept.reserveCapacity(bucket.count)
            for var term in bucket {
                let before = term.provenance.count
                term.provenance.removeAll { $0.source == .dictation && $0.sourceID == sourceID }
                let removed = before - term.provenance.count
                if removed > 0 {
                    term.occurrences = max(0, term.occurrences - removed)
                    changed = true
                }
                if !term.provenance.isEmpty || term.userConfirmed > 0 {
                    kept.append(term)
                } else {
                    changed = true
                }
            }
            terms[key] = kept
        }
        guard changed else { return }
        save()
    }

    /// Drop every dictation-sourced provenance across every term, keeping the
    /// pinned/user-confirmed ones — they graduated because the user taught them
    /// directly, not because a dictation happened to be lying around. The bulk
    /// counterpart to `purge(sourceID:)`, matching the same true-delete contract
    /// `ScratchpadStore`/`AutoAddPreviewLog` expose (for a future "clear all history"
    /// entry point — nothing calls this yet since Memory's bulk-wipe control was
    /// removed).
    func purgeAllDictationSourced() {
        var changed = false
        for (key, bucket) in terms {
            var kept: [NicheTerm] = []
            kept.reserveCapacity(bucket.count)
            for var term in bucket {
                let before = term.provenance.count
                term.provenance.removeAll { $0.source == .dictation }
                let removed = before - term.provenance.count
                if removed > 0 {
                    term.occurrences = max(0, term.occurrences - removed)
                    changed = true
                }
                if !term.provenance.isEmpty || term.userConfirmed > 0 {
                    kept.append(term)
                } else {
                    changed = true
                }
            }
            terms[key] = kept
        }
        guard changed else { return }
        save()
    }

    // MARK: Upsert / niche bookkeeping

    private func upsert(_ rawTerm: String, nicheKey: String, provenance: Provenance,
                        _ mutate: (inout NicheTerm) -> Void) {
        let display = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return }
        let key = display.lowercased()
        var bucket = terms[nicheKey] ?? []
        if let idx = bucket.firstIndex(where: { $0.term.lowercased() == key }) {
            var existing = bucket[idx]
            mutate(&existing)
            existing.lastSeenUnix = max(existing.lastSeenUnix, provenance.dateUnix)
            existing.provenance.append(provenance)
            if existing.provenance.count > provenanceCap {
                existing.provenance.removeFirst(existing.provenance.count - provenanceCap)
            }
            bucket[idx] = existing
        } else {
            var fresh = NicheTerm(term: display, nicheKey: nicheKey,
                                  firstSeenUnix: provenance.dateUnix,
                                  lastSeenUnix: provenance.dateUnix,
                                  provenance: [provenance])
            mutate(&fresh)
            bucket.append(fresh)
        }
        terms[nicheKey] = bucket
    }

    private func touchNiche(_ key: String, at unix: Double) {
        let id = NicheID(key: key)
        if var niche = niches[id] {
            niche.lastSeenUnix = max(niche.lastSeenUnix, unix)
            niche.sessionCount += 1
            niches[id] = niche
        } else {
            niches[id] = Niche(id: id, displayName: Self.displayName(for: key), centroid: nil,
                               firstSeenUnix: unix, lastSeenUnix: unix, sessionCount: 1)
        }
    }

    private func ensureDefaultNiche() {
        let id = NicheID.default
        guard niches[id] == nil else { return }
        let now = Date().timeIntervalSince1970
        niches[id] = Niche(id: id, displayName: Self.displayName(for: id.key), centroid: nil,
                           firstSeenUnix: now, lastSeenUnix: now, sessionCount: 0)
    }

    private static func displayName(for key: String) -> String {
        key == NicheID.default.key ? "Your vocabulary"
            : key.replacingOccurrences(of: "-", with: " ").capitalized
    }

    // MARK: Persistence

    /// JSON can't key an object by the composite `NicheID`/`nicheKey`, so we persist
    /// flat arrays (cf. `ContextGraphStore`).
    private struct Payload: Codable {
        var niches: [Niche]
        var terms: [NicheTerm]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        niches = Dictionary(decoded.niches.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        terms = Dictionary(grouping: decoded.terms, by: { $0.nicheKey })
    }

    private func save() {
        prune()
        let payload = Payload(niches: Array(niches.values), terms: terms.values.flatMap { $0 })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Drop long-dead, never-trusted terms so the file stays bounded. Nothing the
    /// user confirmed is ever pruned.
    private func prune() {
        let now = Date().timeIntervalSince1970
        for (key, bucket) in terms {
            terms[key] = bucket.filter { term in
                if term.userConfirmed > 0 { return true }
                let ageDays = (now - term.lastSeenUnix) / 86_400
                if ageDays <= NicheTuning.pruneAgeDays { return true }
                return NicheConfidence.score(term, nowUnix: now) >= NicheTuning.pruneFloor
            }
        }
    }
}
