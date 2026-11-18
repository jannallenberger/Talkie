import Foundation

// The user's notes taken during a meeting (W2). Notes used to be one free-form string
// that a separate model call "fused" with the transcript, which could rewrite, drop or
// contradict them. Now each line is an item with the moment it was started, the notes
// are shown verbatim in their own section of the summary, and each one is handed to
// the summary chunk around its moment as a hint.

/// One line of the user's meeting notes, or a marked moment (a time with no text yet).
struct MeetingNote: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var text: String
    /// Seconds from the recording start at which the line was started (or the moment
    /// was marked). Nil for notes that predate time stamps.
    var secondsIntoMeeting: Double?

    /// A marked moment the user has not written anything for (yet).
    var isMarker: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Light cleanup only: trims, drops a leading bullet the user typed, and collapses
    /// runs of whitespace. Never rewrites words.
    static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = t.first, "-*•–".contains(f) {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        return t.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// Notes from a plain string (an older partial, an older meeting): one item per
    /// non-empty line, without times.
    static func fromPlain(_ text: String) -> [MeetingNote] {
        text.components(separatedBy: .newlines)
            .map(clean)
            .filter { !$0.isEmpty }
            .map { MeetingNote(text: $0, secondsIntoMeeting: nil) }
    }

    /// The notes as plain text, one per line, each with its time stamp.
    static func plainText(_ notes: [MeetingNote]) -> String {
        notes.map { n in
            if let s = n.secondsIntoMeeting { return "[\(MeetingTranscriptRenderer.timecode(s))] \(n.text)".trimmingCharacters(in: .whitespaces) }
            return n.text
        }.joined(separator: "\n")
    }

    /// Decode notes stored either as the item list or as an older plain string.
    static func decodeFlexible<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> [MeetingNote]? {
        if let items = try? c.decodeIfPresent([MeetingNote].self, forKey: key) { return items }
        if let plain = try? c.decodeIfPresent(String.self, forKey: key) {
            let items = fromPlain(plain)
            return items.isEmpty ? nil : items
        }
        return nil
    }
}

/// Keeps a time stamp on every line of the notes editor: a line gets the meeting time
/// at which the user started typing it, and keeps it while it is edited. A line that
/// starts with a `[mm:ss]` stamp (what "Mark this moment" inserts) carries that time
/// instead. Pure, so typing behaviour is unit-tested.
enum MeetingNoteStamper {
    /// One editor line and the time it was started (nil = still empty).
    struct Line: Equatable, Sendable {
        var id: UUID = UUID()
        var text: String
        var seconds: Double?
    }

    /// The editor's new text against the previous lines. Unchanged lines keep their
    /// id and time; an edited line (a removed and an inserted line between the same
    /// unchanged neighbours) keeps the old line's; a new line gets `now` once it has
    /// text.
    static func restamp(_ old: [Line], text: String, now: Double) -> [Line] {
        let newTexts = text.components(separatedBy: "\n")
        let oldTexts = old.map(\.text)
        let diff = newTexts.difference(from: oldTexts)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [Line] = []
        out.reserveCapacity(newTexts.count)
        var oi = 0, ni = 0
        while ni < newTexts.count {
            // A run of changes between unchanged lines: pair removed with inserted, in order.
            var gone: [Line] = []
            while oi < old.count, removed.contains(oi) { gone.append(old[oi]); oi += 1 }
            var fresh: [String] = []
            while ni < newTexts.count, inserted.contains(ni) { fresh.append(newTexts[ni]); ni += 1 }
            let pairs = pair(gone.map(\.text), fresh)
            for (k, t) in fresh.enumerated() {
                if let g = pairs[k] {
                    var line = gone[g]
                    line.text = t
                    if line.seconds == nil, !t.trimmingCharacters(in: .whitespaces).isEmpty { line.seconds = now }
                    out.append(line)
                } else {
                    out.append(Line(text: t, seconds: t.trimmingCharacters(in: .whitespaces).isEmpty ? nil : now))
                }
            }
            if ni < newTexts.count, oi < old.count {
                // An unchanged line.
                out.append(old[oi])
                oi += 1
                ni += 1
            } else if ni < newTexts.count {
                // Defensive: the diff and the walk disagree; treat the rest as new.
                let t = newTexts[ni]
                out.append(Line(text: t, seconds: t.trimmingCharacters(in: .whitespaces).isEmpty ? nil : now))
                ni += 1
            }
        }
        return out
    }

    /// Which removed line each inserted line is an edit of (inserted index → removed
    /// index), keeping order: one-for-one runs pair up directly (typing into a line);
    /// otherwise a line pairs with the removed one it shares the longest common prefix
    /// or suffix with, so a line typed above another doesn't steal its time.
    static func pair(_ gone: [String], _ fresh: [String]) -> [Int: Int] {
        if gone.count == fresh.count { return Dictionary(uniqueKeysWithValues: fresh.indices.map { ($0, $0) }) }
        func score(_ a: String, _ b: String) -> Int {
            let p = zip(a, b).prefix { $0 == $1 }.count
            let s = zip(a.reversed(), b.reversed()).prefix { $0 == $1 }.count
            return min(max(p, s), min(a.count, b.count))
        }
        var out: [Int: Int] = [:]
        var nextFresh = 0
        for (g, text) in gone.enumerated() {
            var best: (index: Int, score: Int)?
            for f in nextFresh..<fresh.count {
                let sc = score(text, fresh[f])
                if sc > 0, sc > (best?.score ?? 0) { best = (f, sc) }
            }
            if let best { out[best.index] = g; nextFresh = best.index + 1 }
        }
        return out
    }

    /// The persisted notes: non-empty lines (and stamped marker lines), cleaned, with
    /// an explicit `[mm:ss]` prefix taking precedence over the typing time.
    static func notes(from lines: [Line]) -> [MeetingNote] {
        lines.compactMap { line in
            let (stamp, rest) = parseStamp(line.text)
            let text = MeetingNote.clean(rest)
            if text.isEmpty && stamp == nil { return nil }
            return MeetingNote(id: line.id, text: text, secondsIntoMeeting: stamp ?? line.seconds)
        }
    }

    /// Lines for an editor seeded from existing notes (re-opening the page mid-meeting).
    static func lines(text: String, notes: [MeetingNote]) -> [Line] {
        let texts = text.components(separatedBy: "\n")
        var pool = notes
        return texts.map { t in
            let cleaned = MeetingNote.clean(parseStamp(t).rest)
            if let i = pool.firstIndex(where: { $0.text == cleaned }) {
                let n = pool.remove(at: i)
                return Line(id: n.id, text: t, seconds: n.secondsIntoMeeting)
            }
            return Line(text: t, seconds: nil)
        }
    }

    /// `[12:34] rest` / `[1:02:03] rest` → (seconds, rest). No stamp → (nil, line).
    static func parseStamp(_ line: String) -> (seconds: Double?, rest: String) {
        let t = Substring(line).drop(while: { $0 == " " })
        guard t.hasPrefix("["), let close = t.firstIndex(of: "]") else { return (nil, line) }
        let inner = t[t.index(after: t.startIndex)..<close]
        let parts = inner.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return (nil, line) }
        let nums = parts.compactMap { Double($0) }
        guard nums.count == parts.count else { return (nil, line) }
        let seconds = nums.reduce(0) { $0 * 60 + $1 }
        return (seconds, String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespaces))
    }

    /// The line "Mark this moment" appends.
    static func markerLine(at seconds: Double) -> String {
        "[\(MeetingTranscriptRenderer.timecode(seconds))] "
    }

    /// The editor text with a marker line appended (on its own line).
    static func appendingMarker(to text: String, at seconds: Double) -> String {
        let marker = markerLine(at: seconds)
        if text.isEmpty { return marker }
        return text.hasSuffix("\n") ? text + marker : text + "\n" + marker
    }

    /// Final reconcile at stop: every non-empty line has a time (a line typed but never
    /// stamped gets `now`).
    static func finalNotes(lines: [Line], text: String, now: Double) -> [MeetingNote] {
        notes(from: restamp(lines, text: text, now: now))
    }
}

/// Where each note goes as a hint: the summary chunk around the note's moment.
enum NoteHints {
    /// People write a note a little after what it is about.
    static let lagSeconds: Double = 10

    /// Chunk index → the notes whose moment falls in that chunk. A note is placed in
    /// the chunk whose time range contains `moment - lagSeconds`, else the last chunk
    /// starting before it, else the first chunk. Notes without a time get no hint
    /// (they still appear in the notes section).
    static func assign(_ notes: [MeetingNote], chunks: [[SummaryUnit]]) -> [Int: [MeetingNote]] {
        var out: [Int: [MeetingNote]] = [:]
        let ranges: [(start: Double, end: Double)?] = chunks.map { c in
            let starts = c.compactMap(\.start)
            guard let s = starts.min() else { return nil }
            let e = c.compactMap { $0.end ?? $0.start }.max() ?? s
            return (s, e)
        }
        guard ranges.contains(where: { $0 != nil }) else { return out }
        for note in notes {
            guard let t = note.secondsIntoMeeting else { continue }
            let target = max(0, t - lagSeconds)
            var pick: Int?
            for (i, r) in ranges.enumerated() {
                if let r, r.start <= target, target <= r.end { pick = i; break }
            }
            if pick == nil {
                pick = ranges.indices.last(where: { ranges[$0].map { $0.start <= target } ?? false })
            }
            if pick == nil { pick = ranges.firstIndex(where: { $0 != nil }) }
            if let p = pick { out[p, default: []].append(note) }
        }
        return out
    }
}
