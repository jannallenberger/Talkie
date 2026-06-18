import AppKit
import ApplicationServices

/// Recursive self-improvement: after Talkie inserts text, it snapshots the
/// focused text field. Before the next dictation it re-reads that field; if the
/// user fixed a word Talkie produced, that correction becomes a dictionary rule.
///
/// Best-effort by nature — it relies on the Accessibility text value of the
/// focused element, which native fields (Notes, TextEdit, most AppKit apps)
/// expose but some web/Electron apps don't. When it can't read, it simply
/// learns nothing.
@MainActor
final class LearningEngine {
    private struct Pending {
        let element: AXUIElement
        let inserted: String
        let valueAfter: String
    }

    private var pending: Pending?

    /// In-memory tally of how often each candidate correction has been seen.
    /// A candidate is only promoted to a persisted dictionary rule once it
    /// reaches the threshold (P2-12) — until then it stays here and is never
    /// written to the curated dictionary.
    private var ledger = CorrectionLedger()

    /// Snapshot the focused field shortly after we inserted `inserted`.
    func recordInsertion(_ inserted: String) {
        guard let (element, value) = focusedElementValue(), value.contains(inserted) else {
            pending = nil
            return
        }
        pending = Pending(element: element, inserted: inserted, valueAfter: value)
    }

    /// If the user edited our last insertion in the same field, return the
    /// learned (from → to) corrections that have now been observed often enough
    /// to persist. Clears the pending snapshot.
    ///
    /// A single spoken edit no longer becomes a global rule (P2-12): each
    /// extracted candidate is recorded in the ledger and only emitted — i.e.
    /// promoted to a persisted dictionary replacement — once the SAME correction
    /// has been seen `CorrectionLedger.threshold` (3) times. Below that it stays
    /// pending in memory. This is automatic; there is no new confirmation UI.
    func collectCorrections() -> [(from: String, to: String)] {
        guard let p = pending else { return [] }
        pending = nil

        guard let (element, current) = focusedElementValue() else { return [] }
        guard CFEqual(element, p.element) else { return [] } // must be the same field
        guard current != p.valueAfter else { return [] }     // nothing changed

        let candidates = CorrectionExtractor.extract(before: p.valueAfter, after: current, inserted: p.inserted)
        // Record each observation; only candidates that crossed the threshold on
        // this observation are returned for persistence.
        return candidates.filter { ledger.observe(from: $0.from, to: $0.to) }
    }

    // MARK: Accessibility read

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

/// In-memory observation counter for candidate corrections. Pure value type and
/// fully testable: it knows nothing about Accessibility or persistence. A
/// candidate is identified case-insensitively by its `from→to` pair, and is only
/// considered learnable once the same pair has been observed `threshold` times.
struct CorrectionLedger {
    /// How many times the SAME correction must be observed before it persists.
    static let threshold = 3

    private var counts: [String: Int] = [:]

    private static func key(from: String, to: String) -> String {
        from.lowercased() + "→" + to.lowercased()
    }

    /// Record one observation of `from→to`. Returns `true` exactly on the
    /// observation that brings the candidate UP TO the threshold — that's the
    /// moment it should be persisted. Subsequent observations of an
    /// already-promoted candidate return `false` (it's already a rule, no need to
    /// re-add it). Returns `false` while still below the threshold.
    mutating func observe(from: String, to: String) -> Bool {
        let k = Self.key(from: from, to: to)
        let next = (counts[k] ?? 0) + 1
        counts[k] = next
        return next == Self.threshold
    }

    /// Current observation count for a candidate (testing/inspection).
    func count(from: String, to: String) -> Int {
        counts[Self.key(from: from, to: to)] ?? 0
    }
}

/// Pure word-level diff that extracts conservative single-word corrections.
enum CorrectionExtractor {
    static func extract(
        before: String,
        after: String,
        inserted: String
    ) -> [(from: String, to: String)] {
        let beforeTokens = tokenize(before)
        let afterTokens = tokenize(after)
        let insertedWords = Set(tokenize(inserted).map(normalized))

        // Only learn from an UNAMBIGUOUS single-word swap: exactly one word
        // removed and one inserted. CollectionDifference's remove/insert offsets
        // live in different coordinate spaces (before vs after), so pairing them
        // for multi-word edits mis-aligns and would poison the dictionary. The
        // single-swap case is the only one we can pair with certainty.
        let diff = afterTokens.difference(from: beforeTokens)
        guard diff.removals.count == 1, diff.insertions.count == 1 else { return [] }

        var oldWord: String?
        var newWord: String?
        for change in diff {
            switch change {
            case .remove(_, let element, _): oldWord = element
            case .insert(_, let element, _): newWord = element
            }
        }
        guard let old = oldWord, let new = newWord else { return [] }

        let on = normalized(old), nn = normalized(new)
        guard on != nn, on.count >= 2, nn.count >= 2,
              isWordLike(old), isWordLike(new),
              insertedWords.contains(on),
              // Plausibility floor (P2-12): a "correction" should be a respelling
              // of the same word, not a swap to a totally different word. Without
              // this, replacing "cat" with "dog" once would teach a global rule.
              isPlausibleCorrection(from: on, to: nn) else { return [] }

        let fromWord = stripped(old), toWord = stripped(new)
        guard !fromWord.isEmpty, !toWord.isEmpty else { return [] }
        return [(fromWord, toWord)]
    }

    /// Whether `to` is plausibly a respelling of `from` rather than a different
    /// word entirely. Accept when the two share a meaningful prefix OR are within
    /// a small edit distance relative to their length — both signatures of a
    /// spelling fix (e.g. "correlate"→"coralate", "cubernets"→"kubernetes") while
    /// rejecting unrelated swaps ("cat"→"dog"). Pure; inputs are expected
    /// normalized (stripped + lowercased).
    static func isPlausibleCorrection(from: String, to: String) -> Bool {
        guard !from.isEmpty, !to.isEmpty else { return false }
        if from == to { return false }

        // Shared-prefix signal: a genuine respelling usually keeps the opening.
        let sharedPrefix = commonPrefixLength(from, to)
        let shorter = min(from.count, to.count)
        if sharedPrefix >= 2, sharedPrefix * 2 >= shorter { return true }

        // Edit-distance signal: allow ~⅓ of the longer word to change, with a
        // small floor so short words (where prefix may be too strict) still pass
        // a one/two-character fix.
        let distance = levenshtein(from, to)
        let longer = max(from.count, to.count)
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
