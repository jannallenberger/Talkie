import CoreMedia
import Foundation
import Speech

extension SegmentWord {
    /// The per-token audio time ranges of a finalized recognizer result, in the
    /// recognizer's own clock (the same clock as `result.range`). Needs the transcriber to
    /// have been built with `.audioTimeRange`. A run without a time range (whitespace or
    /// punctuation the recognizer did not time) is folded into the neighbouring token's
    /// text, so the tokens always concatenate to the full result text. Nil when no run
    /// carries a usable range.
    static func words(from text: AttributedString) -> [SegmentWord]? {
        var words: [SegmentWord] = []
        var pendingPrefix = ""
        for run in text.runs {
            let chunk = String(text[run.range].characters)
            if let range = run.audioTimeRange {
                let s = range.start.seconds
                let e = (range.start + range.duration).seconds
                if s.isFinite, e.isFinite {
                    words.append(SegmentWord(text: pendingPrefix + chunk, start: s, end: max(s, e)))
                    pendingPrefix = ""
                    continue
                }
            }
            if words.isEmpty { pendingPrefix += chunk } else { words[words.count - 1].text += chunk }
        }
        return words.isEmpty ? nil : words
    }
}
