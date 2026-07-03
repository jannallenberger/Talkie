import XCTest
@testable import Talkie

/// D3 — the timed-transcript export renderers (`TimedTranscriptExport`). These are
/// the whole verifiable surface of the package: a headless agent can't do the
/// maker's QuickTime sync spot-check, so the renderers are covered exhaustively
/// here — format shape (SRT comma vs VTT dot timecodes, `WEBVTT` header, CSV
/// header row), the cue-repair guarantees (sort, clamp, inverted/zero-length →
/// minimum span), RFC-4180 quoting of commas/quotes/newlines, unicode
/// round-tripping, and the two-speaker vs solo tagging switch.
final class TimedTranscriptRendererTests: XCTestCase {

    // A convenience so tests read as (start, end, speaker, text).
    private func seg(_ start: Double, _ end: Double, _ speaker: String, _ text: String) -> MeetingSegment {
        MeetingSegment(speaker: speaker, start: start, end: end, text: text)
    }

    private let header = TimedTranscriptExport.Header(
        title: "Weekly Sync",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        durationSec: 92.5
    )

    // MARK: - Empty input

    func testEmptyListProducesEmptyOrHeaderOnlyOutput() {
        XCTAssertEqual(TimedTranscriptExport.srt([]), "",
                       "an empty segment list must render no SRT cues at all")
        // VTT still carries its mandatory signature line even with no cues.
        XCTAssertEqual(TimedTranscriptExport.vtt([]), "WEBVTT\n",
                       "empty VTT must still be a valid file: just the WEBVTT header")
        // CSV keeps its header row so an empty export opens as a valid, headed sheet.
        XCTAssertEqual(TimedTranscriptExport.csv([]), "start,end,speaker,text\r\n",
                       "empty CSV must still emit the RFC-4180 header row")

        let json = TimedTranscriptExport.json([], header: header)
        XCTAssertTrue(json.contains("\"segments\" : [") || json.contains("\"segments\" : []"),
                      "empty JSON must still carry an (empty) segments array:\n\(json)")
        XCTAssertTrue(json.contains("\"title\" : \"Weekly Sync\""),
                      "JSON header title must be present even with no segments:\n\(json)")
    }

    // MARK: - Single segment

    func testSingleSegmentSrtIsWellFormed() {
        let out = TimedTranscriptExport.srt([seg(0, 2.5, "Me", "Hello there")])
        XCTAssertEqual(out, """
        1
        00:00:00,000 --> 00:00:02,500
        Hello there

        """, "single-segment SRT must be a 1-indexed cue with comma-millisecond timecodes and a trailing newline")
    }

    func testSingleSpeakerCarriesNoSpeakerPrefixOrVoiceSpan() {
        // Solo/imported recording (one distinct label) → no `Me:` prefix, no `<v>`.
        let segs = [seg(0, 1, "Me", "one"), seg(1, 2, "Me", "two")]
        let srt = TimedTranscriptExport.srt(segs)
        XCTAssertFalse(srt.contains("Me:"),
                       "a single-speaker SRT must NOT prefix speaker labels:\n\(srt)")
        let vtt = TimedTranscriptExport.vtt(segs)
        XCTAssertFalse(vtt.contains("<v "),
                       "a single-speaker VTT must NOT use voice spans:\n\(vtt)")
        XCTAssertTrue(vtt.contains("\none\n") && vtt.contains("\ntwo\n"),
                      "single-speaker VTT should carry the bare cue text:\n\(vtt)")
    }

    // MARK: - Two-speaker tagging

    func testTwoSpeakerSrtPrefixesLabels() {
        let segs = [seg(0, 1, "Me", "hi"), seg(1, 2, "Them", "hello")]
        let srt = TimedTranscriptExport.srt(segs)
        XCTAssertTrue(srt.contains("Me: hi"),
                      "two-speaker SRT must prefix the speaker label:\n\(srt)")
        XCTAssertTrue(srt.contains("Them: hello"),
                      "two-speaker SRT must prefix the far-end label:\n\(srt)")
    }

    func testTwoSpeakerVttUsesVoiceSpans() {
        let segs = [seg(0, 1, "Me", "hi"), seg(1, 2, "Them", "hello")]
        let vtt = TimedTranscriptExport.vtt(segs)
        XCTAssertTrue(vtt.contains("<v Me>hi</v>"),
                      "two-speaker VTT must wrap the near end in a voice span:\n\(vtt)")
        XCTAssertTrue(vtt.contains("<v Them>hello</v>"),
                      "two-speaker VTT must wrap the far end in a voice span:\n\(vtt)")
    }

    // MARK: - Cue repair

    func testOverlappingCuesAreSortedAndClampedForward() {
        // Fed OUT of order and overlapping: the later-start cue comes first in the
        // array, and its own start precedes the first cue's end.
        let segs = [seg(5, 4, "Me", "b"),   // inverted end (4 < 5)
                    seg(0, 6, "Me", "a")]   // overlaps the next start
        let cues = TimedTranscriptExport.repaired(segs)
        XCTAssertEqual(cues.map(\.text), ["a", "b"],
                       "repair must sort cues by start time")
        // Monotonic non-decreasing starts.
        XCTAssertLessThanOrEqual(cues[0].start, cues[1].start,
                                 "starts must not go backwards after repair")
        // The inverted cue's end was pushed to start + minimum.
        XCTAssertGreaterThan(cues[1].end, cues[1].start,
                             "an inverted cue must be repaired so end > start")
        XCTAssertEqual(cues[1].end, cues[1].start + TimedTranscriptExport.minimumCueSeconds, accuracy: 1e-9,
                       "an inverted end must become start + the minimum cue length")
    }

    func testZeroLengthCueGetsMinimumDuration() {
        let cues = TimedTranscriptExport.repaired([seg(3, 3, "Me", "blip")])
        XCTAssertEqual(cues[0].start, 3, accuracy: 1e-9)
        XCTAssertEqual(cues[0].end, 3 + TimedTranscriptExport.minimumCueSeconds, accuracy: 1e-9,
                       "a zero-length cue must be stretched to the minimum visible duration")
    }

    func testNonFiniteAndNegativeValuesAreSanitized() {
        let segs = [seg(-2, .nan, "Me", "neg"),
                    seg(.infinity, .infinity, "Me", "inf")]
        let cues = TimedTranscriptExport.repaired(segs)
        for cue in cues {
            XCTAssertTrue(cue.start.isFinite && cue.start >= 0,
                          "every repaired start must be finite and non-negative")
            XCTAssertTrue(cue.end.isFinite && cue.end > cue.start,
                          "every repaired end must be finite and strictly after start")
        }
        // And the timecodes over those repaired values are well-formed digits, never
        // "nan"/"inf". (We check the timecode lines specifically — the transcript text
        // here is deliberately "neg"/"inf", so a naive whole-file substring check would
        // false-positive on the content.) A well-formed SRT time line matches
        // HH:MM:SS,mmm exactly.
        let srt = TimedTranscriptExport.srt(segs)
        let timeLinePattern = #"^\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3}$"#
        let timeLines = srt.components(separatedBy: "\n").filter { $0.contains(" --> ") }
        XCTAssertFalse(timeLines.isEmpty, "expected at least one timecode line:\n\(srt)")
        for line in timeLines {
            XCTAssertNotNil(line.range(of: timeLinePattern, options: .regularExpression),
                            "timecode line was not well-formed HH:MM:SS,mmm: \(line)")
        }
    }

    // MARK: - Timecode formatting

    func testTimecodeFormatsDifferBetweenSrtAndVtt() {
        // SRT uses a comma before millis; VTT uses a dot. Same instant.
        XCTAssertEqual(TimedTranscriptExport.srtTimecode(3661.234), "01:01:01,234",
                       "SRT timecode must be HH:MM:SS,mmm past an hour")
        XCTAssertEqual(TimedTranscriptExport.vttTimecode(3661.234), "01:01:01.234",
                       "VTT timecode must be HH:MM:SS.mmm past an hour")
    }

    func testTimecodeRoundsToNearestMillisecond() {
        // 1.9999s is 2000ms after rounding, not 1999ms.
        XCTAssertEqual(TimedTranscriptExport.srtTimecode(1.9999), "00:00:02,000",
                       "sub-millisecond values must round to the nearest ms")
        XCTAssertEqual(TimedTranscriptExport.vttTimecode(0), "00:00:00.000",
                       "zero must render as the origin timecode")
    }

    // MARK: - CSV / RFC-4180

    func testCsvHeaderAndRowShape() {
        let csv = TimedTranscriptExport.csv([seg(0, 1.5, "Me", "plain text")])
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.first, "start,end,speaker,text",
                       "CSV must lead with the exact header row")
        XCTAssertEqual(lines[1], "0.000,1.500,Me,plain text",
                       "a comma/quote-free row must be emitted unquoted with 3-decimal seconds")
        XCTAssertTrue(csv.hasSuffix("\r\n"),
                      "CSV must terminate with a CRLF per RFC-4180")
    }

    func testCsvQuotesCommasQuotesAndNewlines() {
        let csv = TimedTranscriptExport.csv([
            seg(0, 1, "Me", "a, b, c"),                 // commas
            seg(1, 2, "Them", "she said \"hi\""),        // embedded quotes
            seg(2, 3, "Me", "line one\nline two"),       // embedded newline
        ])
        // Comma field is quoted, no inner escaping needed.
        XCTAssertTrue(csv.contains("\"a, b, c\""),
                      "a field with commas must be double-quoted:\n\(csv)")
        // Inner double-quotes are doubled per RFC-4180.
        XCTAssertTrue(csv.contains("\"she said \"\"hi\"\"\""),
                      "inner double-quotes must be doubled:\n\(csv)")
        // The embedded newline stays INSIDE a quoted field (the field opens with a
        // quote and the newline is not preceded by an unquoted record break).
        XCTAssertTrue(csv.contains("\"line one\nline two\""),
                      "an embedded newline must be wrapped in quotes, not split the record:\n\(csv)")
    }

    func testCsvFieldWithCommaRoundTripsAsSingleField() {
        // A minimal RFC-4180 reader: proves the quoted comma does NOT split a column.
        let csv = TimedTranscriptExport.csv([seg(0, 1, "Me", "one, two, three")])
        let dataRow = csv.components(separatedBy: "\r\n")[1]
        let parsed = Self.parseCsvRow(dataRow)
        XCTAssertEqual(parsed.count, 4,
                       "the row must parse back into exactly 4 fields despite the commas in text")
        XCTAssertEqual(parsed[3], "one, two, three",
                       "the text field must round-trip with its commas intact")
    }

    // MARK: - Unicode

    func testUnicodeSurvivesEveryFormat() {
        let text = "café — 日本語 — 🦜 emoji"
        let segs = [seg(0, 1, "Me", text)]
        XCTAssertTrue(TimedTranscriptExport.srt(segs).contains(text),
                      "SRT must pass unicode through verbatim")
        XCTAssertTrue(TimedTranscriptExport.vtt(segs).contains(text),
                      "VTT must pass unicode through verbatim (no metachars here to escape)")
        XCTAssertTrue(TimedTranscriptExport.csv(segs).contains(text),
                      "CSV must pass unicode through verbatim")
        let json = TimedTranscriptExport.json(segs, header: header)
        XCTAssertTrue(json.contains("café") && json.contains("🦜"),
                      "JSON must preserve unicode (not \\u-escape it into unreadability):\n\(json)")
    }

    // MARK: - VTT escaping

    func testVttEscapesAngleBracketsAndAmpersand() {
        let vtt = TimedTranscriptExport.vtt([seg(0, 1, "Me", "5 < 6 & 7 > 3")])
        XCTAssertTrue(vtt.contains("5 &lt; 6 &amp; 7 &gt; 3"),
                      "VTT must escape <, >, and & so speech can't be read as cue markup:\n\(vtt)")
        XCTAssertFalse(vtt.contains("6 & 7"),
                       "a raw ampersand must not survive into VTT output:\n\(vtt)")
    }

    // MARK: - JSON structure

    func testJsonCarriesHeaderAndSegmentObjects() throws {
        let segs = [seg(0, 1.25, "Me", "hello"), seg(1.25, 2, "Them", "hi")]
        let json = TimedTranscriptExport.json(segs, header: header)
        let data = Data(json.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let root = try XCTUnwrap(obj, "JSON must decode to an object")

        XCTAssertEqual(root["title"] as? String, "Weekly Sync")
        XCTAssertEqual(root["duration_sec"] as? Double, 92.5,
                       "the header duration must use the snake_case key `duration_sec`")
        XCTAssertNotNil(root["date"] as? String, "date must be an ISO-8601 string")

        let segments = try XCTUnwrap(root["segments"] as? [[String: Any]],
                                     "segments must be an array of objects")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0]["speaker"] as? String, "Me")
        XCTAssertEqual(segments[0]["text"] as? String, "hello")
        XCTAssertEqual(segments[0]["start"] as? Double, 0)
        XCTAssertEqual(segments[1]["end"] as? Double, 2)
    }

    func testJsonIsDeterministicAcrossRuns() {
        // Sorted keys + pretty printing → byte-identical on repeat, so diffs of an
        // exported file are meaningful.
        let segs = [seg(0, 1, "Me", "x")]
        let a = TimedTranscriptExport.json(segs, header: header)
        let b = TimedTranscriptExport.json(segs, header: header)
        XCTAssertEqual(a, b, "JSON export must be deterministic (sorted keys)")
    }

    // MARK: - Test helpers

    /// A deliberately small RFC-4180 single-row parser used only to prove the
    /// writer's quoting round-trips. Handles quoted fields, doubled inner quotes,
    /// and commas inside quotes. Not a general CSV parser.
    private static func parseCsvRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(row)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        current.append("\"")   // doubled quote → literal quote
                        i += 1
                    } else {
                        inQuotes = false       // closing quote
                    }
                } else {
                    current.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    fields.append(current)
                    current = ""
                } else {
                    current.append(c)
                }
            }
            i += 1
        }
        fields.append(current)
        return fields
    }
}
