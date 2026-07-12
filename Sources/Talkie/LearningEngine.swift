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
            talkieDebugLog("learn: watching after insert (\(captured.count) chars), app=\(AXFieldReader.frontAppName())")

            // Acquire a baseline that reflects our insertion, retrying while the
            // paste lands. We don't HARD-require an exact substring (apps reformat:
            // smart quotes, trimming) — but we log whether it matched, so the log
            // shows clearly when a field simply isn't AX-readable in this app.
            var element: AXUIElement?
            var baseline: String?
            for attempt in 0..<6 {                          // ~6 × 300ms ≈ 1.8s
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
                guard let (el, val) = AXFieldReader.focusedElementValue() else {
                    if attempt == 5 {
                        talkieDebugLog("learn: ✗ focused field exposes NO AX value (app=\(AXFieldReader.frontAppName()), role=\(AXFieldReader.focusedRole())) — can't watch here")
                    }
                    continue
                }
                if AXFieldReader.looseContains(val, captured) {
                    talkieDebugLog("learn: ✓ baseline acquired (app=\(AXFieldReader.frontAppName()), role=\(AXFieldReader.focusedRole()), \(val.count) chars)")
                    element = el; baseline = val
                    break
                }
                if attempt == 5 {
                    talkieDebugLog("learn: ⚠︎ inserted text not found in AX value (app=\(AXFieldReader.frontAppName()), role=\(AXFieldReader.focusedRole())) — watching from current value anyway")
                    element = el; baseline = val
                }
            }
            guard let element, let baseline else {
                talkieDebugLog("learn: gave up — no readable field after deep read")
                AXFieldReader.logFocusedTree()   // dump what IS there, so we know if it's recoverable
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
                guard let (current, value) = AXFieldReader.focusedElementValue(),
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

    // The Accessibility read machinery (focused-element read, AX primitives, the
    // subtree diagnostic, and the reformatting-tolerant `looseContains`) now lives
    // in `AXFieldReader`, shared with `InsertionVerifier`. This engine delegates to
    // it above; the behavior is identical to when these methods were file-private.
}

/// Pure word-level diff that extracts a single conservative correction the user
/// made to text Talkie inserted. Handles a one-word respelling
/// ("get hub"→"GitHub") AND a contiguous merge/split ("Higgs field"→
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

/// Extracts EVERY learnable respelling from a whole-transcript edit — the pure
/// piece behind A8's "fix a word in the meeting note, teach the dictionary" flow.
///
/// `CorrectionExtractor.extract` deliberately peels one common prefix + one common
/// suffix and then demands the single changed middle be a 1↔N respelling. That's
/// exactly right for the live field-watcher (one edit at a time) but wrong for a
/// transcript the user opens and fixes in several places at once: two scattered
/// fixes ("cloud MD"→"claude.md" near the top, "kubernetis"→"kubernetes" near the
/// bottom) leave a *middle* spanning everything between them, so `extract`'s shape
/// guard rejects the pair and learns nothing — the naive "apply and re-extract"
/// loop never even finds its first correction.
///
/// So we segment the edit into contiguous changed token-runs separated by
/// unchanged context (a token-level LCS alignment; the gaps between matched anchor
/// tokens are the change blocks), re-attach one unchanged anchor token on each side
/// so the reused extractor still has a prefix/suffix to peel, and run the UNCHANGED
/// `CorrectionExtractor.extract` on each block. Each block is a localized 1↔N
/// substitution or it teaches nothing — so multi-fix edits yield multiple rules
/// while deletions, rewrites, and prose edits are still rejected by the same
/// guards. Results are deduped and capped so a huge rewrite can't spew rules.
enum TranscriptEditCorrections {
    /// At most this many distinct learn rules from one save — a transcript edit that
    /// changes more than a handful of regions is a rewrite, not a batch of spelling
    /// fixes, and shouldn't flood the user with chips.
    static let maxRegions = 5

    /// Every trustworthy from→to respelling between `before` and `after`, in reading
    /// order, deduped (case-insensitively on the pair). `inserted` defaults to the
    /// old text because in a transcript edit Talkie "inserted" the whole original
    /// transcript — every original word is fair game to correct, unlike the live
    /// watcher where only the freshly-pasted span was ours.
    static func extract(before: String, after: String) -> [(from: String, to: String)] {
        let beforeTokens = tokenize(before)
        let afterTokens = tokenize(after)
        guard beforeTokens != afterTokens else { return [] }

        var results: [(from: String, to: String)] = []
        var seen = Set<String>()
        for block in changeBlocks(beforeTokens, afterTokens) {
            // Re-attach one unchanged anchor token on each side (when present) so the
            // reused extractor can peel a common prefix/suffix and correctly isolate
            // the changed middle — an anchorless block of two differing single tokens
            // would otherwise read as a whole-utterance swap.
            let bLo = block.beforeRange.lowerBound == 0 ? 0 : block.beforeRange.lowerBound - 1
            let aLo = block.afterRange.lowerBound == 0 ? 0 : block.afterRange.lowerBound - 1
            let bHi = min(beforeTokens.count, block.beforeRange.upperBound + 1)
            let aHi = min(afterTokens.count, block.afterRange.upperBound + 1)
            let beforeRegion = beforeTokens[bLo..<bHi].joined(separator: " ")
            let afterRegion = afterTokens[aLo..<aHi].joined(separator: " ")

            for c in CorrectionExtractor.extract(
                before: beforeRegion, after: afterRegion, inserted: beforeRegion
            ) {
                let key = c.from.lowercased() + "\u{0}" + c.to.lowercased()
                guard seen.insert(key).inserted else { continue }
                results.append(c)
                if results.count >= maxRegions { return results }
            }
        }
        return results
    }

    /// A maximal run of changed tokens, as index ranges into each side. Empty ranges
    /// are allowed (a pure insertion has an empty `beforeRange`); `CorrectionExtractor`
    /// rejects those, which is what we want.
    private struct ChangeBlock {
        var beforeRange: Range<Int>
        var afterRange: Range<Int>
    }

    /// Walk a longest-common-subsequence alignment of the two token arrays; the
    /// spans between consecutive matched (equal) tokens are the change blocks. Pure.
    private static func changeBlocks(_ before: [String], _ after: [String]) -> [ChangeBlock] {
        let matches = lcsMatches(before, after)  // aligned (beforeIdx, afterIdx) equal pairs
        var blocks: [ChangeBlock] = []
        var b = 0
        var a = 0
        for (mb, ma) in matches + [(before.count, after.count)] {
            if mb > b || ma > a {
                blocks.append(ChangeBlock(beforeRange: b..<mb, afterRange: a..<ma))
            }
            b = mb + 1
            a = ma + 1
        }
        return blocks
    }

    /// Indices of a longest common subsequence, as aligned `(beforeIdx, afterIdx)`
    /// pairs. Classic O(n·m) DP + backtrace — transcripts are bounded (retention cap)
    /// and this only runs on an explicit save, so the quadratic table is fine.
    private static func lcsMatches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1
                                        : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                pairs.append((i, j)); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
