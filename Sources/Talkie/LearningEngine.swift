import AppKit
import ApplicationServices

/// Recursive self-improvement, WhisperFlow-style: after Talkie inserts text it
/// *actively watches* the focused field for a short window. The moment you fix a
/// word Talkie misrecognized, that correction is added to the dictionary
/// immediately and you get a pill ping with an Undo — no waiting, no silent
/// thresholds.
///
/// Best-effort by nature — it relies on the Accessibility text value of the
/// focused element, which native fields (Notes, TextEdit, most AppKit apps)
/// expose but some web/Electron apps don't. When it can't read, it learns
/// nothing (and never pings).
@MainActor
final class LearningEngine {
    /// Let the paste/keystroke insertion settle into the field before we snapshot
    /// the baseline value we'll diff edits against.
    private static let settleDelay: Duration = .milliseconds(400)
    /// How often we re-read the field while watching for an edit.
    private static let pollInterval: Duration = .milliseconds(600)
    /// Total watch window after an insertion (pollInterval × this).
    private static let maxPolls = 20
    /// A changed value must hold steady for this many consecutive polls before we
    /// treat the edit as finished — so we diff the user's final spelling, not a
    /// half-typed intermediate ("Higgsfiel" mid-keystroke).
    private static let stablePolls = 2

    private var watchTask: Task<Void, Never>?

    /// Start watching the focused field after we inserted `inserted`. On the first
    /// stable, plausible correction the user makes to our text, `onLearned` fires
    /// once (on the main actor) with the from→to pair. Cancels any prior watch.
    func beginWatching(inserted: String,
                       onLearned: @escaping @MainActor (_ from: String, _ to: String) -> Void) {
        stopWatching()
        let captured = inserted
        watchTask = Task { @MainActor in
            try? await Task.sleep(for: Self.settleDelay)
            if Task.isCancelled { return }
            // Baseline: the field must contain what we just inserted, or we're not
            // looking at the right place (or the app reformatted it) — bail.
            guard let (element, baseline) = self.focusedElementValue(),
                  baseline.contains(captured) else { return }

            var candidateValue: String?
            var stableCount = 0
            for _ in 0..<Self.maxPolls {
                try? await Task.sleep(for: Self.pollInterval)
                if Task.isCancelled { return }
                // The same field must still be focused; if focus moved, stop —
                // we can't attribute edits in a different element to our insertion.
                guard let (current, value) = self.focusedElementValue(),
                      CFEqual(current, element) else { return }

                if value == baseline {
                    candidateValue = nil
                    stableCount = 0
                    continue
                }
                if value == candidateValue {
                    stableCount += 1
                    if stableCount >= Self.stablePolls {
                        if let c = CorrectionExtractor.extract(
                            before: baseline, after: value, inserted: captured).first {
                            onLearned(c.from, c.to)
                            return
                        }
                        // Settled, but not a clean respelling of our words — reset
                        // and keep watching in case the user edits further.
                        candidateValue = nil
                        stableCount = 0
                    }
                } else {
                    candidateValue = value
                    stableCount = 0
                }
            }
        }
    }

    /// Stop watching (a new dictation started, or a new insertion is taking over).
    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    // MARK: Accessibility read

    /// The system-wide focused element and its current text value, or nil when
    /// it's unreadable (no AX value, secure field, sandboxed web view, …).
    private func focusedElementValue() -> (AXUIElement, String)? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let str = valueRef as? String else { return nil }
        return (element, str)
    }
}

/// Pure word-level diff that extracts a single conservative correction the user
/// made to text Talkie inserted. Handles a one-word respelling
/// ("correlate"→"Coralate") AND a contiguous merge/split ("Higgs field"→
/// "Higgsfield", "kubernetes"→"k8s" is rejected as implausible). Fully testable;
/// knows nothing about Accessibility.
enum CorrectionExtractor {
    static func extract(
        before: String,
        after: String,
        inserted: String
    ) -> [(from: String, to: String)] {
        let beforeTokens = tokenize(before)
        let afterTokens = tokenize(after)
        guard beforeTokens != afterTokens else { return [] }
        let insertedWords = Set(tokenize(inserted).map(normalized))

        // Isolate the single contiguous region that changed by peeling off the
        // common prefix and suffix. Whatever's left in the middle on each side is
        // the edit: `fromMid` (what Talkie wrote) → `toMid` (what the user typed).
        let prefix = commonPrefixCount(beforeTokens, afterTokens)
        let suffix = commonSuffixCount(
            beforeTokens.dropFirst(prefix), afterTokens.dropFirst(prefix))
        let fromMid = Array(beforeTokens[prefix..<(beforeTokens.count - suffix)])
        let toMid = Array(afterTokens[prefix..<(afterTokens.count - suffix)])

        // A correction is a SUBSTITUTION: both sides non-empty (a pure insertion or
        // deletion isn't a respelling). Exactly the respelling shapes — 1→1, N→1
        // (merge "Higgs field"→"Higgsfield"), 1→N (split) — so ONE side must be a
        // single word; this rejects scattered multi-word regions that would fuse
        // into a bogus phrase rule. A small cap bounds the merge/split width.
        guard !fromMid.isEmpty, !toMid.isEmpty,
              min(fromMid.count, toMid.count) == 1,
              max(fromMid.count, toMid.count) <= 4 else { return [] }

        let fromPhrase = fromMid.joined(separator: " ")
        let toPhrase = toMid.joined(separator: " ")
        let fromStripped = stripped(fromPhrase), toStripped = stripped(toPhrase)
        guard !fromStripped.isEmpty, !toStripped.isEmpty else { return [] }

        // The corrected words must be ones Talkie actually inserted (not edits to
        // the user's own surrounding prose), each side must be word-like, and the
        // change must be a plausible respelling rather than a swap to a different
        // word ("cat"→"dog").
        guard fromMid.allSatisfy({ insertedWords.contains(normalized($0)) }),
              fromMid.allSatisfy(isWordLike), toMid.allSatisfy(isWordLike),
              isPlausibleCorrection(from: normalized(fromPhrase), to: normalized(toPhrase))
        else { return [] }

        return [(fromStripped, toStripped)]
    }

    /// Whether `to` is plausibly a respelling of `from` rather than a different
    /// word. A pure spacing change (same letters, e.g. "higgs field"→"higgsfield")
    /// always qualifies; otherwise accept a shared meaningful prefix OR a small
    /// edit distance relative to length. Inputs are expected normalized.
    static func isPlausibleCorrection(from: String, to: String) -> Bool {
        guard !from.isEmpty, !to.isEmpty, from != to else { return false }

        // Spacing/merge fix: identical once spaces are removed.
        let fromNoSpace = from.replacingOccurrences(of: " ", with: "")
        let toNoSpace = to.replacingOccurrences(of: " ", with: "")
        if fromNoSpace == toNoSpace { return true }

        // Shared-prefix signal: a genuine respelling usually keeps the opening.
        let sharedPrefix = commonPrefixLength(fromNoSpace, toNoSpace)
        let shorter = min(fromNoSpace.count, toNoSpace.count)
        if sharedPrefix >= 2, sharedPrefix * 2 >= shorter { return true }

        // Edit-distance signal: allow ~⅓ of the longer word to change, with a
        // small floor so short words still pass a one/two-character fix.
        let distance = levenshtein(fromNoSpace, toNoSpace)
        let longer = max(fromNoSpace.count, toNoSpace.count)
        let budget = max(2, longer / 3)
        return distance <= budget
    }

    /// Number of leading characters two strings share.
    static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        var i = a.startIndex, j = b.startIndex
        while i < a.endIndex, j < b.endIndex, a[i] == b[j] {
            count += 1
            i = a.index(after: i)
            j = b.index(after: j)
        }
        return count
    }

    /// Classic Levenshtein edit distance (insert/delete/substitute). Pure.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }

    // MARK: Token helpers

    private static func commonPrefixCount(_ a: [String], _ b: [String]) -> Int {
        var n = 0
        while n < a.count, n < b.count, a[n] == b[n] { n += 1 }
        return n
    }

    private static func commonSuffixCount(_ a: ArraySlice<String>, _ b: ArraySlice<String>) -> Int {
        let ar = Array(a), br = Array(b)
        var n = 0
        while n < ar.count, n < br.count, ar[ar.count - 1 - n] == br[br.count - 1 - n] { n += 1 }
        return n
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static let punctuation = CharacterSet(charactersIn: ",.!?;:\"'()[]{}…—-")

    private static func stripped(_ token: String) -> String {
        token.trimmingCharacters(in: punctuation)
    }

    private static func normalized(_ token: String) -> String {
        stripped(token).lowercased()
    }

    private static func isWordLike(_ token: String) -> Bool {
        let core = stripped(token)
        return core.count >= 2 && core.contains(where: { $0.isLetter })
    }
}
