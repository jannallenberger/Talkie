import Foundation

/// One command-key event of a dictation, in AUDIO time (seconds from the session's
/// audio start — the recognizer's word-timing clock).
enum FormatMark: Sendable, Equatable {
    /// The command key was held from `start` to `end`: the words spoken inside are a
    /// format command, never dictated text.
    case span(start: Double, end: Double)
    /// A short tap at `at`: end the active format.
    case endTap(at: Double)

    var isSpan: Bool { if case .span = self { return true }; return false }

    /// Ordering time: a span takes effect when it ends; a tap when it happens.
    var effectiveTime: Double {
        switch self {
        case .span(_, let end): return end
        case .endTap(let at): return at
        }
    }
}

/// One recognised word with its audio time and the finalized segment it came from.
struct FormatWord: Sendable, Equatable {
    var text: String
    var start: Double
    var end: Double
    var segment: Int

    var midpoint: Double { (start + end) / 2 }
}

/// What a formatted region is pasted as: a built-in format or a user-made command.
enum FormatStyle: Sendable, Equatable {
    case preset(FormatPreset)
    case user(UserCommand)

    var displayName: String {
        switch self {
        case .preset(let p): return p.displayName
        case .user(let c): return c.name
        }
    }
}

/// A run of dictated words that share one format (nil = normal text). A user-made
/// fixed-text command is a region of its own with no words (its text is inserted).
struct FormatRegion: Sendable, Equatable {
    var style: FormatStyle?
    var words: [FormatWord]

    init(style: FormatStyle?, words: [FormatWord]) {
        self.style = style
        self.words = words
    }

    init(format: FormatPreset?, words: [FormatWord]) {
        self.init(style: format.map(FormatStyle.preset), words: words)
    }

    /// The built-in format, if this region has one.
    var format: FormatPreset? {
        if case .preset(let p)? = style { return p }
        return nil
    }
}

/// How one command span resolved.
enum FormatSpanResolution: Sendable, Equatable {
    case applied(FormatPreset)
    /// A user-made command now formats what follows.
    case appliedUser(UserCommand)
    /// A user-made fixed-text command inserted its text here.
    case inserted(UserCommand)
    case ended
    /// Words were said but none matched a preset — nothing changes.
    case notRecognised(String)
}

/// The pure span/region model: given the session's words (with timings) and its
/// command-key marks, decide which words are commands and which format every other
/// word is pasted in.
enum FormatTimeline {
    /// A word belongs to a span when its midpoint lies within the held interval,
    /// widened a little: the key clock and the recognizer clock are not identical
    /// (audio reaches the recognizer slightly after the key event), people start
    /// talking just as they press and release just after the last syllable.
    static let spanLeadPadding: Double = 0.25
    static let spanTrailPadding: Double = 0.25

    /// Flatten timed segments into words. Segments whose recognizer word timings are
    /// missing or don't reproduce the segment text get evenly interpolated word times
    /// across the segment span — coarse, but never loses a word.
    static func words(from segments: [TimedSegment]) -> [FormatWord] {
        var out: [FormatWord] = []
        for (index, seg) in segments.enumerated() {
            if let timed = SegmentWord.validated(seg.words, for: seg.text) {
                for w in timed where !w.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(FormatWord(text: w.text, start: w.start, end: w.end, segment: index))
                }
            } else {
                let tokens = seg.text.split(whereSeparator: \.isWhitespace).map(String.init)
                guard !tokens.isEmpty else { continue }
                let span = max(0, seg.end - seg.start)
                let step = span / Double(tokens.count)
                for (i, token) in tokens.enumerated() {
                    let s = seg.start + step * Double(i)
                    out.append(FormatWord(text: (i == 0 ? "" : " ") + token, start: s, end: s + step,
                                          segment: index))
                }
            }
        }
        return out
    }

    struct Layout: Sendable, Equatable {
        var regions: [FormatRegion]
        var resolutions: [FormatSpanResolution]
    }

    /// Split `words` into regions. `book` holds the phrases a span's text is matched
    /// against (the live phrase book by default; tests pass their own).
    ///
    /// - `fallback`: per span (in time order), the command to use when the span's
    ///   words here are empty or match nothing — e.g. after a stop-time language
    ///   re-transcription, the command recognised in the ORIGINAL transcript or by the
    ///   live preview at release.
    /// - `refineByPhrase`: the word times are only estimates (proportional fallback,
    ///   no recognizer timings). Each span's word range is then nudged by up to
    ///   `refineReach` words either way to the range that is exactly the command
    ///   phrase, so command words don't leak into the paste when the estimate is off.
    /// - `alternatives`: per span, other readings of the same audio (re-recognised in
    ///   the other enabled languages, or the original transcript's words). When there
    ///   are any, the best match across all readings decides
    ///   (`FormatPhraseMatcher.bestAcross`); with none, behaviour is unchanged.
    static func layout(words: [FormatWord], marks: [FormatMark],
                       book: FormatPhraseBook = .current,
                       fallback: (Int) -> FormatCommand? = { _ in nil },
                       alternatives: (Int) -> [String] = { _ in [] },
                       refineByPhrase: Bool = false) -> Layout {
        let sorted = marks.sorted { $0.effectiveTime < $1.effectiveTime }
        let spans: [(start: Double, end: Double)] = sorted.compactMap {
            if case .span(let s, let e) = $0 { return (s, e) } else { return nil }
        }

        // Which span (if any) owns each word.
        var owner: [Int?] = words.map { w in
            spans.firstIndex { w.midpoint >= $0.start - spanLeadPadding && w.midpoint <= $0.end + spanTrailPadding }
        }
        func ownedRange(_ n: Int) -> ClosedRange<Int>? {
            guard let a = owner.firstIndex(of: n), let b = owner.lastIndex(of: n) else { return nil }
            return a...b
        }
        func firstIndex(atOrAfter t: Double) -> Int {
            words.firstIndex { $0.midpoint >= t } ?? words.count
        }

        // Resolve each span's command: its own words first, then the fallback.
        var commands: [FormatCommand?] = []
        var spokenTexts: [String] = []
        for n in spans.indices {
            let spoken = ownedRange(n).map { text(of: Array(words[$0])) } ?? ""
            spokenTexts.append(spoken)
            let others = alternatives(n).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let resolved: FormatCommand?
            if others.isEmpty {
                resolved = spoken.isEmpty ? nil : FormatPhraseMatcher.match(spoken, book: book)
            } else {
                resolved = FormatPhraseMatcher.bestAcross([spoken] + others, book: book)
            }
            commands.append(resolved ?? fallback(n))
        }

        if refineByPhrase {
            for n in spans.indices {
                guard let expected = commands[n] else { continue }
                guard !words.isEmpty else { continue }
                let estimate = ownedRange(n) ?? {
                    let i = min(words.count - 1, firstIndex(atOrAfter: spans[n].start))
                    return i...i
                }()
                if let better = bestPhraseRange(in: words, around: estimate, owner: owner, span: n,
                                                expected: expected, book: book) {
                    for i in owner.indices where owner[i] == n { owner[i] = nil }
                    for i in better { owner[i] = n }
                    spokenTexts[n] = text(of: Array(words[better]))
                }
            }
        }

        // Each mark becomes a format change that takes effect from a word index on.
        var changes: [(index: Int, format: FormatStyle?)] = []
        var insertions: [(index: Int, command: UserCommand)] = []
        var resolutions: [FormatSpanResolution] = []
        var spanNumber = 0
        for mark in sorted {
            switch mark {
            case .endTap(let at):
                changes.append((firstIndex(atOrAfter: at), nil))
            case .span(_, let e):
                let n = spanNumber
                spanNumber += 1
                let from = refineByPhrase ? (ownedRange(n).map { $0.upperBound + 1 } ?? firstIndex(atOrAfter: e))
                                          : firstIndex(atOrAfter: e)
                switch commands[n] {
                case .apply(let preset)?:
                    resolutions.append(.applied(preset))
                    changes.append((from, .preset(preset)))
                case .user(let command)? where command.isInsertion:
                    resolutions.append(.inserted(command))
                    insertions.append((from, command))
                case .user(let command)?:
                    resolutions.append(.appliedUser(command))
                    changes.append((from, .user(command)))
                case .end?:
                    resolutions.append(.ended)
                    changes.append((from, nil))
                case nil:
                    if spokenTexts[n].isEmpty {
                        // Held the key and said nothing → end the format.
                        resolutions.append(.ended)
                        changes.append((from, nil))
                    } else {
                        // Words that match nothing change nothing (they're still dropped:
                        // they were spoken as a command).
                        resolutions.append(.notRecognised(spokenTexts[n]))
                    }
                }
            }
        }
        changes.sort { $0.index < $1.index }   // stable: same index keeps time order

        // Walk the content words in order. A new format command always opens a new
        // region (a second "bullet list" starts a second list); normal text either
        // side of an ended mode merges back.
        insertions.sort { $0.index < $1.index }   // stable, like `changes`
        var regions: [FormatRegion] = []
        var current: FormatStyle? = nil
        var ci = 0
        var ii = 0
        for (i, w) in words.enumerated() {
            var changed = false
            while ci < changes.count, changes[ci].index <= i {
                current = changes[ci].format
                changed = true
                ci += 1
            }
            guard owner[i] == nil else { continue }
            // A fixed text said before this word goes in here, without changing the format.
            while ii < insertions.count, insertions[ii].index <= i {
                regions.append(FormatRegion(style: .user(insertions[ii].command), words: []))
                ii += 1
                changed = true
            }
            if let last = regions.last, last.style == current, !(changed && current != nil) {
                regions[regions.count - 1].words.append(w)
            } else {
                regions.append(FormatRegion(style: current, words: [w]))
            }
        }
        while ii < insertions.count {
            regions.append(FormatRegion(style: .user(insertions[ii].command), words: []))
            ii += 1
        }
        return Layout(regions: regions, resolutions: resolutions)
    }

    /// How far (in words) `refineByPhrase` may move a span's edges.
    static let refineReach = 3

    /// The word range near `estimate` that is EXACTLY `expected`'s phrase (a whole-
    /// utterance match, not a word run inside it), closest to the estimate, preferring
    /// the longer range so carrier words ("in", "als") go too. Never takes words that
    /// belong to another span. Nil when no nearby range is the phrase.
    static func bestPhraseRange(in words: [FormatWord], around estimate: ClosedRange<Int>, owner: [Int?],
                                span n: Int, expected: FormatCommand,
                                book: FormatPhraseBook = .current) -> ClosedRange<Int>? {
        guard !words.isEmpty else { return nil }
        let lo = max(0, estimate.lowerBound - refineReach)
        let hi = min(words.count - 1, max(estimate.lowerBound, estimate.upperBound) + refineReach)
        guard lo <= hi else { return nil }
        var best: (range: ClosedRange<Int>, cost: Int)?
        for a in lo...hi {
            for b in a...min(hi, a + 5) {
                guard (a...b).allSatisfy({ owner[$0] == nil || owner[$0] == n }) else { continue }
                guard FormatPhraseMatcher.matchWhole(text(of: Array(words[a...b])), book: book) == expected else { continue }
                let cost = abs(a - estimate.lowerBound) + abs(b - estimate.upperBound)
                if best == nil || cost < best!.cost
                    || (cost == best!.cost && b - a > best!.range.count - 1) {
                    best = (a...b, cost)
                }
            }
        }
        return best?.range
    }

    /// Per span (time order): the span's audio interval and the words heard in it.
    static func spans(of marks: [FormatMark]) -> [(start: Double, end: Double)] {
        marks.sorted { $0.effectiveTime < $1.effectiveTime }.compactMap {
            if case .span(let s, let e) = $0 { return (s, e) } else { return nil }
        }
    }

    /// Per span (time order): the text `words` hold inside it ("" when none).
    static func spanTexts(words: [FormatWord], marks: [FormatMark]) -> [String] {
        spans(of: marks).map { span in
            text(of: words.filter { $0.midpoint >= span.start - spanLeadPadding && $0.midpoint <= span.end + spanTrailPadding })
        }
    }

    /// Per span (time order): the command its words match, or nil. Used to read the
    /// command from the ORIGINAL transcript as the fallback after a re-transcription.
    static func spanCommands(words: [FormatWord], marks: [FormatMark],
                             match: (String) -> FormatCommand? = { FormatPhraseMatcher.match($0) }) -> [FormatCommand?] {
        let spans: [(start: Double, end: Double)] = marks.sorted { $0.effectiveTime < $1.effectiveTime }.compactMap {
            if case .span(let s, let e) = $0 { return (s, e) } else { return nil }
        }
        return spans.map { span in
            let inside = words.filter { $0.midpoint >= span.start - spanLeadPadding && $0.midpoint <= span.end + spanTrailPadding }
            let spoken = text(of: inside)
            return spoken.isEmpty ? nil : match(spoken)
        }
    }

    /// Words for a transcript that has NO recognizer word timings (e.g. a
    /// re-transcription whose timings couldn't be read): each token gets the time of
    /// the reference word at the same relative position (so pauses in the original
    /// recording are kept), or an even spread over `duration` without a reference.
    static func proportionalWords(text: String, reference: [FormatWord], duration: Double) -> [FormatWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        return tokens.enumerated().map { k, token in
            let piece = (k == 0 ? "" : " ") + token
            if reference.isEmpty {
                let step = max(0, duration) / Double(tokens.count)
                return FormatWord(text: piece, start: step * Double(k), end: step * Double(k + 1), segment: 0)
            }
            let position = (Double(k) + 0.5) / Double(tokens.count) * Double(reference.count)
            let ref = reference[min(reference.count - 1, Int(position))]
            return FormatWord(text: piece, start: ref.start, end: ref.end, segment: 0)
        }
    }

    /// The segment-wise texts of a region's words, for the usual de-seaming.
    static func segmentTexts(of words: [FormatWord]) -> [String] {
        var out: [String] = []
        var lastSegment: Int?
        for w in words {
            if w.segment == lastSegment, !out.isEmpty {
                out[out.count - 1] += w.text
            } else {
                out.append(w.text)
                lastSegment = w.segment
            }
        }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The region's words as one string (recognizer punctuation kept).
    static func text(of words: [FormatWord]) -> String {
        words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pause-separated chunks of a region (gap ≥ `pause` between one word's end and
    /// the next word's start) — the list-item boundaries the speaker made.
    static let listPause: Double = 0.7

    static func pauseChunks(of words: [FormatWord], pause: Double = listPause) -> [String] {
        var chunks: [[FormatWord]] = []
        for w in words {
            if let prev = chunks.last?.last, w.start - prev.end < pause {
                chunks[chunks.count - 1].append(w)
            } else {
                chunks.append([w])
            }
        }
        return chunks.map(text(of:)).filter { !$0.isEmpty }
    }
}
