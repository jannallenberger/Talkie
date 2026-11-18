import Foundation
import TalkieDiarization

/// One recognizer token with its audio time range, kept IN MEMORY from the recognizer
/// until speaker labelling (never persisted). `text` is the token's exact text including
/// any whitespace the recognizer put around it, so the tokens of a segment concatenate
/// to the segment's text and a piece of the segment is a plain concatenation.
///
/// `start`/`end` are in the same clock as the segment they belong to (the lane's
/// recognizer clock, with analyzer-rotation offsets already added), so word times and
/// the lane's diarization are directly comparable.
struct SegmentWord: Sendable, Equatable {
    var text: String
    var start: Double
    var end: Double

    init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }

    /// Tokens that reproduce `segmentText` (compared whitespace-normalised), with finite,
    /// non-decreasing times; else nil, so a segment whose words cannot be trusted keeps
    /// today's whole-segment majority label.
    static func validated(_ words: [SegmentWord]?, for segmentText: String) -> [SegmentWord]? {
        guard let words, !words.isEmpty else { return nil }
        var lastStart = -Double.infinity
        for w in words {
            guard w.start.isFinite, w.end.isFinite, w.end >= w.start, w.start >= lastStart else { return nil }
            lastStart = w.start
        }
        guard normalized(words.map(\.text).joined()) == normalized(segmentText) else { return nil }
        return words
    }

    static func normalized(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `text` of `words[range]` as one trimmed string.
    static func text(of words: ArraySlice<SegmentWord>) -> String {
        words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Pure logic that splits one transcript segment where the diarized speaker changes.
///
/// Inputs are the segment's words and one speaker per word (nil = unknown); the output is
/// the pieces to emit. Rules (every number is a named constant below):
///  1. A word with no speaker takes the speaker of the nearest labelled word (previous
///     first); a segment with no labelled word at all is one piece with no speaker.
///  2. Consecutive words by one speaker form a run.
///  3. ANTI-FLICKER. A run is a flicker when it is shorter than `minPieceSeconds` AND has
///     fewer than `minPieceWords` words. The smallest flicker is absorbed into its
///     neighbour (the longer of the two; the previous one on a tie) and the check repeats,
///     so an "A b A" island collapses into A. A run that is long OR wordy enough stays,
///     so a real one-sentence interjection ("ja, genau, das stimmt so") keeps its label.
///  4. Adjacent runs of the same speaker are merged.
enum SegmentSplitter {
    /// Shorter than this AND fewer than `minPieceWords`: a flicker. 0.8 s is about two
    /// average German words; diarizer turn edges jitter by a few tenths of a second, so
    /// anything below that is as likely boundary noise as a real change of speaker.
    static let minPieceSeconds = 0.8
    /// See `minPieceSeconds`. A run of 3+ words is a sentence fragment, not noise.
    static let minPieceWords = 3

    struct Piece: Equatable {
        /// Half-open word index range within the segment.
        var words: Range<Int>
        var speaker: Int?
    }

    static func split(words: [SegmentWord], speakers rawSpeakers: [Int?]) -> [Piece] {
        let n = words.count
        guard n > 0, rawSpeakers.count == n else { return [] }
        guard rawSpeakers.contains(where: { $0 != nil }) else { return [Piece(words: 0..<n, speaker: nil)] }

        // 1. Fill unknown words: previous labelled word, else the next one.
        var spk = rawSpeakers
        var last: Int?
        for i in 0..<n { if let s = spk[i] { last = s } else { spk[i] = last } }
        var next: Int?
        for i in stride(from: n - 1, through: 0, by: -1) { if let s = spk[i] { next = s } else { spk[i] = next } }

        // 2. Runs.
        var runs: [Piece] = []
        for i in 0..<n {
            if let l = runs.last, l.speaker == spk[i] { runs[runs.count - 1].words = l.words.lowerBound..<(i + 1) }
            else { runs.append(Piece(words: i..<(i + 1), speaker: spk[i])) }
        }

        func seconds(_ r: Range<Int>) -> Double { max(0, words[r.upperBound - 1].end - words[r.lowerBound].start) }
        func isFlicker(_ p: Piece) -> Bool { seconds(p.words) < minPieceSeconds && p.words.count < minPieceWords }

        // 3. Absorb the smallest flicker into its neighbour until none is left.
        while runs.count > 1 {
            var pick: Int?
            var pickSize = Double.infinity
            for (i, r) in runs.enumerated() where isFlicker(r) {
                let size = seconds(r.words)
                if size < pickSize { pick = i; pickSize = size }
            }
            guard let i = pick else { break }
            let into: Int
            if i == 0 { into = 1 }
            else if i == runs.count - 1 { into = i - 1 }
            else { into = seconds(runs[i + 1].words) > seconds(runs[i - 1].words) ? i + 1 : i - 1 }
            let lo = min(i, into), hi = max(i, into)
            runs[into].words = runs[lo].words.lowerBound..<runs[hi].words.upperBound
            runs.remove(at: i)
            // 4. Merge neighbours that now share a speaker.
            var k = 1
            while k < runs.count {
                if runs[k].speaker == runs[k - 1].speaker {
                    runs[k - 1].words = runs[k - 1].words.lowerBound..<runs[k].words.upperBound
                    runs.remove(at: k)
                } else { k += 1 }
            }
        }
        return runs
    }
}

/// Per-word speaker lookup against one lane's diarization turns.
struct WordSpeakerIndex {
    private let turns: [DiarizedTurn]
    private let prefixMaxEnd: [Double]
    /// A word in no turn is attached to the nearest turn only if it is this close (s).
    static let nearestTurnSlack = 0.5

    init(turns: [DiarizedTurn]) {
        let sorted = turns.sorted { $0.start < $1.start }
        self.turns = sorted
        var m = -Double.infinity
        self.prefixMaxEnd = sorted.map { m = max(m, $0.end); return m }
    }

    /// The speaker with the most overlap with [start, end]; else the nearest turn within
    /// `nearestTurnSlack`; else nil. Ties go to the lower speaker index.
    func speaker(start: Double, end: Double) -> Int? {
        guard !turns.isEmpty else { return nil }
        let e = max(end, start)
        // First turn that can still reach `start`.
        var lo = 0, hi = turns.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if prefixMaxEnd[mid] > start { hi = mid } else { lo = mid + 1 }
        }
        var total: [Int: Double] = [:]
        var i = lo
        while i < turns.count, turns[i].start <= e {
            let t = turns[i]
            if e > start {
                let o = min(e, t.end) - max(start, t.start)
                if o > 0 { total[t.speaker, default: 0] += o }
            } else if t.start <= start && start < t.end {
                total[t.speaker, default: 0] = 1
            }
            i += 1
        }
        if let best = total.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) { return best.key }
        // Nearest turn: the one ending just before, or starting just after.
        let mid = (start + e) / 2
        var best: (gap: Double, speaker: Int)?
        let from = max(0, lo - 1)
        for j in from..<min(turns.count, from + 3) {
            let t = turns[j]
            let gap = mid < t.start ? t.start - mid : (mid > t.end ? mid - t.end : 0)
            if best == nil || gap < best!.gap { best = (gap, t.speaker) }
        }
        if let best, best.gap <= Self.nearestTurnSlack { return best.speaker }
        return nil
    }
}
