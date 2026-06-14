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
    }

    private let lock = NSLock()
    private var turns: [Turn] = []
    private let startedAt: Date

    init(startedAt: Date) { self.startedAt = startedAt }

    /// Stamp a finalized segment with the time it arrived and record it.
    func add(_ speaker: MeetingSpeaker, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        lock.withLock { turns.append(Turn(elapsed: elapsed, speaker: speaker, text: trimmed)) }
    }

    func snapshot() -> [Turn] {
        lock.withLock { turns }
    }

    var isEmpty: Bool {
        lock.withLock { turns.isEmpty }
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
    static func render(_ turns: [TurnLog.Turn]) -> String {
        let sorted = turns.sorted { $0.elapsed < $1.elapsed }
        guard !sorted.isEmpty else { return "" }

        let speakers = sorted.reduce(into: [MeetingSpeaker]()) { acc, turn in
            if !acc.contains(turn.speaker) { acc.append(turn.speaker) }
        }

        // Solo (only one side spoke) → plain joined transcript (Phase 1 output shape).
        if speakers.count <= 1 {
            return sorted.map(\.text).joined(separator: " ")
        }

        // Coalesce consecutive same-speaker turns, then label each block with the
        // timestamp of its first turn.
        var blocks: [(elapsed: TimeInterval, speaker: MeetingSpeaker, text: String)] = []
        for turn in sorted {
            if var last = blocks.last, last.speaker == turn.speaker {
                last.text += " " + turn.text
                blocks[blocks.count - 1] = last
            } else {
                blocks.append((turn.elapsed, turn.speaker, turn.text))
            }
        }

        let lines = blocks.map { "[\(timecode($0.elapsed))] \($0.speaker.rawValue): \($0.text)" }
        return lines.joined(separator: "\n")
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
