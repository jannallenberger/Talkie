import Foundation

// Reusing the chunk extractions made DURING a recording (W2) when the meeting stops.
//
// The live pass cuts the stable part of the transcript into chunks exactly like the
// batch pipeline (same units, echo de-dup, chunk budget) and keeps each chunk's
// extraction together with the chunk's units. At stop the final units are matched
// against those chunks BY CONTENT (speaker lane + text of every unit, in order):
// a matching run reuses the cached result (its line numbers are remapped onto the
// final lines), and everything that does not match — the tail, a chunk whose text
// changed when a late segment arrived or a language vote moved a word — is cut and
// extracted as usual. The diarized speaker labels are applied afterwards by time
// range, because the live chunks were cut from the lane-labelled (Me/Them) segments
// and diarization splits segments at speaker changes.
//
// Everything here is pure and unit-tested with a fake model.

/// Chunk extractions made during a recording, keyed by their units' content.
struct LiveChunkCache: Sendable {
    struct Entry: Sendable {
        /// The chunk's units as the live pass saw them (lane speaker labels).
        var units: [SummaryUnit]
        /// The extraction, possibly split into pieces on context overflow.
        var pieces: [(chunk: [SummaryUnit], notes: ChunkNotes)]
        /// The prompt conditions it was extracted under; a reuse needs all three equal.
        var language: String
        var speakers: Bool
        var hint: String
    }

    var entries: [Entry] = []
    var isEmpty: Bool { entries.isEmpty }

    /// A unit's content identity: who (lane) and what, not where (indices and times
    /// shift between the live and the final transcript).
    static func key(_ u: SummaryUnit) -> String { (u.speaker ?? "") + "\u{1F}" + u.text }

    /// Replace (or add) the entry for the same unit run.
    mutating func store(_ entry: Entry) {
        let k = entry.units.map(Self.key)
        entries.removeAll { $0.units.map(Self.key) == k }
        entries.append(entry)
    }

    func entries(language: String) -> [Entry] { entries.filter { $0.language == language } }
}

/// One chunk to summarize: its units, and the cached entry whose units it matches.
struct PlannedChunk: Sendable {
    var units: [SummaryUnit]
    var cached: Int?
}

enum SummaryChunkPlanner {
    /// Cut `units` into chunks, reusing every cached chunk whose unit run appears
    /// verbatim (the longest match wins at each position); the units between matches
    /// are chunked greedily with the batch chunker. Every unit lands in exactly one
    /// chunk, in order.
    static func plan(_ units: [SummaryUnit], cache: [LiveChunkCache.Entry], budgetChars: Int,
                     speakers: Bool) -> [PlannedChunk] {
        let keys = units.map(LiveChunkCache.key)
        var byFirst: [String: [Int]] = [:]
        let entryKeys = cache.map { $0.units.map(LiveChunkCache.key) }
        for (i, k) in entryKeys.enumerated() where !k.isEmpty { byFirst[k[0], default: []].append(i) }
        var out: [PlannedChunk] = []
        var gap: [SummaryUnit] = []
        func flush() {
            guard !gap.isEmpty else { return }
            out += SummaryChunker.chunk(gap, budgetChars: budgetChars, speakers: speakers)
                .map { PlannedChunk(units: $0, cached: nil) }
            gap = []
        }
        var p = 0
        while p < units.count {
            var best: (entry: Int, length: Int)?
            for e in byFirst[keys[p]] ?? [] {
                let ek = entryKeys[e]
                guard p + ek.count <= keys.count, Array(keys[p..<(p + ek.count)]) == ek else { continue }
                if ek.count > (best?.length ?? 0) { best = (e, ek.count) }
            }
            if let best {
                flush()
                out.append(PlannedChunk(units: Array(units[p..<(p + best.length)]), cached: best.entry))
                p += best.length
            } else {
                gap.append(units[p])
                p += 1
            }
        }
        flush()
        return out
    }

    /// A cached entry's pieces moved onto the final chunk's units: each cited line
    /// number is remapped by position (a citation outside the chunk stays invalid, so
    /// grounding drops it exactly as it would have).
    static func remap(_ entry: LiveChunkCache.Entry, onto final: [SummaryUnit])
        -> [(chunk: [SummaryUnit], notes: ChunkNotes)] {
        var map: [Int: Int] = [:]
        var unitAt: [Int: SummaryUnit] = [:]
        for (live, fin) in zip(entry.units, final) {
            map[live.index] = fin.index
            unitAt[live.index] = fin
        }
        func line(_ n: Int) -> Int { map[n] ?? -1 }
        return entry.pieces.map { piece in
            let chunk = piece.chunk.compactMap { unitAt[$0.index] }
            var n = piece.notes
            n.topics = n.topics.map { .init(line: line($0.line), text: $0.text) }
            n.decisions = n.decisions.map { .init(line: line($0.line), text: $0.text) }
            n.openQuestions = n.openQuestions.map { .init(line: line($0.line), text: $0.text) }
            n.keyFacts = n.keyFacts.map { .init(line: line($0.line), text: $0.text) }
            n.actionItems = n.actionItems.map { .init(line: line($0.line), owner: $0.owner, task: $0.task, due: $0.due) }
            return (chunk, n)
        }
    }

    /// The chunks a LIVE pass may extract now: not cached yet, and not the last chunk
    /// (the last one can still grow when the next stable text arrives).
    static func closedUncached(_ plan: [PlannedChunk]) -> [Int] {
        plan.indices.filter { i in plan[i].cached == nil && i < plan.count - 1 }
    }
}

/// Diarized speaker labels by time range: a lane-labelled unit ("Them", 12.0-31.5 s)
/// gets the person label that holds most of that span within the same lane.
struct SpeakerTimeMap: Sendable {
    /// Share of a unit's overlapped time one person must hold to get its label.
    static let majorityShare = 0.6

    private let byLane: [String: [(start: Double, end: Double, label: String)]]
    private let laneWide: [String: String]

    init(segments: [MeetingSegment]) {
        var lanes: [String: [(Double, Double, String)]] = [:]
        var labels: [String: Set<String>] = [:]
        for s in segments {
            lanes[s.audioKey, default: []].append((s.start, max(s.start, s.end), s.speaker))
            labels[s.audioKey, default: []].insert(s.speaker)
        }
        byLane = lanes.mapValues { $0.sorted { $0.0 < $1.0 }.map { (start: $0.0, end: $0.1, label: $0.2) } }
        laneWide = labels.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    /// Whether these segments carry diarized labels at all.
    static func isDiarized(_ segments: [MeetingSegment]?) -> Bool {
        segments?.contains { $0.lane != nil } ?? false
    }

    /// The person for `lane` over `start...end`: the label with the largest overlap if
    /// it holds `majorityShare` of the overlapped time; a zero-length span takes the
    /// segment containing it; the lane's single label when it only ever had one; else nil.
    func label(lane: String, start: Double, end: Double) -> String? {
        let items = byLane[lane] ?? []
        let e = max(start, end)
        var weight: [String: Double] = [:]
        for it in items where it.start <= e && it.end >= start {
            let overlap = min(e, it.end) - max(start, it.start)
            weight[it.label, default: 0] += max(overlap, 0)
        }
        let total = weight.values.reduce(0, +)
        if total > 0, let best = weight.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
           best.value >= Self.majorityShare * total {
            return best.key
        }
        if total == 0, let hit = items.first(where: { $0.start <= start && start <= $0.end }) { return hit.label }
        return laneWide[lane]
    }

    /// One extraction piece with its units relabelled and lane-label owners ("Them")
    /// translated to the person on the cited line.
    func apply(_ piece: (chunk: [SummaryUnit], notes: ChunkNotes)) -> (chunk: [SummaryUnit], notes: ChunkNotes) {
        let original = Dictionary(piece.chunk.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        let chunk = piece.chunk.map { u -> SummaryUnit in
            var u = u
            if let lane = u.speaker, let s = u.start,
               let l = label(lane: lane, start: s, end: u.end ?? s) {
                u.speaker = l
            }
            return u
        }
        let relabelled = Dictionary(chunk.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        let lanes = Set(piece.chunk.compactMap(\.speaker))
        var notes = piece.notes
        notes.actionItems = notes.actionItems.map { a in
            var a = a
            let owner = a.owner.trimmingCharacters(in: .whitespaces)
            guard let lane = lanes.first(where: { $0.caseInsensitiveCompare(owner) == .orderedSame }) else { return a }
            if original[a.line]?.speaker == lane, let person = relabelled[a.line]?.speaker {
                a.owner = person
            } else {
                // The lane is named but another lane's line is cited: the lane's single
                // person in this chunk, else let grounding fall back to the cited speaker.
                let people = Set(piece.chunk.filter { $0.speaker == lane }.compactMap { relabelled[$0.index]?.speaker })
                a.owner = people.count == 1 ? people.first! : ""
            }
            return a
        }
        return (chunk, notes)
    }
}

enum NoteLinker {
    /// Which note a decision or action item belongs to: when it came from a chunk
    /// that had note hints, the best-matching note there (most shared content words,
    /// else the nearest in time). Nil without hints.
    static func resolver(hints: [Int: [MeetingNote]], chunks: [[SummaryUnit]],
                         language: SummaryLanguage) -> ((SummaryItem) -> UUID?)? {
        guard !hints.isEmpty else { return nil }
        var chunkOfUnit: [Int: Int] = [:]
        for (i, c) in chunks.enumerated() { for u in c { chunkOfUnit[u.index] = i } }
        return { item in
            guard let c = chunkOfUnit[item.unit], let notes = hints[c], !notes.isEmpty else { return nil }
            let words = Set(Grounding.contentWords(item.text, language: language))
            let scored = notes.map { n -> (id: UUID, shared: Int, distance: Double) in
                let shared = words.intersection(Grounding.contentWords(n.text, language: language)).count
                let distance = abs((n.secondsIntoMeeting ?? 0) - (item.start ?? n.secondsIntoMeeting ?? 0))
                return (n.id, shared, distance)
            }
            return scored.min { a, b in a.shared != b.shared ? a.shared > b.shared : a.distance < b.distance }?.id
        }
    }
}
