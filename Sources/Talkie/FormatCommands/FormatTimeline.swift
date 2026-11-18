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

/// A run of dictated words that share one format (nil = normal text).
struct FormatRegion: Sendable, Equatable {
    var format: FormatPreset?
    var words: [FormatWord]
}

/// How one command span resolved.
enum FormatSpanResolution: Sendable, Equatable {
    case applied(FormatPreset)
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

    /// Split `words` into regions. `match` maps a span's text to a command (injected
    /// so tests can stub it; the live caller passes `FormatPhraseMatcher.match`).
    static func layout(words: [FormatWord], marks: [FormatMark],
                       match: (String) -> FormatCommand? = FormatPhraseMatcher.match) -> Layout {
        let sorted = marks.sorted { $0.effectiveTime < $1.effectiveTime }
        let spans: [(start: Double, end: Double)] = sorted.compactMap {
            if case .span(let s, let e) = $0 { return (s, e) } else { return nil }
        }
        func spanIndex(of w: FormatWord) -> Int? {
            spans.firstIndex { w.midpoint >= $0.start - spanLeadPadding && w.midpoint <= $0.end + spanTrailPadding }
        }

        // Command words per span; content words keep their order.
        var spanWords = [[FormatWord]](repeating: [], count: spans.count)
        var content: [FormatWord] = []
        for w in words {
            if let i = spanIndex(of: w) { spanWords[i].append(w) } else { content.append(w) }
        }

        // Resolve every mark into a timed format change. A span whose words are empty
        // behaves like a tap (held the key, said nothing → end). An unrecognised span
        // changes nothing (its words are still dropped — they were spoken as a command).
        var changes: [(time: Double, format: FormatPreset?)] = []
        var resolutions: [FormatSpanResolution] = []
        var spanNumber = 0
        for mark in sorted {
            switch mark {
            case .endTap(let at):
                changes.append((at, nil))
            case .span(_, let e):
                let spoken = Self.text(of: spanWords[spanNumber])
                spanNumber += 1
                if spoken.isEmpty {
                    resolutions.append(.ended)
                    changes.append((e, nil))
                } else if let command = match(spoken) {
                    switch command {
                    case .apply(let preset):
                        resolutions.append(.applied(preset))
                        changes.append((e, preset))
                    case .end:
                        resolutions.append(.ended)
                        changes.append((e, nil))
                    }
                } else {
                    resolutions.append(.notRecognised(spoken))
                }
            }
        }

        // Walk content words, applying every change whose time has passed. A new
        // format command always opens a new region (a second "bullet list" starts a
        // second list); normal text either side of an ended mode merges back.
        var regions: [FormatRegion] = []
        var current: FormatPreset? = nil
        var ci = 0
        for w in content {
            var changed = false
            while ci < changes.count, changes[ci].time <= w.midpoint {
                current = changes[ci].format
                changed = true
                ci += 1
            }
            if let last = regions.last, last.format == current, !(changed && current != nil) {
                regions[regions.count - 1].words.append(w)
            } else {
                regions.append(FormatRegion(format: current, words: [w]))
            }
        }
        return Layout(regions: regions, resolutions: resolutions)
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
