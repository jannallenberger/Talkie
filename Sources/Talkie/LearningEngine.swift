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
    /// How often we re-read the field while watching for an edit.
    private static let pollInterval: Duration = .milliseconds(600)
    /// Total watch window after an insertion (pollInterval × this). Generous — a
    /// misrecognition is often fixed seconds (to a minute) later, once the user has
    /// read it back, not within a few seconds of insertion.
    private static let maxPolls = 100        // ≈ 60s
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
            talkieDebugLog("learn: watching after insert (\(captured.count) chars), app=\(Self.frontAppName())")

            // Acquire a baseline that reflects our insertion, retrying while the
            // paste lands. We don't HARD-require an exact substring (apps reformat:
            // smart quotes, trimming) — but we log whether it matched, so the log
            // shows clearly when a field simply isn't AX-readable in this app.
            var element: AXUIElement?
            var baseline: String?
            for attempt in 0..<6 {                          // ~6 × 300ms ≈ 1.8s
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
                guard let (el, val) = self.focusedElementValue() else {
                    if attempt == 5 {
                        talkieDebugLog("learn: ✗ focused field exposes NO AX value (app=\(Self.frontAppName()), role=\(Self.focusedRole())) — can't watch here")
                    }
                    continue
                }
                if Self.looseContains(val, captured) {
                    talkieDebugLog("learn: ✓ baseline acquired (app=\(Self.frontAppName()), role=\(Self.focusedRole()), \(val.count) chars)")
                    element = el; baseline = val
                    break
                }
                if attempt == 5 {
                    talkieDebugLog("learn: ⚠︎ inserted text not found in AX value (app=\(Self.frontAppName()), role=\(Self.focusedRole())) — watching from current value anyway")
                    element = el; baseline = val
                }
            }
            guard let element, let baseline else {
                talkieDebugLog("learn: gave up — no readable field after deep read")
                Self.logFocusedTree()   // dump what IS there, so we know if it's recoverable
                return
            }

            var candidateValue: String?
            var stableCount = 0
            var lastEdited: String?     // last non-baseline value — for the send-clears-field case
            for _ in 0..<Self.maxPolls {
                try? await Task.sleep(for: Self.pollInterval)
                if Task.isCancelled { return }
                // Compare only when the SAME field is still focused & readable; a
                // transient focus blip (clicking around to edit) just skips a poll
                // rather than aborting the whole watch.
                guard let (current, value) = self.focusedElementValue(),
                      CFEqual(current, element) else { continue }

                // The field emptied/collapsed — in a chat you EDIT then SEND, and the
                // send clears the input before the edit can settle. Learn from the last
                // edit we saw just before it vanished, then stop.
                if value.isEmpty || (baseline.count >= 12 && value.count < baseline.count / 3) {
                    if let edited = lastEdited,
                       let c = CorrectionExtractor.extract(before: baseline, after: edited, inserted: captured).first {
                        talkieDebugLog("learn: ✓ LEARNED on send '\(c.from)' → '\(c.to)'")
                        onLearned(c.from, c.to)
                    } else {
                        talkieDebugLog("learn: field cleared (sent) — no clean correction to learn")
                    }
                    return
                }

                if value == baseline {
                    candidateValue = nil
                    stableCount = 0
                    continue
                }
                lastEdited = value
                if value == candidateValue {
                    stableCount += 1
                    if stableCount >= Self.stablePolls {
                        if let c = CorrectionExtractor.extract(
                            before: baseline, after: value, inserted: captured).first {
                            talkieDebugLog("learn: ✓ LEARNED '\(c.from)' → '\(c.to)'")
                            onLearned(c.from, c.to)
                            return
                        }
                        // Settled, but not a clean respelling of our words — reset
                        // and keep watching in case the user edits further.
                        talkieDebugLog("learn: edit settled but not a learnable single correction — still watching")
                        candidateValue = nil
                        stableCount = 0
                    }
                } else {
                    candidateValue = value
                    stableCount = 0
                }
            }
            talkieDebugLog("learn: watch window expired, nothing learned")
        }
    }

    /// Stop watching (a new dictation started, or a new insertion is taking over).
    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    // MARK: Accessibility read

    /// The focused text element and its current value. Reads the focused element's
    /// own value first; if that's empty — common in Electron/Chromium apps like
    /// Claude, where the top focused element is a generic group — it walks the app's
    /// tree for the editable text element (AXTextArea / AXTextField / AXWebArea with
    /// a value), the way a screen reader would. nil only when no text is reachable.
    private func focusedElementValue() -> (AXUIElement, String)? {
        if let el = Self.focusedElement() {
            if let v = Self.stringValue(of: el) { return (el, v) }
            if let hit = Self.findTextDescendant(el, depth: 0) { return hit }
        }
        // Fall back through the focused application's own focused element + window.
        if let app = Self.focusedAppElement() {
            for attr in [kAXFocusedUIElementAttribute, kAXFocusedWindowAttribute] {
                if let child = Self.copyElement(app, attr as CFString) {
                    if let v = Self.stringValue(of: child) { return (child, v) }
                    if let hit = Self.findTextDescendant(child, depth: 0) { return hit }
                }
            }
        }
        return nil
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        return copyElement(system, kAXFocusedUIElementAttribute as CFString)
    }

    private static func focusedAppElement() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    /// Bounded DFS for an editable text element under `el` — a text-role node that
    /// exposes a non-empty string value.
    private static func findTextDescendant(_ el: AXUIElement, depth: Int) -> (AXUIElement, String)? {
        if depth > 8 { return nil }
        let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXWebArea", "AXTextView"]
        if textRoles.contains(roleOf(el)), let v = stringValue(of: el) { return (el, v) }
        for child in children(el).prefix(40) {
            if let hit = findTextDescendant(child, depth: depth + 1) { return hit }
        }
        return nil
    }

    // MARK: AX primitives

    private static func copyElement(_ el: AXUIElement, _ attr: CFString) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success, let r = ref,
              CFGetTypeID(r) == AXUIElementGetTypeID() else { return nil }
        return (r as! AXUIElement)
    }

    private static func stringValue(of el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &ref) == .success,
              let s = ref as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func roleOf(_ el: AXUIElement) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &ref) == .success,
              let r = ref as? String else { return "" }
        return r
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return [] }
        return arr
    }

    /// One-shot diagnostic: dump the focused subtree's roles + value presence to the
    /// debug log, so we can SEE whether an AX-blind-looking app actually exposes its
    /// text somewhere (and where), rather than guessing.
    private static func logFocusedTree() {
        guard let root = focusedElement() ?? focusedAppElement() else {
            talkieDebugLog("axprobe: no focused element"); return
        }
        var lines: [String] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            if depth > 6 || lines.count > 80 { return }
            let role = roleOf(e)
            let v = stringValue(of: e)
            let desc = v.map { "= \"\($0.replacingOccurrences(of: "\n", with: "⏎").prefix(28))\" (\($0.count)ch)" } ?? ""
            lines.append(String(repeating: "· ", count: depth) + (role.isEmpty ? "?" : role) + " " + desc)
            for c in children(e).prefix(15) { walk(c, depth + 1) }
        }
        walk(root, 0)
        talkieDebugLog("axprobe tree (app=\(frontAppName())):\n" + lines.joined(separator: "\n"))
    }

    // MARK: Diagnostics + matching

    /// The frontmost app's name — for the debug log, to see which apps expose a
    /// readable field and which don't.
    private static func frontAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    }

    /// The AX role of the focused element (e.g. AXTextArea, AXTextField), or
    /// "none"/"?" when nothing readable is focused — a strong signal in the log of
    /// whether the app exposes an editable text element at all.
    private static func focusedRole() -> String {
        guard let el = focusedElement() else { return "none" }
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return "?" }
        return role
    }

    /// Substring match that tolerates the reformatting apps apply on insert —
    /// smart quotes, en/em dashes, non-breaking spaces — so the baseline still
    /// recognises our inserted text.
    private static func looseContains(_ haystack: String, _ needle: String) -> Bool {
        normalizeForMatch(haystack).contains(normalizeForMatch(needle))
    }

    private static func normalizeForMatch(_ s: String) -> String {
        var out = s
        for (from, to) in [("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""),
                           ("\u{201D}", "\""), ("\u{2013}", "-"), ("\u{2014}", "-"),
                           ("\u{00A0}", " ")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
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
