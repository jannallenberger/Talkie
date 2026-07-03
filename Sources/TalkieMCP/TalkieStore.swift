import Foundation

/// Read-mostly access to the on-disk Talkie stores for the MCP server. A *peer
/// reader* of the same JSON/Markdown the app writes — it never holds a lock the
/// app holds and works whether or not the app is running. Slim local Codable
/// mirrors avoid importing the app target (keeping this a separate, network-free
/// binary); a shared library to de-dupe them is a later refactor.
struct TalkieStore {
    let supportDir: URL
    let meetingsDir: URL
    /// Lazily-built, process-lifetime cache of the semantic search index. A
    /// reference type so the memoized index survives across `search` calls even
    /// though `TalkieStore` is a value type held in the top-level `server`. The
    /// stdio loop in `main.swift` is single-threaded (one `readLine` at a time),
    /// so an unsynchronized cache is safe — no actor/lock needed.
    private let searchCache = SemanticSearchCache()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        supportDir = home.appendingPathComponent("Library/Application Support/Talkie", isDirectory: true)
        meetingsDir = home.appendingPathComponent("Talkie Meetings", isDirectory: true)
    }

    // MARK: Dictionary teach-back (the ONE write path — an inbox handshake, A5)

    /// A single Claude-suggested dictionary change, dropped as one atomic JSON file
    /// into `~/Library/Application Support/Talkie/inbox/` for the app to confirm.
    ///
    /// This server NEVER touches `dictionary.json`: the app saves it unconditionally
    /// (`DictionaryStore.save()` overwrites the whole file), so a peer write here
    /// would race and could clobber the user's curated vocab. Instead every
    /// suggestion is its own file — atomic, and two concurrent Claude sessions can't
    /// clobber each other because there's no shared JSON to contend on. The app
    /// watches the dir, validates, applies via the same `addLearnedReplacement` /
    /// `addVocabularyTerm` the LearningEngine uses, and shows the HUD-Undo pill — so
    /// a prompt-injected session can never *silently* pollute recognition.
    ///
    /// The shape is mirrored on the app side (`DictionaryInbox.Suggestion`) rather
    /// than shared, for the same reason the store models above are mirrored: this
    /// binary must not import the app target (it would drag in the whole app and
    /// break the separate, network-free product claim). The two decoders must stay
    /// byte-compatible — extra fields are optional on the reader for back-compat.
    struct DictionarySuggestion: Codable {
        /// `"vocabulary"` (add a bias/vocab term) or `"replacement"` (add a from→to rule).
        var kind: String
        /// For `vocabulary`: the term. For `replacement`: unused.
        var term: String?
        /// For `replacement`: the misheard spelling.
        var from: String?
        /// For `replacement`: the canonical spelling to write.
        var to: String?
        /// Optional free-text note from Claude (why it's suggesting this). Surfaced
        /// nowhere yet; carried for provenance/inspection.
        var note: String?
        /// When the suggestion was written (unix seconds). The app rate-caps on
        /// arrival time, not this, so a back-dated file can't dodge the cap.
        var createdUnix: Double
        /// Schema version, so the app can reject shapes it doesn't understand.
        var version: Int
    }

    /// The inbox directory. Created on demand in BOTH processes (the app may not
    /// have run yet when Claude writes the first suggestion).
    private var inboxDir: URL { supportDir.appendingPathComponent("inbox", isDirectory: true) }

    /// Queue an "add this vocabulary term" suggestion for the user to confirm in
    /// Talkie. Returns a human/model-readable line; the tool layer wraps it.
    func queueVocabularyTerm(_ term: String, note: String?) -> String {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Error: term is empty." }
        let suggestion = DictionarySuggestion(
            kind: "vocabulary", term: trimmed, from: nil, to: nil, note: note,
            createdUnix: Date().timeIntervalSince1970, version: 1)
        return write(suggestion,
                     ok: "Queued “\(trimmed)” — it’ll appear in Talkie with an Undo the moment you confirm it. Nothing changes your recognition until then.")
    }

    /// Queue an "add this from→to replacement rule" suggestion for confirmation.
    func queueReplacement(from: String, to: String, note: String?) -> String {
        let f = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !t.isEmpty else { return "Error: both from and to are required." }
        let suggestion = DictionarySuggestion(
            kind: "replacement", term: nil, from: f, to: t, note: note,
            createdUnix: Date().timeIntervalSince1970, version: 1)
        return write(suggestion,
                     ok: "Queued “\(f)” → “\(t)” — it’ll appear in Talkie with an Undo the moment you confirm it. Nothing changes your recognition until then.")
    }

    /// Write one suggestion as an atomic, uuid-named JSON file. Deterministic key
    /// order (`.sortedKeys`) so the file is stable/inspectable. Best-effort: a write
    /// failure returns an error string rather than crashing the stdio server.
    private func write(_ suggestion: DictionarySuggestion, ok: String) -> String {
        do {
            try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(suggestion)
            // uuid filename → no collision between concurrent sessions; `.json` so
            // the watcher can ignore anything else that lands in the dir.
            let url = inboxDir.appendingPathComponent("\(UUID().uuidString).json")
            try data.write(to: url, options: .atomic)
            return ok
        } catch {
            return "Error: couldn't queue the suggestion (\(error.localizedDescription))."
        }
    }

    // MARK: Models (mirror the app's on-disk shapes; extra fields optional)

    struct Meeting: Codable {
        var id: UUID
        var title: String
        var startUnix: Double
        var durationSec: Double
        var transcript: String
        var summary: String
        var participants: [String]?
        var source: String?
        var fileName: String
        var date: Date { Date(timeIntervalSince1970: startUnix) }
    }
    struct EntityID: Codable { var kind: String; var key: String }
    struct Provenance: Codable { var source: String; var sourceID: String?; var dateUnix: Double; var snippet: String? }
    struct Entity: Codable {
        var id: EntityID
        var displayName: String
        var aliases: [String]?
        var mentions: Int?
        var pinned: Bool?
        var firstSeenUnix: Double?
        var lastSeenUnix: Double?
        var provenance: [Provenance]?
    }
    struct DictationEntry: Codable {
        var id: UUID
        var timestampUnix: Double
        var text: String
        var wordCount: Int?
        var appName: String?
    }
    struct Brief: Codable { var summary: String; var generatedAtUnix: Double? }

    // MARK: Loaders

    func meetings() -> [Meeting] { (decode(supportDir.appendingPathComponent("meetings.json")) ?? []) }
    func entities() -> [Entity] { (decode(supportDir.appendingPathComponent("graph/entities.json")) ?? []) }
    func history() -> [DictationEntry] { (decode(supportDir.appendingPathComponent("history.json")) ?? []) }
    func brief() -> Brief? { decode(supportDir.appendingPathComponent("context_summary.json")) }

    private func decode<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()
    private func stamp(_ unix: Double) -> String { Self.dateFmt.string(from: Date(timeIntervalSince1970: unix)) }

    // MARK: Tool implementations (return human/model-readable text)

    func listMeetings(limit: Int, query: String?) -> String {
        var ms = meetings().sorted { $0.startUnix > $1.startUnix }
        if let q = query?.lowercased(), !q.isEmpty {
            ms = ms.filter { $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q) || $0.transcript.lowercased().contains(q) }
        }
        ms = Array(ms.prefix(max(1, limit)))
        guard !ms.isEmpty else { return "No meetings found." }
        return ms.map { m in
            let mins = Int((m.durationSec / 60).rounded())
            let who = (m.participants ?? []).joined(separator: ", ")
            let oneLine = m.summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? "(no summary)"
            return "• [\(m.id.uuidString.prefix(8))] \(m.title) — \(stamp(m.startUnix)), \(mins) min\(who.isEmpty ? "" : " · \(who)")\n  \(oneLine)"
        }.joined(separator: "\n")
    }

    /// Which field `get_meeting` was asked to select on. Carried through from the
    /// MCP layer so a `date` hint isn't silently treated like an id/title substring.
    enum MeetingSelector {
        case id(String)
        case title(String)
        case date(String)
    }

    /// Does `startUnix` fall within the calendar day named by `hint`? Pure (no I/O),
    /// so it can be exercised in isolation. `hint` is matched against a leading
    /// `yyyy-MM-dd` (the rest, e.g. a time, is ignored); returns nil when the hint
    /// has no parseable date, so callers can decide how to handle a bad hint.
    static func dayBucketMatch(startUnix: Double, hint: String, calendar: Calendar = .current) -> Bool? {
        guard let day = parseDay(hint, calendar: calendar) else { return nil }
        let start = Date(timeIntervalSince1970: startUnix)
        return calendar.isDate(start, inSameDayAs: day)
    }

    /// Parse a leading `yyyy-MM-dd` out of a free-form date hint (tolerating a
    /// trailing time or other text). Returns nil when no such date is present.
    static func parseDay(_ hint: String, calendar: Calendar = .current) -> Date? {
        let trimmed = hint.trimmingCharacters(in: .whitespaces)
        let datePart = trimmed.split(whereSeparator: { $0 == " " || $0 == "T" }).first.map(String.init) ?? trimmed
        let parts = datePart.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(mo), (1...31).contains(d)
        else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        return calendar.date(from: comps)
    }

    func getMeeting(selector: MeetingSelector) -> String {
        let ms = meetings()
        let label: String
        let match: Meeting?
        switch selector {
        case .id(let v):
            label = v
            let key = v.lowercased()
            match = ms.first { $0.id.uuidString.lowercased().hasPrefix(key) }
                ?? ms.first { $0.title.lowercased().contains(key) }
        case .title(let v):
            label = v
            let key = v.lowercased()
            match = ms.first { $0.title.lowercased().contains(key) }
        case .date(let v):
            label = v
            // Day-bucket match on startUnix; no fallback to most-recent when a date
            // hint was supplied (the caller asked for a specific day).
            match = ms.sorted { $0.startUnix > $1.startUnix }
                .first { Self.dayBucketMatch(startUnix: $0.startUnix, hint: v) == true }
        }
        guard let m = match else { return "No meeting found for \"\(label)\"." }
        let mins = Int((m.durationSec / 60).rounded())
        let who = (m.participants ?? []).joined(separator: ", ")
        return """
        # \(m.title)
        \(stamp(m.startUnix)) · \(mins) min\(who.isEmpty ? "" : " · \(who)")

        ## Summary
        \(m.summary.isEmpty ? "(no summary)" : m.summary)

        ## Transcript
        \(m.transcript)
        """
    }

    func getBrief() -> String {
        guard let b = brief(), !b.summary.isEmpty else { return "No brief generated yet." }
        let when = b.generatedAtUnix.map { " (generated \(stamp($0)))" } ?? ""
        return "Today's brief\(when):\n\n\(b.summary)"
    }

    func listCommitments(limit: Int) -> String {
        let commitments = entities()
            .filter { $0.id.kind == "commitment" }
            .sorted { ($0.lastSeenUnix ?? 0) > ($1.lastSeenUnix ?? 0) }
            .prefix(max(1, limit))
        guard !commitments.isEmpty else { return "No commitments recorded yet." }
        return commitments.map { e in
            let src = e.provenance?.last.map { " — from \($0.source) on \(stamp($0.dateUnix))" } ?? ""
            return "• \(e.displayName)\(src)"
        }.joined(separator: "\n")
    }

    func lookupEntity(query: String, kinds: [String]?) -> String {
        let q = query.lowercased()
        var es = entities().filter {
            $0.displayName.lowercased().contains(q) || ($0.aliases ?? []).contains { $0.lowercased().contains(q) }
        }
        if let kinds, !kinds.isEmpty { es = es.filter { kinds.contains($0.id.kind) } }
        es = es.sorted { ($0.mentions ?? 0) > ($1.mentions ?? 0) }
        guard !es.isEmpty else { return "No entity matching \"\(query)\"." }
        return es.prefix(10).map { e in
            let prov = (e.provenance ?? []).suffix(3).compactMap { $0.snippet }.joined(separator: " | ")
            return "• \(e.displayName) (\(e.id.kind), \(e.mentions ?? 0)×)\(prov.isEmpty ? "" : "\n  ↳ \(prov)")"
        }.joined(separator: "\n")
    }

    /// Semantic + keyword search across meetings, dictations, and entities.
    ///
    /// Re-exposes the app's Memory-tab recall (plan 19, §1: search "re-exposed
    /// verbatim through the MCP search tool") instead of the old substring grep, so
    /// a paraphrase like "shipping the updater" finds a meeting that says "release
    /// the auto-update build". Records are built exactly like the app's
    /// `SearchEngine.makeIndex` (meeting = summary+transcript, dictation = text,
    /// entity = displayName) and ranked by the blended cosine+keyword score from
    /// `SemanticCore` (MIRROR of the app's `SemanticIndex`). The `sources` filter
    /// and `limit` are preserved; the output line format is unchanged, with a
    /// score-carrying snippet appended.
    ///
    /// The index is built once per process and memoized (`searchCache`): the first
    /// call pays the embedding cost, later calls are a lookup. When the sentence
    /// model is unavailable, the blend degrades to keyword overlap — the same
    /// behavior as the old substring grep.
    func search(query: String, limit: Int, sources: [String]?) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "Empty query." }
        let want: (String) -> Bool = { sources?.contains($0) ?? true }

        // Build the per-source records once, memoized. `sources` filters which
        // records exist in the index — mirroring the old per-source gating — so the
        // cache key includes the requested source set.
        let index = searchCache.index(for: sources, build: {
            var records: [SemanticRecord] = []
            if want("meetings") {
                for m in meetings() {
                    // Same text the app indexes: summary + transcript (summary alone
                    // if the transcript is empty is covered by the app; here both are
                    // joined so paraphrase recall spans the whole meeting).
                    let text = m.summary.isEmpty ? m.transcript
                        : (m.transcript.isEmpty ? m.summary : m.summary + "\n\n" + m.transcript)
                    records.append(SemanticRecord(
                        line: "meeting [\(m.id.uuidString.prefix(8))] \(m.title) — \(stamp(m.startUnix))",
                        text: text, sourceRank: 2))
                }
            }
            if want("dictations") {
                for d in history() {
                    records.append(SemanticRecord(
                        line: "dictation [\(d.id.uuidString.prefix(8))] \(stamp(d.timestampUnix)): \(d.text.prefix(100))",
                        text: d.text, sourceRank: 1))
                }
            }
            if want("entities") {
                for e in entities() {
                    records.append(SemanticRecord(
                        line: "entity (\(e.id.kind)) \(e.displayName)",
                        text: e.displayName, sourceRank: 3))
                }
            }
            return SemanticIndex(records: records)
        })

        let hits = index.search(q, limit: max(1, limit))
        guard !hits.isEmpty else { return "No matches for \"\(query)\"." }
        return hits.map { hit in
            // Preserve today's line format; append a score-carrying snippet. The
            // snippet is dropped when it merely repeats a short line (dictations
            // already inline their first 100 chars; entities are just a name).
            let trimmedLine = hit.line
            let snip = hit.snippet
            let showSnippet = !snip.isEmpty && !trimmedLine.contains(snip.prefix(40))
            let scoreTag = String(format: "  [%.2f]", hit.score)
            return showSnippet
                ? "• \(trimmedLine)\(scoreTag)\n  ↳ \(snip)"
                : "• \(trimmedLine)\(scoreTag)"
        }.joined(separator: "\n")
    }
}

/// Process-lifetime memoization for the semantic search index. Reference type so a
/// value-type `TalkieStore` can hold a persistent cache; unsynchronized because the
/// MCP stdio loop is single-threaded (`main.swift` handles one message at a time).
/// Keyed by the requested `sources` set, because that set determines which records
/// the index contains (the old code gated per source, and so must this).
final class SemanticSearchCache {
    private var cached: [String: SemanticIndex] = [:]

    /// Return the memoized index for this `sources` filter, building it once on the
    /// first request for that filter. `sources == nil` (all sources) and an explicit
    /// list are distinct keys, matching the pre-change per-source gating.
    func index(for sources: [String]?, build: () -> SemanticIndex) -> SemanticIndex {
        // Order-independent key so ["meetings","dictations"] and the reverse share
        // one index; nil (== all) is its own key.
        let key = sources.map { $0.sorted().joined(separator: "|") } ?? "*all*"
        if let hit = cached[key] { return hit }
        let built = build()
        cached[key] = built
        return built
    }
}
