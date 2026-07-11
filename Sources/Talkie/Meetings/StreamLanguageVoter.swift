import Foundation

/// Merges the timed, confidence-scored *words* produced by several per-language
/// recognizers running over the *same* audio into one transcript — routing each
/// word to the language whose model was most confident about it.
///
/// macOS decodes audio with one language model per analyzer, so a bilingual
/// speaker is gibberish in any single language. We run one recognizer per spoken
/// language and vote per time slice: a German word scores high in the German lane
/// and low in the English lane (and vice-versa), so even a single English word
/// dropped into a German sentence is kept in English. Voting is per-frame (not
/// per-word-boundary) because the lanes segment the same audio differently;
/// light smoothing suppresses single-frame flicker between languages.
enum StreamLanguageVoter {
    /// One recognizer's word: its text, the audio span it covers (seconds), and
    /// the recognizer's confidence in it.
    struct TimedWord: Equatable, Sendable {
        var localeID: String
        var text: String
        var start: Double
        var end: Double
        var confidence: Double
    }

    /// A resolved run of the merged transcript: a stretch of one language's words.
    /// `start`/`end` are the audio-clock span (seconds) of the run's first and last
    /// words, so callers can persist per-segment timings (`Meeting.segments`).
    struct Span: Equatable, Sendable {
        var localeID: String
        var text: String
        var start: Double
        var end: Double
    }

    /// Time-grid resolution (seconds) for the per-slice language vote.
    static let frame = 0.12
    /// Smoothing half-window (seconds): a frame's winner is the majority language
    /// over ±this, so one noisy frame can't flip the language for a single word.
    static let smoothingWindow = 0.30

    /// Merge per-lane words into language-coherent spans by voting the
    /// highest-confidence language per time frame. Each word is kept only if its
    /// own lane won at least half the frames it covers, so overlapping words from
    /// competing lanes don't both survive.
    static func mergeWords(
        _ words: [TimedWord],
        frame: Double = frame,
        smoothingWindow: Double = smoothingWindow
    ) -> [Span] {
        let valid = words.filter { $0.end > $0.start && !$0.text.isEmpty }
        guard !valid.isEmpty else { return [] }
        let t0 = valid.map(\.start).min() ?? 0
        let t1 = valid.map(\.end).max() ?? 0
        guard t1 > t0, frame > 0 else {
            if let best = valid.max(by: { $0.confidence < $1.confidence }) {
                return [Span(localeID: best.localeID, text: best.text, start: best.start, end: best.end)]
            }
            return []
        }

        let frameCount = max(1, Int(((t1 - t0) / frame).rounded(.up)))

        // 1. Raw winner per frame: the locale of the highest-confidence word
        //    covering the frame's midpoint. Computed via a time-ordered interval
        //    sweep rather than scanning every word for every frame: `valid` is
        //    sorted by start once, then as `mid` advances monotonically across
        //    frames, a cursor admits words whose start has been reached into a
        //    max-heap keyed by (confidence desc, original-index asc — the same
        //    tie-break the old linear scan's strict `>` gave: the first
        //    highest-confidence word in input order wins), while a lazy-deletion
        //    pass evicts words whose end has already passed. A heap's root is
        //    always the true max of whatever it currently holds, and only
        //    permanently-stale entries (their end can't un-pass) are ever
        //    discarded, so the root after eviction is exactly the highest-
        //    confidence word still covering `mid` — identical to the old scan's
        //    winner, but in O((frames + words) log words) instead of O(frames ×
        //    words).
        let byStart = valid.enumerated().sorted { $0.element.start < $1.element.start }
        var raw = [String?](repeating: nil, count: frameCount)
        var admitCursor = 0
        var active = WordHeap()
        for i in 0..<frameCount {
            let mid = t0 + (Double(i) + 0.5) * frame
            while admitCursor < byStart.count, byStart[admitCursor].element.start <= mid {
                active.push(index: byStart[admitCursor].offset, word: byStart[admitCursor].element)
                admitCursor += 1
            }
            while let top = active.top, top.end < mid {
                active.pop()
            }
            raw[i] = active.top?.localeID
        }

        // 2. Smooth: each frame's winner becomes the majority within ±window.
        let half = max(0, Int((smoothingWindow / frame).rounded()))
        var winner = raw
        if half > 0 {
            for i in 0..<frameCount {
                var counts: [String: Int] = [:]
                for j in max(0, i - half)...min(frameCount - 1, i + half) {
                    if let w = raw[j] { counts[w, default: 0] += 1 }
                }
                winner[i] = counts.max { $0.value < $1.value }?.key ?? raw[i]
            }
        }

        // 3. Keep each word iff its lane won ≥ half the frames it covers.
        func frameIndex(_ t: Double) -> Int { min(frameCount - 1, max(0, Int((t - t0) / frame))) }
        let kept = valid
            .filter { w in
                let lo = frameIndex(w.start)
                let hi = max(lo, frameIndex(w.end - 1e-6))
                var wins = 0
                let total = hi - lo + 1
                for k in lo...hi where winner[k] == w.localeID { wins += 1 }
                return total == 0 || Double(wins) / Double(total) >= 0.5
            }
            .sorted { $0.start < $1.start }

        // 4. Coalesce consecutive same-language words into spans, extending each
        //    span's `end` to its last word so the persisted segment covers the run.
        var spans: [Span] = []
        for w in kept {
            if var last = spans.last, code(last.localeID) == code(w.localeID) {
                last.text = joined(last.text, w.text)
                last.end = max(last.end, w.end)
                spans[spans.count - 1] = last
            } else {
                spans.append(Span(localeID: w.localeID, text: w.text, start: w.start, end: w.end))
            }
        }
        return spans
    }

    /// The whole merged transcript as one string (spans joined in time order).
    static func mergedText(_ words: [TimedWord]) -> String {
        mergeWords(words)
            .map(\.text)
            .reduce("") { joined($0, $1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - helpers

    /// Array-based max-heap of (original index, word) pairs, ordered by confidence
    /// (descending) and tie-broken by the smaller original index — matching the
    /// strict `>` compare the previous linear-scan `mergeWords` used (first
    /// highest-confidence word in the caller's order wins a tie). Used by
    /// `mergeWords`'s frame sweep for two operations: push a newly-admitted word,
    /// and drop the top once it's no longer active. That second operation is lazy
    /// deletion — a heap's root is always the true maximum of whatever it still
    /// holds, so repeatedly popping a stale (expired) root before reading `top`
    /// leaves exactly the maximum among the still-active entries.
    private struct WordHeap {
        private var items: [(index: Int, word: TimedWord)] = []

        var top: TimedWord? { items.first?.word }

        private func higherPriority(_ a: (index: Int, word: TimedWord), _ b: (index: Int, word: TimedWord)) -> Bool {
            if a.word.confidence != b.word.confidence { return a.word.confidence > b.word.confidence }
            return a.index < b.index
        }

        mutating func push(index: Int, word: TimedWord) {
            items.append((index, word))
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard higherPriority(items[i], items[parent]) else { break }
                items.swapAt(i, parent)
                i = parent
            }
        }

        /// Drop the current top (used only when it's been found stale/expired).
        mutating func pop() {
            guard !items.isEmpty else { return }
            items[0] = items[items.count - 1]
            items.removeLast()
            var i = 0
            while true {
                let l = 2 * i + 1, r = 2 * i + 2
                var largest = i
                if l < items.count, higherPriority(items[l], items[largest]) { largest = l }
                if r < items.count, higherPriority(items[r], items[largest]) { largest = r }
                guard largest != i else { break }
                items.swapAt(i, largest)
                i = largest
            }
        }
    }

    private static func code(_ id: String) -> String {
        Locale(identifier: id).language.languageCode?.identifier ?? id
    }

    private static func joined(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }
}
