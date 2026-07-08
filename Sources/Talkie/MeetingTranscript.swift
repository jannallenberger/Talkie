import Foundation

/// Who said a turn. With two separate audio streams, the speaker is known for
/// free: the mic stream is always "Me", the far-end (system-audio tap) is "Them".
enum MeetingSpeaker: String, Sendable {
    case me = "Me"
    case them = "Them"
}

/// A thread-safe log of timestamped speaker turns. Each finalized transcript
/// segment is stamped with its arrival time (relative to the recording start) the
/// moment it lands, so the two streams can be interleaved chronologically without
/// parsing the recognizer's audio-time ranges. Appended on the transcriber's
/// actor; drained on the main thread.
final class TurnLog: @unchecked Sendable {
    struct Turn: Sendable {
        let elapsed: TimeInterval
        let speaker: MeetingSpeaker
        let text: String
        /// Audio-clock end of this turn (seconds), when the source carried a real
        /// span (the timed segment/import path). Nil for a wall-clock-stamped turn,
        /// whose duration is unknown. Used only to build `Meeting.segments`; the
        /// rendered transcript is unaffected.
        let endSec: TimeInterval?

        init(elapsed: TimeInterval, speaker: MeetingSpeaker, text: String, endSec: TimeInterval? = nil) {
            self.elapsed = elapsed
            self.speaker = speaker
            self.text = text
            self.endSec = endSec
        }
    }

    private let lock = NSLock()
    private var turns: [Turn] = []
    private let startedAt: Date

    /// Characters that, alone, make a segment content-free (the recognizer emits
    /// punctuation-only finalized segments during pauses → a run of bare commas).
    private static let punctuationAndSpace = CharacterSet(charactersIn: ",.!?;:—…\"'()[]{}- ")

    init(startedAt: Date) { self.startedAt = startedAt }

    /// Stamp a finalized segment with the time it arrived and record it. Drops
    /// punctuation-only artifacts so they don't render as "Okay, , , , ,".
    ///
    /// This uses **wall-clock arrival** time, which lags the true audio time by the
    /// finalization delay. Prefer the `at:end:` overload when the recognizer gives
    /// an audio-clock span — but a `TurnLog` must never mix the two clocks (that
    /// would corrupt cross-stream interleaving), so a single recording sticks to one.
    func add(_ speaker: MeetingSpeaker, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let depunctuated = trimmed.components(separatedBy: Self.punctuationAndSpace).joined()
        guard !depunctuated.isEmpty else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        lock.withLock { turns.append(Turn(elapsed: elapsed, speaker: speaker, text: trimmed)) }
    }

    /// Record a finalized segment stamped with its **audio-clock** span (seconds
    /// from session start ≈ recording start), instead of wall-clock arrival. Same
    /// punctuation-only drop as `add`. Used by the single-locale meeting streams and
    /// file import so `Meeting.segments` carries real per-segment timings, and so
    /// the interleaving is on the audio clock rather than lagged by finalization.
    func add(_ speaker: MeetingSpeaker, _ text: String, at start: TimeInterval, end: TimeInterval) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let depunctuated = trimmed.components(separatedBy: Self.punctuationAndSpace).joined()
        guard !depunctuated.isEmpty else { return }
        let s = max(0, start)
        let e = max(s, end)
        lock.withLock { turns.append(Turn(elapsed: s, speaker: speaker, text: trimmed, endSec: e)) }
    }

    func snapshot() -> [Turn] {
        lock.withLock { turns }
    }

    var isEmpty: Bool {
        lock.withLock { turns.isEmpty }
    }

    /// All turns for one speaker (drives per-stream language correction).
    func turns(for speaker: MeetingSpeaker) -> [Turn] {
        lock.withLock { turns.filter { $0.speaker == speaker } }
    }

    /// Replace all of one speaker's turns with a single block anchored at `elapsed`.
    /// Used when that stream was re-transcribed in another language — whole-stream
    /// re-transcription returns one untimed block, so we collapse the speaker's
    /// fine-grained turns into it (anchored at the first turn's time so cross-stream
    /// ordering survives).
    func replace(_ speaker: MeetingSpeaker, withSingleTurn text: String, at elapsed: TimeInterval) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            turns.removeAll { $0.speaker == speaker }
            if !trimmed.isEmpty { turns.append(Turn(elapsed: elapsed, speaker: speaker, text: trimmed)) }
        }
    }

    /// Replace a speaker's turns with language-routed spans from the multilingual
    /// merge — each span becomes a timed turn (`elapsed` is the span's audio start,
    /// `end` its audio end), so per-language segments, `Meeting.segments` timings,
    /// AND cross-stream interleaving all survive.
    func replace(_ speaker: MeetingSpeaker, withTimedTurns newTurns: [(elapsed: TimeInterval, text: String, end: TimeInterval)]) {
        lock.withLock {
            turns.removeAll { $0.speaker == speaker }
            for t in newTurns {
                let trimmed = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let s = max(0, t.elapsed)
                    turns.append(Turn(elapsed: s, speaker: speaker, text: trimmed, endSec: max(s, t.end)))
                }
            }
        }
    }
}

/// Renders a turn log into the meeting transcript body. (The participant list is
/// derived separately from the *capture* state, not from who happened to speak, so
/// a captured-but-silent far end is still reported honestly.)
enum MeetingTranscriptRenderer {
    /// When only one speaker is present (mic-only / solo recording, or a call where
    /// the far end stayed silent) the transcript is rendered plainly, exactly like
    /// Phase 1. When both sides spoke, it's interleaved and speaker-labeled:
    /// `[mm:ss] Me: …` / `[mm:ss] Them: …`, coalescing consecutive same-speaker
    /// turns into one line.
    static func render(_ turns: [TurnLog.Turn], duration: TimeInterval? = nil) -> String {
        let prepared = duration.map { decollapse(turns, duration: $0) } ?? turns
        let sorted = prepared.sorted { $0.elapsed < $1.elapsed }
        guard !sorted.isEmpty else { return "" }

        let speakers = sorted.reduce(into: [MeetingSpeaker]()) { acc, turn in
            if !acc.contains(turn.speaker) { acc.append(turn.speaker) }
        }

        // Solo (only one side spoke) → plain joined transcript (Phase 1 output shape).
        if speakers.count <= 1 {
            return sorted.map(\.text).joined(separator: " ")
        }

        // Coalesce consecutive same-speaker turns, then label each block with the
        // timestamp of its first turn. A block only grows while its turns stay within
        // `coalesceMaxGap` of each other — a larger jump (a long pause, or the spread
        // pieces a de-collapsed stall produces) starts a fresh line, so a 35-minute
        // stall can never render as one block again.
        var blocks: [(elapsed: TimeInterval, last: TimeInterval, speaker: MeetingSpeaker, text: String)] = []
        for turn in sorted {
            if var block = blocks.last, block.speaker == turn.speaker,
               turn.elapsed - block.last <= coalesceMaxGap {
                block.text += " " + turn.text
                block.last = turn.elapsed
                blocks[blocks.count - 1] = block
            } else {
                blocks.append((turn.elapsed, turn.elapsed, turn.speaker, turn.text))
            }
        }

        let lines = blocks.map { "[\(timecode($0.elapsed))] \($0.speaker.rawValue): \($0.text)" }
        return lines.joined(separator: "\n")
    }

    /// Build the persisted `[MeetingSegment]` from a turn-log snapshot: one segment
    /// per turn, in time order, with **finite, monotonically non-decreasing** start
    /// and end (the D2 acceptance guarantee). Each turn's `end` is its own audio-clock
    /// `endSec` when the source carried one, else the next turn's start, else its own
    /// start (a zero-length cue) — clamped so `end ≥ start` and starts never go
    /// backwards even if two streams' clocks interleave with a small skew. Returns nil
    /// when there is nothing timed to persist, so callers store `segments = nil` rather
    /// than an empty array (keeping the "no segments" and "pre-D2" cases identical).
    static func segments(from turns: [TurnLog.Turn], duration: TimeInterval? = nil) -> [MeetingSegment]? {
        let prepared = duration.map { decollapse(turns, duration: $0) } ?? turns
        let sorted = prepared.sorted { $0.elapsed < $1.elapsed }
        guard !sorted.isEmpty else { return nil }
        var out: [MeetingSegment] = []
        out.reserveCapacity(sorted.count)
        var lastStart = 0.0
        for (i, turn) in sorted.enumerated() {
            // Clamp start to finite and non-decreasing (skew between the two per-stream
            // audio clocks can otherwise put a later turn a hair before an earlier one).
            var start = turn.elapsed.isFinite ? max(0, turn.elapsed) : lastStart
            start = max(start, lastStart)
            lastStart = start
            // Prefer the turn's real audio end; otherwise bound it by the next turn's
            // start; otherwise it's a zero-length cue (we don't invent a duration).
            let nextStart = i + 1 < sorted.count ? sorted[i + 1].elapsed : nil
            var end = turn.endSec ?? nextStart ?? start
            if !end.isFinite { end = start }
            end = max(end, start)
            out.append(MeetingSegment(speaker: turn.speaker.rawValue, start: start, end: end, text: turn.text))
        }
        return out
    }

    // MARK: Stalled-recognizer safeguard (de-collapse)

    /// Natural speaking rate, used to estimate how long a collapsed run of speech
    /// really lasted when no later turn bounds it.
    static let assumedWordsPerSecond = 2.5
    /// A run of same-speaker turns whose whole time span is under this (seconds) is
    /// treated as sharing "one timestamp" — the fingerprint of a finalization stall.
    static let collapseSpanTolerance = 3.0
    /// Only re-time a frozen run once it carries more words than one instant of speech
    /// could (~a minute of talk), so ordinary fast back-and-forth is left untouched.
    static let collapseWordFloor = 150
    /// A frozen run is re-chunked into paragraph-sized pieces of about this many words
    /// each, so the output is uniform whether the stall produced one giant turn or many
    /// tiny merged spans, and each renders as its own timed line.
    static let decollapseChunkWords = 80
    /// `render` keeps consecutive same-speaker turns on one line only while they're
    /// within this many seconds of each other; a larger gap (a long pause, or the
    /// spread-apart pieces a de-collapsed stall produces) starts a new timed line.
    static let coalesceMaxGap = 12.0

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }

    /// Undo a stalled recognizer's timestamp collapse. When macOS's `SpeechAnalyzer`
    /// stops finalizing on a long stream (~30 min in), every later segment can arrive
    /// stamped at the last good audio time, so a whole speaker turn — up to tens of
    /// minutes — coalesces under ONE timecode (the "[29:52] Them: …4,872 words" bug).
    /// This detects such a frozen run (consecutive same-speaker turns that barely
    /// advance in time yet carry far more speech than one instant could) and spreads
    /// its timecodes across the real gap — up to the next turn, else the meeting
    /// `duration` — splitting a lone giant turn into word-chunks. The primary fix is
    /// analyzer rotation (which keeps this from ever triggering); this is the backstop
    /// so a stall can never again produce one unreadable block. Pure, and a no-op on a
    /// healthy transcript whose turns already carry distinct, advancing times.
    static func decollapse(_ turns: [TurnLog.Turn], duration: TimeInterval) -> [TurnLog.Turn] {
        let sorted = turns.sorted { $0.elapsed < $1.elapsed }
        guard !sorted.isEmpty else { return turns }
        var out: [TurnLog.Turn] = []
        var i = 0
        while i < sorted.count {
            // Grow a run of consecutive same-speaker turns whose times stay within the
            // tolerance of the run's start (i.e. effectively one frozen timestamp).
            let speaker = sorted[i].speaker
            let runStart = sorted[i].elapsed
            var j = i
            while j < sorted.count,
                  sorted[j].speaker == speaker,
                  sorted[j].elapsed - runStart < collapseSpanTolerance {
                j += 1
            }
            let run = Array(sorted[i..<j])
            let totalWords = run.reduce(0) { $0 + wordCount($1.text) }
            if totalWords >= collapseWordFloor {
                // Its true end: the next (different-speaker) turn if meaningfully later,
                // else an estimate from the word count, capped at the meeting end.
                let nextTime = j < sorted.count ? sorted[j].elapsed : duration
                let estimated = min(duration, runStart + Double(totalWords) / assumedWordsPerSecond)
                var runEnd = nextTime
                if runEnd - runStart < 1 { runEnd = estimated }
                runEnd = max(runEnd, runStart + 1)
                out.append(contentsOf: spread(run, from: runStart, to: runEnd, speaker: speaker))
            } else {
                out.append(contentsOf: run)
            }
            i = j
        }
        return out
    }

    /// Spread a frozen run's text evenly across `[start, end]`. The run's (collapsed,
    /// same-timecode) text is joined and re-chunked into paragraph-sized pieces so the
    /// output is uniform whether the stall produced one giant turn or many tiny merged
    /// spans; each piece then gets an interpolated timecode. `render`'s gap-break turns
    /// them into separate lines.
    private static func spread(_ run: [TurnLog.Turn], from start: TimeInterval,
                               to end: TimeInterval, speaker: MeetingSpeaker) -> [TurnLog.Turn] {
        let span = max(0, end - start)
        let fullText = run.map(\.text).joined(separator: " ")
        let pieces = chunked(fullText, per: decollapseChunkWords)
        guard pieces.count > 1 else {
            return [TurnLog.Turn(elapsed: start, speaker: speaker, text: fullText, endSec: max(start, end))]
        }
        let words = pieces.map { max(1, wordCount($0)) }
        let wordsTotal = max(1, words.reduce(0, +))
        var out: [TurnLog.Turn] = []
        var cumulative = 0
        for (k, text) in pieces.enumerated() {
            let startFrac = Double(cumulative) / Double(wordsTotal)
            cumulative += words[k]
            let endFrac = Double(cumulative) / Double(wordsTotal)
            let s = start + span * startFrac
            let e = start + span * endFrac
            out.append(TurnLog.Turn(elapsed: s, speaker: speaker, text: text, endSec: max(s, e)))
        }
        return out
    }

    /// Split text into chunks of about `per` words, on word boundaries.
    private static func chunked(_ text: String, per: Int) -> [String] {
        let ws = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard ws.count > per else { return [text] }
        var chunks: [String] = []
        var idx = 0
        while idx < ws.count {
            let end = min(idx + per, ws.count)
            chunks.append(ws[idx..<end].joined(separator: " "))
            idx = end
        }
        return chunks
    }

    /// `mm:ss` (or `h:mm:ss` past an hour) for a relative offset.
    static func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
