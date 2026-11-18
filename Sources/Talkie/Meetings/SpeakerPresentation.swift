import Foundation

/// View-side presentation of speaker labels. Stored labels stay English and raw
/// ("Me", "Them", "Speaker 2") so exports, MCP output and the persisted meeting are
/// unaffected; only what the Meetings tab *displays* is localized here.
enum SpeakerPresentation {

    /// Number of accent slots in the palette (slot 0 is reserved for "Me").
    static let paletteSize = 6

    /// The localized display name for a stored label. "Speaker N" goes through a
    /// format string; "Me"/"Them" through the catalog; anything else is shown as stored.
    static func displayName(for label: String) -> String {
        if label == SpeakerLabels.me { return "Me".loc }
        if label == SpeakerLabels.them { return "Them".loc }
        if let n = speakerNumber(label) {
            return String(format: "Speaker %d".loc, n)
        }
        return label
    }

    /// N for a stored "Speaker N" label, else nil.
    static func speakerNumber(_ label: String) -> Int? {
        guard label.hasPrefix(SpeakerLabels.prefix) else { return nil }
        return Int(label.dropFirst(SpeakerLabels.prefix.count))
    }

    /// Colour slot per distinct label, stable within a meeting: "Me" is always slot 0;
    /// every other label takes the next slot (1…paletteSize-1, wrapping) in order of
    /// first appearance.
    static func colorIndices(for labels: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        var next = 0
        for label in labels where out[label] == nil {
            if label == SpeakerLabels.me { out[label] = 0; continue }
            out[label] = 1 + next % (paletteSize - 1)
            next += 1
        }
        return out
    }

    /// Whether the transcript should render per-speaker labels: two or more distinct
    /// speakers among the segments.
    static func showsLabels(_ segments: [MeetingSegment]?) -> Bool {
        guard let segments else { return false }
        return Set(segments.map(\.speaker)).count >= 2
    }

    /// True for each segment that starts a new turn (its speaker differs from the
    /// previous segment's), so a label shows once per run by the same speaker.
    static func turnStarts(_ segments: [MeetingSegment]) -> [Bool] {
        segments.enumerated().map { i, s in i == 0 || segments[i - 1].speaker != s.speaker }
    }

    /// Consecutive same-speaker segments merged into turns (text joined with a space).
    static func turns(_ segments: [MeetingSegment]) -> [(speaker: String, text: String)] {
        var out: [(speaker: String, text: String)] = []
        for s in segments {
            if let last = out.last, last.speaker == s.speaker {
                out[out.count - 1].text += " " + s.text
            } else {
                out.append((s.speaker, s.text))
            }
        }
        return out
    }
}
