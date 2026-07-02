// Renders a transcript + its timed segments into the CLI's output formats:
// plain text, Markdown, SRT, WebVTT, and JSON. The timestamps come from the
// recognizer (FileTranscriber.TimedSegment, i.e. SpeechTranscriber.Result.range),
// so cues reflect what was actually recognized — nothing is fabricated.
//
// Cue-time hygiene: SRT/VTT players expect start < end and non-decreasing starts.
// The recognizer's ranges are already ordered and non-overlapping, but we defend
// against a zero-length or out-of-order range so the emitted file is always valid
// (monotonic cue times), rather than trusting the input blindly.

import Foundation
import TalkieFileKit

enum OutputFormats {

    // MARK: Plain text

    /// Just the transcript. When there are timed segments we join them (one line
    /// per cue reads better than a wall of text); otherwise we print the transcript
    /// as-is. Either way it's the recognized words, nothing added.
    static func plainText(transcript: String, segments: [TimedSegment]) -> String {
        guard !segments.isEmpty else { return transcript }
        return segments.map(\.text).joined(separator: "\n")
    }

    // MARK: Markdown

    static func markdown(transcript: String, segments: [TimedSegment]) -> String {
        guard !segments.isEmpty else {
            return "# Transcript\n\n\(transcript)\n"
        }
        var out = "# Transcript\n\n"
        for cue in normalizedCues(segments) {
            let stamp = "\(clock(cue.start, millisSeparator: ".")) – \(clock(cue.end, millisSeparator: "."))"
            out += "**[\(stamp)]** \(cue.text)\n\n"
        }
        return out
    }

    // MARK: SRT (SubRip)

    static func srt(segments: [TimedSegment]) -> String {
        let cues = normalizedCues(segments)
        guard !cues.isEmpty else { return "" }
        var out = ""
        for (i, cue) in cues.enumerated() {
            out += "\(i + 1)\n"
            out += "\(srtTimestamp(cue.start)) --> \(srtTimestamp(cue.end))\n"
            out += "\(cue.text)\n\n"
        }
        return out
    }

    // MARK: WebVTT

    static func vtt(segments: [TimedSegment]) -> String {
        let cues = normalizedCues(segments)
        var out = "WEBVTT\n\n"
        for cue in cues {
            out += "\(vttTimestamp(cue.start)) --> \(vttTimestamp(cue.end))\n"
            out += "\(cue.text)\n\n"
        }
        return out
    }

    // MARK: JSON

    /// `{ "text": "...", "segments": [ { "start": s, "end": s, "text": "..." } ] }`.
    /// Hand-serialized via JSONSerialization (Foundation, no dependency) with
    /// sorted keys so the output is stable/diffable. Times are seconds (Double).
    static func json(transcript: String, segments: [TimedSegment]) -> String {
        let cues = normalizedCues(segments)
        let segmentObjects: [[String: Any]] = cues.map {
            ["start": $0.start, "end": $0.end, "text": $0.text]
        }
        let root: [String: Any] = ["text": transcript, "segments": segmentObjects]
        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let str = String(data: data, encoding: .utf8) else {
            // Extremely unlikely (all values are JSON-safe); degrade to text.
            return transcript
        }
        return str
    }

    // MARK: - Cue normalization

    /// A cleaned cue with guaranteed start < end and non-decreasing starts.
    struct Cue {
        let start: Double
        let end: Double
        let text: String
    }

    /// Enforce monotonic, non-degenerate cue times. Walks the segments in order,
    /// clamping each start to be ≥ the previous cue's start and giving any cue with
    /// non-positive duration a tiny 1 ms floor so subtitle players don't reject it.
    private static func normalizedCues(_ segments: [TimedSegment]) -> [Cue] {
        var cues: [Cue] = []
        var lastStart = 0.0
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = max(seg.startSeconds, lastStart)
            let minEnd = start + 0.001
            let end = max(seg.endSeconds, minEnd)
            cues.append(Cue(start: start, end: end, text: text))
            lastStart = start
        }
        return cues
    }

    // MARK: - Timestamp formatting

    /// `HH:MM:SS,mmm` — SRT's comma decimal separator.
    static func srtTimestamp(_ seconds: Double) -> String { clock(seconds, millisSeparator: ",") }
    /// `HH:MM:SS.mmm` — WebVTT's period decimal separator.
    static func vttTimestamp(_ seconds: Double) -> String { clock(seconds, millisSeparator: ".") }

    private static func clock(_ seconds: Double, millisSeparator: String) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = Int(total) % 60
        let millis = Int((total - Double(Int(total))) * 1000).clampedTo(0...999)
        return String(format: "%02d:%02d:%02d\(millisSeparator)%03d", hours, minutes, secs, millis)
    }
}

private extension Int {
    func clampedTo(_ range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
