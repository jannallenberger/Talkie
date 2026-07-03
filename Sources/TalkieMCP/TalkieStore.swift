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

    private var meetingsFile: URL { supportDir.appendingPathComponent("meetings.json") }
    private var entitiesFile: URL { supportDir.appendingPathComponent("graph/entities.json") }
    private var historyFile: URL { supportDir.appendingPathComponent("history.json") }

    func meetings() -> [Meeting] { (decode(meetingsFile) ?? []) }
    func entities() -> [Entity] { (decode(entitiesFile) ?? []) }
    func history() -> [DictationEntry] { (decode(historyFile) ?? []) }
    func brief() -> Brief? { decode(supportDir.appendingPathComponent("context_summary.json")) }

    /// The staleness fingerprint of the three files that feed the semantic index,
    /// stat'd fresh per `tools/call`. A change here invalidates the memoized index so
    /// `search` and `get_recent_context` see new dictations/meetings/entities. Order
    /// is fixed (history, meetings, entities) so the stamp is stable across calls.
    func currentStamp() -> StoreStamp {
        StoreStamp(files: [historyFile, meetingsFile, entitiesFile])
    }

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

    /// Partition a set of commitment entities into meeting-sourced vs dictation-only.
    /// "Meeting-sourced" = has *any* provenance entry stamped `source == "meeting"`
    /// (the LLM finalize path + the meeting import path; see the app's
    /// `ProvenanceSource` enum, whose raw value for `.meeting` is the string
    /// "meeting"). Everything else is dictation-only — the noisy cue-phrase heuristic
    /// ("let me…", "we need to…") that false-positives constantly and shouldn't be
    /// served as if it were a real commitment. Pure (no I/O) so it's unit-testable.
    static func partitionCommitments(_ entities: [Entity]) -> (meeting: [Entity], dictationOnly: [Entity]) {
        var meeting: [Entity] = []
        var dictationOnly: [Entity] = []
        for e in entities {
            if (e.provenance ?? []).contains(where: { $0.source == "meeting" }) {
                meeting.append(e)
            } else {
                dictationOnly.append(e)
            }
        }
        return (meeting, dictationOnly)
    }

    func listCommitments(limit: Int, includeDictations: Bool = false) -> String {
        let all = entities()
            .filter { $0.id.kind == "commitment" }
            .sorted { ($0.lastSeenUnix ?? 0) > ($1.lastSeenUnix ?? 0) }
        let (meetingSourced, dictationOnly) = Self.partitionCommitments(all)

        // Default view: meeting-sourced only. Opt-in (`includeDictations`) returns
        // everything, preserving the pre-L12 behavior of listing every commitment.
        let shown = Array((includeDictations ? all : meetingSourced).prefix(max(1, limit)))

        func line(_ e: Entity) -> String {
            let src = e.provenance?.last.map { " — from \($0.source) on \(stamp($0.dateUnix))" } ?? ""
            return "• \(e.displayName)\(src)"
        }

        guard !shown.isEmpty else {
            return "No commitments recorded yet — Talkie records these from meeting transcripts, on-device."
        }

        var out = shown.map(line).joined(separator: "\n")
        // When we hid dictation-only items (default view), say so honestly in ONE
        // footer line — and tell the caller how to see them.
        if !includeDictations, !dictationOnly.isEmpty {
            out += "\n(\(dictationOnly.count) more heard in dictations — hidden by default: they're usually phrasing like \"let me check…\", not real commitments. Pass include_dictations: true to see them.)"
        }
        return out
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

        // Build the per-source records once, memoized — but invalidated by the store
        // stamp (L14): a changed history/meetings/entities file rebuilds the index so
        // this shipped tool stops going stale in a long-lived session. `sources`
        // filters which records exist in the index — mirroring the old per-source
        // gating — so the cache key includes the requested source set.
        let index = searchCache.index(for: sources, stamp: currentStamp(), build: {
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
                        text: text, sourceRank: 2, dateUnix: m.startUnix))
                }
            }
            if want("dictations") {
                for d in history() {
                    records.append(SemanticRecord(
                        line: "dictation [\(d.id.uuidString.prefix(8))] \(stamp(d.timestampUnix)): \(d.text.prefix(100))",
                        text: d.text, sourceRank: 1, dateUnix: d.timestampUnix))
                }
            }
            if want("entities") {
                for e in entities() {
                    records.append(SemanticRecord(
                        line: "entity (\(e.id.kind)) \(e.displayName)",
                        text: e.displayName, sourceRank: 3, dateUnix: e.lastSeenUnix ?? 0))
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

    // MARK: get_recent_context (L14) — a time-windowed join across the stores

    /// Per-item and total display caps for the recent-context report, so a chatty
    /// window can't return a wall of text. Chosen to keep the report scannable.
    private static let recentDictationCap = 12
    private static let recentDictationCharCap = 220
    private static let recentGraphPerKindCap = 6
    private static let recentRelatedDefaultK = 5

    /// Recency-decayed re-rank of semantic hits for `get_recent_context` ONLY. The
    /// `search` tool's ranking is deliberately NOT touched by this: `minSemantic` /
    /// `substringFloor` were calibrated undecayed, so decaying `search` would move a
    /// calibrated boundary. Here recency is the point, so we decay — but WITHIN tiers.
    ///
    /// Formula (the named constant is `tau`):
    ///
    ///     score' = tierBase + exp(-Δt / τ) × tierInner
    ///
    /// where a hit's raw score from `SemanticIndex` decomposes into a tier:
    ///   • lexical  (raw ≥ 1.0): tierBase = 1.0, tierInner = raw − 1.0
    ///   • semantic (raw < 1.0): tierBase = 0.0, tierInner = raw
    /// and Δt = max(0, now − hit.dateUnix), τ = max(window, 10 min).
    ///
    /// Because the decay multiplies only `tierInner`, a fully-decayed lexical hit
    /// still floors at 1.0 — above the 0.7 ceiling of ANY semantic-only hit. So an old
    /// exact-term hit still outranks a fresh paraphrase-only hit: G3's
    /// lexical-above-semantic rule survives structurally under decay.
    static func recencyDecay(rawScore: Double, ageSeconds: Double, tau: Double) -> Double {
        let dt = max(0, ageSeconds)
        let decay = exp(-dt / max(tau, 1))
        // Tier split at the 1.0 lexical base used by `SemanticIndex.search`.
        if rawScore >= 1.0 {
            return 1.0 + decay * (rawScore - 1.0)
        } else {
            return decay * rawScore
        }
    }

    /// τ for the recency decay: the longer of the requested window and a 10-minute
    /// floor, so a tiny window (e.g. 2 min) doesn't make everything decay to nothing.
    static func recencyTau(windowSeconds: Double) -> Double {
        max(windowSeconds, 10 * 60)
    }

    /// Human age like "3m ago" / "2h ago" / "just now", for stamping Related hits by
    /// how old they are (the report is otherwise absolute-timestamped).
    private func ageLabel(_ unix: Double, now: Double) -> String {
        let secs = max(0, now - unix)
        if secs < 60 { return "just now" }
        let mins = Int(secs / 60)
        if mins < 60 { return "\(mins)m ago" }
        let hours = Int(secs / 3600)
        if hours < 24 { return "\(hours)h ago" }
        return "\(Int(secs / 86400))d ago"
    }

    /// `get_recent_context(minutes, topic?, limit?)` — a stamped, sectioned report of
    /// what happened in the last `minutes`: dictations in the window, meetings that
    /// overlap it, graph entities touched in it (grouped by kind), and — only when a
    /// `topic` is given — recency-decayed semantic neighbours over the FULL index.
    /// Every line carries a timestamp. An empty window returns an honest one-liner;
    /// nothing is padded or invented. Read-only.
    func getRecentContext(minutes: Int, topic: String?, limit: Int?) -> String {
        let now = Date().timeIntervalSince1970
        let window = Double(max(1, minutes)) * 60
        let cutoff = now - window
        var sections: [String] = []

        // --- Dictations in [cutoff, now], newest first -------------------------
        let recentDictations = history()
            .filter { $0.timestampUnix >= cutoff && $0.timestampUnix <= now }
            .sorted { $0.timestampUnix > $1.timestampUnix }
        // The window-empty signal is defined by dictations (the spec's exact copy).
        guard !recentDictations.isEmpty || hasNonDictationActivity(cutoff: cutoff, now: now) else {
            return "Nothing dictated in the last \(minutes) minute\(minutes == 1 ? "" : "s")."
        }

        if !recentDictations.isEmpty {
            let shown = recentDictations.prefix(Self.recentDictationCap)
            var lines = shown.map { d -> String in
                let app = (d.appName?.isEmpty == false) ? " (\(d.appName!))" : ""
                let text = d.text.count > Self.recentDictationCharCap
                    ? String(d.text.prefix(Self.recentDictationCharCap)) + "…" : d.text
                return "• [\(stamp(d.timestampUnix))]\(app) \(text)"
            }
            if recentDictations.count > shown.count {
                lines.append("  (+\(recentDictations.count - shown.count) more in window)")
            }
            sections.append("## Dictations (last \(minutes)m — \(recentDictations.count) total)\n" + lines.joined(separator: "\n"))
        }

        // --- Meetings overlapping [cutoff, now] --------------------------------
        // A meeting overlaps the window iff it started before `now` and ended after
        // `cutoff` (start + duration ≥ cutoff).
        let overlappingMeetings = meetings()
            .filter { $0.startUnix <= now && ($0.startUnix + $0.durationSec) >= cutoff }
            .sorted { $0.startUnix > $1.startUnix }
        if !overlappingMeetings.isEmpty {
            let lines = overlappingMeetings.map { m -> String in
                let oneLine = m.summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? "(no summary)"
                return "• [\(stamp(m.startUnix))] \(m.title) — \(oneLine)"
            }
            sections.append("## Meetings overlapping window\n" + lines.joined(separator: "\n"))
        }

        // --- Graph activity: entities with any provenance in the window --------
        let graphBlock = graphActivity(cutoff: cutoff, now: now)
        if !graphBlock.isEmpty { sections.append(graphBlock) }

        // --- Related (topic only): recency-decayed semantic neighbours ---------
        if let topic = topic?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty {
            let k = max(1, limit ?? Self.recentRelatedDefaultK)
            let related = relatedByTopic(topic, k: k, window: window, now: now)
            sections.append("## Related to “\(topic)” (recency-weighted)\n" + related)
        }

        let header = "# Recent context — last \(minutes) minute\(minutes == 1 ? "" : "s") (as of \(stamp(now)))"
        return ([header] + sections).joined(separator: "\n\n")
    }

    /// Is there any meeting/entity activity in the window even when no dictation is?
    /// Used so a window with (say) an active meeting but no dictation still reports,
    /// rather than falsely claiming "nothing dictated".
    private func hasNonDictationActivity(cutoff: Double, now: Double) -> Bool {
        if meetings().contains(where: { $0.startUnix <= now && ($0.startUnix + $0.durationSec) >= cutoff }) { return true }
        for e in entities() {
            if (e.provenance ?? []).contains(where: { $0.dateUnix >= cutoff && $0.dateUnix <= now }) { return true }
        }
        return false
    }

    /// The "Graph activity" section: entities with ANY provenance dateUnix in the
    /// window, grouped person/project/term/commitment, each with a mention count and
    /// its latest in-window snippet. Commitments are labelled as the heuristic they
    /// are. Returns "" when nothing in the graph was touched in the window.
    private func graphActivity(cutoff: Double, now: Double) -> String {
        struct Touched { let e: Entity; let latest: Double; let snippet: String? }
        var byKind: [String: [Touched]] = [:]
        for e in entities() {
            let inWindow = (e.provenance ?? []).filter { $0.dateUnix >= cutoff && $0.dateUnix <= now }
            guard !inWindow.isEmpty else { continue }
            let newest = inWindow.max { $0.dateUnix < $1.dateUnix }!
            byKind[e.id.kind, default: []].append(Touched(e: e, latest: newest.dateUnix, snippet: newest.snippet))
        }
        guard !byKind.isEmpty else { return "" }

        // Fixed, honest kind order + labels. Commitments carry the heuristic caveat.
        let order: [(kind: String, label: String)] = [
            ("person", "People"), ("project", "Projects"),
            ("term", "Terms"), ("commitment", "Commitment phrases heard (heuristic)"),
        ]
        var blocks: [String] = []
        for (kind, label) in order {
            guard let items = byKind[kind], !items.isEmpty else { continue }
            let sorted = items.sorted { $0.latest > $1.latest }.prefix(Self.recentGraphPerKindCap)
            var lines: [String] = ["### \(label)"]
            for t in sorted {
                let snip = t.snippet.map { " — \($0)" } ?? ""
                lines.append("• \(t.e.displayName) (\(t.e.mentions ?? 0)×, latest [\(stamp(t.latest))])\(snip)")
            }
            if items.count > sorted.count { lines.append("  (+\(items.count - sorted.count) more)") }
            blocks.append(lines.joined(separator: "\n"))
        }
        // Any kinds outside the fixed order (future-proofing) are ignored on purpose —
        // the four above are the only kinds the graph emits today.
        return "## Graph activity in window\n" + blocks.joined(separator: "\n")
    }

    /// Related-to-topic: recency-decayed semantic hits over the FULL index (all
    /// sources), NOT the window — the point is "what across all my history relates to
    /// this topic, freshest first". Uses the stamped, invalidating cache. Each hit is
    /// labelled with its absolute date and its age.
    private func relatedByTopic(_ topic: String, k: Int, window: Double, now: Double) -> String {
        // Build/reuse the full-index (nil sources) via the same stamped cache as
        // `search`, so this is fresh and cheap after the first build in a session.
        let index = searchCache.index(for: nil, stamp: currentStamp(), build: {
            var records: [SemanticRecord] = []
            for m in meetings() {
                let text = m.summary.isEmpty ? m.transcript
                    : (m.transcript.isEmpty ? m.summary : m.summary + "\n\n" + m.transcript)
                records.append(SemanticRecord(
                    line: "meeting [\(m.id.uuidString.prefix(8))] \(m.title) — \(stamp(m.startUnix))",
                    text: text, sourceRank: 2, dateUnix: m.startUnix))
            }
            for d in history() {
                records.append(SemanticRecord(
                    line: "dictation [\(d.id.uuidString.prefix(8))] \(stamp(d.timestampUnix)): \(d.text.prefix(100))",
                    text: d.text, sourceRank: 1, dateUnix: d.timestampUnix))
            }
            for e in entities() {
                records.append(SemanticRecord(
                    line: "entity (\(e.id.kind)) \(e.displayName)",
                    text: e.displayName, sourceRank: 3, dateUnix: e.lastSeenUnix ?? 0))
            }
            return SemanticIndex(records: records)
        })

        // Over-fetch, then recency-decay WITHIN tiers and take the top k.
        let tau = Self.recencyTau(windowSeconds: window)
        let raw = index.search(topic, limit: max(k * 4, 20))
        guard !raw.isEmpty else { return "(no related items found)" }
        let decayed = raw.map { hit -> (hit: SemanticHit, score: Double) in
            let age = hit.dateUnix > 0 ? now - hit.dateUnix : 0
            return (hit, Self.recencyDecay(rawScore: hit.score, ageSeconds: age, tau: tau))
        }.sorted { $0.score > $1.score }.prefix(k)

        return decayed.map { d in
            let ageTag = d.hit.dateUnix > 0 ? " · \(ageLabel(d.hit.dateUnix, now: now))" : ""
            let snip = d.hit.snippet
            let showSnip = !snip.isEmpty && !d.hit.line.contains(snip.prefix(40))
            let head = "• \(d.hit.line)  [\(String(format: "%.2f", d.score))\(ageTag)]"
            return showSnip ? "\(head)\n  ↳ \(snip)" : head
        }.joined(separator: "\n")
    }

    // MARK: graph_query (L14) — entity recall + on-the-fly co-occurrence

    /// `graph_query(entity, limit?)` — resolve an entity by name/alias (same matching
    /// as `lookup_entity`), then print its header (kind, mentions, first/last seen),
    /// up to ~8 stamped provenance snippets, and a "Seen together" list of other
    /// entities that share ≥1 provenance sourceID with it, ranked by shared-source
    /// count. The co-occurrence is DERIVED on the fly (no stored edges), so a
    /// purge-by-sourceID automatically severs it — no new true-delete surface. O(n·p)
    /// at the hard caps (≤2000 entities × ≤12 provenance), trivial per call. Read-only.
    func graphQuery(entity query: String, limit: Int?) -> String {
        let q = query.lowercased()
        let all = entities()
        // Reuse lookup_entity's matching (displayName/alias substring), then pick the
        // most-mentioned as the resolved target.
        let matches = all.filter {
            $0.displayName.lowercased().contains(q) || ($0.aliases ?? []).contains { $0.lowercased().contains(q) }
        }.sorted { ($0.mentions ?? 0) > ($1.mentions ?? 0) }
        guard let target = matches.first else { return "No entity matching \"\(query)\"." }

        var out: [String] = []
        // Header.
        let first = target.firstSeenUnix.map { stamp($0) } ?? "?"
        let last = target.lastSeenUnix.map { stamp($0) } ?? "?"
        var header = "# \(target.displayName) — \(target.id.kind), \(target.mentions ?? 0) mention\((target.mentions ?? 0) == 1 ? "" : "s")"
        header += "\nfirst seen [\(first)] · last seen [\(last)]"
        if let aliases = target.aliases, !aliases.isEmpty {
            header += "\naliases: \(aliases.joined(separator: ", "))"
        }
        out.append(header)

        // Up to ~8 stamped provenance snippets, newest first.
        let provCap = max(1, limit ?? 8)
        let prov = (target.provenance ?? []).sorted { $0.dateUnix > $1.dateUnix }.prefix(provCap)
        if !prov.isEmpty {
            let lines = prov.map { p -> String in
                let snip = p.snippet.map { ": \($0)" } ?? ""
                return "• [\(stamp(p.dateUnix))] \(p.source)\(snip)"
            }
            out.append("## Provenance (newest first)\n" + lines.joined(separator: "\n"))
        }

        // Co-occurrence: other entities sharing ≥1 provenance sourceID with the target.
        let cooccur = Self.coOccurring(target: target, all: all)
        if cooccur.isEmpty {
            out.append("## Seen together (same dictations/meetings)\n(none — no shared sources found)")
        } else {
            let lines = cooccur.prefix(provCap).map { "• \($0.entity.displayName) (\($0.entity.id.kind)) — \($0.shared) shared source\($0.shared == 1 ? "" : "s")" }
            out.append("## Seen together (same dictations/meetings)\n" + lines.joined(separator: "\n"))
        }
        return out.joined(separator: "\n\n")
    }

    /// Compute the entities that co-occur with `target` — i.e. share ≥1 provenance
    /// `sourceID` — ranked by the count of shared source IDs (desc), then by mentions,
    /// then name, for a deterministic order. Pure (no I/O) so it's unit-testable.
    /// Derived, never stored: purging a sourceID removes it from both provenance lists
    /// and this join simply stops returning that pair.
    static func coOccurring(target: Entity, all: [Entity]) -> [(entity: Entity, shared: Int)] {
        let targetSources = Set((target.provenance ?? []).compactMap { $0.sourceID })
        guard !targetSources.isEmpty else { return [] }
        let targetKey = target.id
        var result: [(entity: Entity, shared: Int)] = []
        for e in all {
            // Skip the target itself (same kind+key).
            if e.id.kind == targetKey.kind && e.id.key == targetKey.key { continue }
            let shared = Set((e.provenance ?? []).compactMap { $0.sourceID }).intersection(targetSources).count
            if shared > 0 { result.append((e, shared)) }
        }
        return result.sorted {
            if $0.shared != $1.shared { return $0.shared > $1.shared }
            if ($0.entity.mentions ?? 0) != ($1.entity.mentions ?? 0) { return ($0.entity.mentions ?? 0) > ($1.entity.mentions ?? 0) }
            return $0.entity.displayName < $1.entity.displayName
        }
    }
}

/// A cheap staleness fingerprint of the on-disk stores: the `(mtime, size)` of each
/// file that feeds the index. Two stamps compare equal iff none of the tracked files
/// changed since the last build. Stat'ing three files is ~microseconds, so this runs
/// per `tools/call` with no measurable cost (the co-occurrence note in the spec).
///
/// Why `(mtime, size)` and not a content hash: the app writes these files atomically
/// (write-temp-then-rename) whenever a dictation/meeting/entity lands, which bumps
/// mtime; size catches the rare same-second edit that keeps the mtime. Missing files
/// stamp as `(0, 0)` — a store that doesn't exist yet is "unchanged" until it appears.
/// Rebuild is cheap post-L13-a: the sidecar's `contentHash → vector` reuse means only
/// genuinely new records embed, so an invalidated stamp costs ~one new record, not a
/// full re-embed of the corpus.
struct StoreStamp: Equatable {
    /// One `(mtime, size)` pair per tracked file, in a fixed order.
    let marks: [Int64]

    /// Stat the given files (order-significant) into a stamp. A file that can't be
    /// stat'd contributes `(0, 0)` so a not-yet-created store is stable, not a crash.
    init(files: [URL]) {
        var m: [Int64] = []
        m.reserveCapacity(files.count * 2)
        let fm = FileManager.default
        for url in files {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970.rounded()) } ?? 0
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            m.append(mtime); m.append(size)
        }
        marks = m
    }
}

/// Process-lifetime memoization for the semantic search index, invalidated by a
/// `StoreStamp`. Reference type so a value-type `TalkieStore` can hold a persistent
/// cache; unsynchronized because the MCP stdio loop is single-threaded (`main.swift`
/// handles one message at a time). Keyed by the requested `sources` set, because that
/// set determines which records the index contains (the old code gated per source,
/// and so must this).
///
/// L14 freshness fix: the previous version memoized per process and NEVER invalidated,
/// so a long-lived Claude session's `search` (and the new recall tools) went stale —
/// "the last 10 minutes" was unanswerable because new dictations never entered the
/// index. Now each cached index carries the stamp it was built at; a changed stamp
/// forces a rebuild. This fixes the shipped `search` tool's staleness too, not just
/// the new tools.
final class SemanticSearchCache {
    private var cached: [String: (stamp: StoreStamp, index: SemanticIndex)] = [:]

    /// Return the memoized index for this `sources` filter, rebuilding when the store
    /// `stamp` differs from the one the cached index was built at. `sources == nil`
    /// (all sources) and an explicit list are distinct keys, matching the pre-change
    /// per-source gating.
    func index(for sources: [String]?, stamp: StoreStamp, build: () -> SemanticIndex) -> SemanticIndex {
        // Order-independent key so ["meetings","dictations"] and the reverse share
        // one index; nil (== all) is its own key.
        let key = sources.map { $0.sorted().joined(separator: "|") } ?? "*all*"
        if let hit = cached[key], hit.stamp == stamp { return hit.index }
        let built = build()
        cached[key] = (stamp, built)
        return built
    }
}
