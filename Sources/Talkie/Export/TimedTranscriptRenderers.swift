import Foundation

/// Dependency-free renderers that turn a meeting's timed `[MeetingSegment]`
/// (D2) into the four sidecar formats a MacWhisper-Pro user expects — SRT/VTT
/// subtitles and CSV/JSON data — with no model, no audio, no I/O and no
/// third-party library. Kept beside `NoteTemplate` as pure `static func`s so the
/// export menu (and any future producer) renders with the *same* rules and the
/// "zero dependencies" claim stays true.
///
/// Input contract, deliberately narrow: the renderers take `[MeetingSegment]`
/// and a tiny `Header` (title/date/duration), nothing else. Word-level cues,
/// chapter burn-in, and dictation-history export are explicitly out of scope for
/// v1 — when word-level timings arrive only the *producer* of the segment array
/// changes, not these functions (per the D3 spec's "design the input as
/// `[MeetingSegment]`" note).
///
/// Robustness is defensive on purpose: segment timings come from recognizer
/// finalization chunks, so a later segment can start a hair before an earlier
/// one's end, a cue can be zero-length, or a value can be non-finite. Every
/// renderer runs the segments through `repaired(_:)` first, which sorts by
/// start, clamps non-finite/negative values, and forces `end > start` (a
/// degenerate cue becomes `start + 0.5s`) so no player is handed an inverted or
/// zero-length cue.
enum TimedTranscriptExport {

    /// The per-file header carried into CSV/JSON output (SRT/VTT have no metadata
    /// slot). All fields are plain data — the `date` is rendered ISO-8601, never a
    /// link — so the on-device network gate stays satisfied.
    struct Header: Sendable, Equatable {
        var title: String
        var date: Date
        var durationSec: Double

        init(title: String, date: Date, durationSec: Double) {
            self.title = title
            self.date = date
            self.durationSec = durationSec
        }
    }

    /// The default duration a degenerate cue (`end <= start`, or a lone segment
    /// with no measurable span) is stretched to, so subtitles are visible and no
    /// player rejects a zero-length or inverted cue.
    static let minimumCueSeconds = 0.5

    // MARK: SRT

    /// SubRip (`.srt`). One cue per segment, 1-based index, `HH:MM:SS,mmm`
    /// timecodes. When the meeting has more than one distinct speaker the cue text
    /// is prefixed with the speaker label (`Me: …` / `Them: …`); a solo/imported
    /// recording carries no prefix. Blank-line separated, trailing newline — the
    /// shape QuickTime/IINA expect from a sidecar `.srt`.
    static func srt(_ segments: [MeetingSegment]) -> String {
        let cues = repaired(segments)
        guard !cues.isEmpty else { return "" }
        let tagged = hasMultipleSpeakers(cues)

        var blocks: [String] = []
        blocks.reserveCapacity(cues.count)
        for (i, cue) in cues.enumerated() {
            let text = tagged ? "\(cue.speaker): \(cue.text)" : cue.text
            blocks.append("""
            \(i + 1)
            \(srtTimecode(cue.start)) --> \(srtTimecode(cue.end))
            \(text)
            """)
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: VTT

    /// WebVTT (`.vtt`). Same one-cue-per-segment model with `HH:MM:SS.mmm`
    /// timecodes and the mandatory `WEBVTT` header. Two-speaker meetings use voice
    /// spans (`<v Me>…`) so a compliant player can style/attribute each speaker;
    /// solo recordings emit the bare line. Text is minimally escaped (`&`, `<`, `>`)
    /// so a literal angle bracket in speech can't be misread as markup.
    static func vtt(_ segments: [MeetingSegment]) -> String {
        let cues = repaired(segments)
        let tagged = hasMultipleSpeakers(cues)

        var out = "WEBVTT\n"
        for cue in cues {
            let escaped = vttEscape(cue.text)
            let body: String
            if tagged {
                // `<v Speaker>` is a voice span; the closing `</v>` is optional per
                // the spec but we emit it so downstream parsers that expect a close
                // tag stay happy.
                body = "<v \(vttEscape(cue.speaker))>\(escaped)</v>"
            } else {
                body = escaped
            }
            out += "\n\(vttTimecode(cue.start)) --> \(vttTimecode(cue.end))\n\(body)\n"
        }
        return out
    }

    // MARK: CSV

    /// RFC-4180 CSV with a `start,end,speaker,text` header row. `start`/`end` are
    /// seconds with millisecond precision (a stable, locale-independent decimal —
    /// always `.`), `speaker` is the raw label, `text` the cue. Every field is
    /// quoted when it contains a comma, a double-quote, or a newline, with inner
    /// quotes doubled (`"` → `""`) — so a transcript line with commas, quotes, or
    /// embedded newlines round-trips into Numbers/Excel intact. CRLF line endings,
    /// as the RFC specifies.
    static func csv(_ segments: [MeetingSegment]) -> String {
        let cues = repaired(segments)
        var rows: [String] = ["start,end,speaker,text"]
        rows.reserveCapacity(cues.count + 1)
        for cue in cues {
            let fields = [
                seconds(cue.start),
                seconds(cue.end),
                cue.speaker,
                cue.text,
            ].map(csvField)
            rows.append(fields.joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: JSON

    /// Pretty-printed JSON: a small header object (`title`, ISO-8601 `date`,
    /// `duration_sec`) plus a `segments` array of `{start,end,speaker,text}`
    /// objects. Encoded with sorted keys and pretty printing so the output is
    /// deterministic and diff-stable; `start`/`end` are the repaired numeric
    /// values. Never emits a URL, so the zero-network source gate is unaffected.
    static func json(_ segments: [MeetingSegment], header: Header) -> String {
        let cues = repaired(segments)
        // Built locally, not cached in a static: `ISO8601DateFormatter` isn't
        // `Sendable`, and the house pattern (Meeting.swift, NoteTemplate.swift)
        // constructs date formatters per call rather than sharing mutable global
        // state — one allocation on an explicit user-triggered export is free.
        let payload = ExportPayload(
            title: header.title,
            date: ISO8601DateFormatter().string(from: header.date),
            durationSec: header.durationSec,
            segments: cues.map {
                ExportPayload.Segment(start: $0.start, end: $0.end, speaker: $0.speaker, text: $0.text)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string + "\n"
    }

    // MARK: - Cue repair

    /// Sort by start and coerce every cue into a finite, forward-moving span:
    /// clamp non-finite/negative starts to a monotonically non-decreasing value,
    /// then force `end` to be at least `start + minimumCueSeconds` when the source
    /// gives an inverted, equal, or non-finite end. The result is safe for any
    /// subtitle player and stable to render. Text is passed through verbatim (the
    /// per-format escaping happens in each renderer).
    static func repaired(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        let sorted = segments.sorted { lhs, rhs in
            let l = lhs.start.isFinite ? lhs.start : .greatestFiniteMagnitude
            let r = rhs.start.isFinite ? rhs.start : .greatestFiniteMagnitude
            return l < r
        }
        var out: [MeetingSegment] = []
        out.reserveCapacity(sorted.count)
        var lastStart = 0.0
        for seg in sorted {
            var start = seg.start.isFinite ? max(0, seg.start) : lastStart
            start = max(start, lastStart)
            lastStart = start

            var end = seg.end
            if !end.isFinite || end <= start {
                end = start + minimumCueSeconds
            }
            out.append(MeetingSegment(speaker: seg.speaker, start: start, end: end, text: seg.text))
        }
        return out
    }

    /// True when the cues carry more than one distinct speaker label — the switch
    /// that turns on `Me:`/`Them:` prefixes (SRT) and `<v …>` spans (VTT). A solo
    /// or imported recording (one label, or none) renders untagged.
    private static func hasMultipleSpeakers(_ segments: [MeetingSegment]) -> Bool {
        var seen = Set<String>()
        for seg in segments {
            seen.insert(seg.speaker)
            if seen.count > 1 { return true }
        }
        return false
    }

    // MARK: - Formatting primitives

    /// `HH:MM:SS,mmm` (comma before milliseconds) — the SubRip timecode.
    static func srtTimecode(_ seconds: Double) -> String {
        clockComponents(seconds) { h, m, s, ms in
            String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
        }
    }

    /// `HH:MM:SS.mmm` (dot before milliseconds) — the WebVTT timecode.
    static func vttTimecode(_ seconds: Double) -> String {
        clockComponents(seconds) { h, m, s, ms in
            String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
        }
    }

    /// Split a second count into H/M/S/ms and format it. Rounds to the nearest
    /// millisecond (so 1.9999s reads 00:00:02.000, not …:01.999) and clamps
    /// negatives to zero — the timecode is always well-formed regardless of input.
    private static func clockComponents(_ seconds: Double,
                                        _ format: (Int, Int, Int, Int) -> String) -> String {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        let totalMillis = Int((clamped * 1000).rounded())
        let ms = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return format(h, m, s, ms)
    }

    /// A fixed-precision second value for CSV/data output: three decimals, always
    /// a `.` separator (locale-independent), no thousands grouping. Whole seconds
    /// still read `12.000` for column consistency.
    private static func seconds(_ value: Double) -> String {
        let clamped = value.isFinite ? max(0, value) : 0
        return String(format: "%.3f", clamped)
    }

    /// RFC-4180 field quoting: wrap in double-quotes and double any inner quote
    /// **only** when the field contains a comma, a double-quote, CR, or LF —
    /// leaving simple fields bare so the CSV stays readable. This is what makes a
    /// transcript line with `"a, b"` or an embedded newline survive a round-trip
    /// into a spreadsheet.
    private static func csvField(_ field: String) -> String {
        let mustQuote = field.contains(",")
            || field.contains("\"")
            || field.contains("\n")
            || field.contains("\r")
        guard mustQuote else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Minimal WebVTT text escaping: `&` first (so we don't double-escape the
    /// entities we introduce), then `<`/`>` so a literal angle bracket in speech
    /// can't be parsed as a cue tag.
    private static func vttEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Codable payload

    /// The JSON shape. A nested `Segment` mirrors `MeetingSegment` but is its own
    /// type so the on-disk export format is decoupled from the in-memory model —
    /// the exported key names (`duration_sec`) can differ from Swift's and won't
    /// drift if `MeetingSegment` gains fields.
    private struct ExportPayload: Encodable {
        var title: String
        var date: String
        var durationSec: Double
        var segments: [Segment]

        struct Segment: Encodable {
            var start: Double
            var end: Double
            var speaker: String
            var text: String
        }

        enum CodingKeys: String, CodingKey {
            case title
            case date
            case durationSec = "duration_sec"
            case segments
        }
    }
}
