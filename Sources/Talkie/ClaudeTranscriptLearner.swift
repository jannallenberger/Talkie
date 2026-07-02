import Foundation

/// Cures the AX-blind spot. `LearningEngine` learns corrections by watching the
/// focused Accessibility field — which Electron/terminal surfaces (Claude Code
/// running in Terminal, iTerm, Warp, or a VS Code/Cursor integrated terminal)
/// simply don't expose, so it learns *nothing* there. But Claude Code writes every
/// submitted prompt to `~/.claude/projects/<munged-cwd>/<session>.jsonl` as a local
/// file. So when we dictate into one of those surfaces and can't watch the field,
/// we instead take one opportunistic look at that transcript a short while later:
/// if the prompt the user actually submitted contains a respelled version of what
/// we inserted, that's the same correction the AX watcher would have caught — and
/// we learn it identically (dictionary rule + HUD-Undo + the niche-vocab signals).
///
/// Deliberately opportunistic, not a contract. We schedule ONE delayed scan (no
/// FSEvents watcher — better privacy optics and no machinery); if the user submits
/// after our window, we miss it, and that's fine. Privacy is the load-bearing
/// concern: reading a conversation file is qualitatively different from watching
/// the field we just pasted into, so this is gated behind a one-time consent AND
/// the existing `learnFromEdits` toggle, reads are scoped to a tight time window,
/// content is NEVER logged, and only `~/.claude/projects` is ever touched.
///
/// 100% local — it reads local JSON files and constructs nothing networked.

// MARK: - Pure, testable scan core

/// The pure engine: parse a Claude Code JSONL transcript into the user prompts that
/// fall inside a time window, and decide whether any of them is a respelling of the
/// text Talkie inserted. Knows nothing about the filesystem, Accessibility, or the
/// clock beyond the timestamps it is handed — so it is exhaustively unit-testable
/// with fixture JSONL (see `ClaudeTranscriptLearnerTests`).
enum ClaudeTranscriptScan {
    /// A single submitted user prompt recovered from a transcript, with when it was
    /// submitted (so the shell can filter to the post-insertion window).
    struct Prompt: Equatable, Sendable {
        var text: String
        var unix: Double
    }

    /// Fraction of the inserted text's tokens a candidate prompt must contain for us
    /// to consider it "the same utterance, edited" rather than an unrelated message.
    /// 0.70 per the spec — loose enough to survive a one-word respelling and a bit of
    /// surrounding edit, tight enough that a prompt merely *mentioning* a couple of
    /// the words never qualifies.
    static let minTokenOverlap = 0.70

    /// Parse the lines of a `.jsonl` transcript into the plain-text user prompts
    /// whose `timestamp` lies within `[window.lowerBound, window.upperBound]`.
    ///
    /// Defensive by construction — the JSONL schema is Anthropic-internal and can
    /// drift, so every decode failure (a malformed line, a missing field, a content
    /// shape we don't expect) is treated as "no prompt here" and skipped, never a
    /// throw. We keep ONLY `type == "user"` lines whose `message.content` is a bare
    /// string: array content is a tool-result echo, not something the human typed,
    /// and learning from it would be wrong.
    static func userPrompts(fromJSONL jsonl: String, within window: ClosedRange<Double>) -> [Prompt] {
        var out: [Prompt] = []
        for line in jsonl.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard obj["type"] as? String == "user" else { continue }
            guard let ts = obj["timestamp"] as? String, let unix = parseISO8601(ts) else { continue }
            guard window.contains(unix) else { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            // ONLY string content is a typed prompt. Array content (tool_result) is
            // echoed tool output, and other shapes aren't human text — skip both.
            guard let text = message["content"] as? String else { continue }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            out.append(Prompt(text: clean, unix: unix))
        }
        return out
    }

    /// The one function the shell calls: given the text Talkie inserted and a set of
    /// candidate submitted prompts (already time-filtered), return the single
    /// trustworthy correction to learn, or nil.
    ///
    /// A candidate qualifies only if it *loosely contains* the inserted text (≥70% of
    /// the inserted tokens are present) — i.e. it's plausibly the same utterance the
    /// user edited before submitting. We then hand `(before: inserted, after: prompt)`
    /// to the SAME `CorrectionExtractor` the live AX watcher uses, so a Claude Code
    /// correction and a Notes correction go through identical respelling guards
    /// (single contiguous substitution of words we inserted, plausible respelling —
    /// never a word swap, never a change to the user's own surrounding prose). The
    /// first candidate that yields a clean rule wins.
    static func extractLearnableCorrection(inserted: String, candidates: [String]) -> (from: String, to: String)? {
        let insertedTokens = normalizedTokens(inserted)
        guard !insertedTokens.isEmpty else { return nil }
        for candidate in candidates {
            guard looseContains(candidate, insertedTokens: insertedTokens) else { continue }
            if let c = CorrectionExtractor.extract(before: inserted, after: candidate, inserted: inserted).first {
                return c
            }
        }
        return nil
    }

    /// Whether `candidate` is plausibly the same utterance the user edited before
    /// submitting — the cheap "same sentence?" pre-filter in front of the strict
    /// `CorrectionExtractor`. Two ways to qualify, because a correction has two
    /// signatures:
    ///
    ///  1. **Bag overlap** — ≥`minTokenOverlap` (70%) of the inserted tokens are
    ///     present, order-insensitive. Catches reflowed edits and long insertions
    ///     where the fix is a small fraction of the words.
    ///
    ///  2. **Contiguous anchor** — the candidate shares an unchanged token *prefix*
    ///     and *suffix* with the insertion that together cover ≥60% of the inserted
    ///     tokens. This is exactly what a single localized respelling leaves behind
    ///     ("update the ⟨cloud MD⟩ file" → "update the ⟨claude.md⟩ file" keeps
    ///     "update the" and "file"), and it rescues the short-sentence case where the
    ///     corrected words themselves drag the bag overlap below 70%. An unrelated
    ///     prompt has no such aligned prefix+suffix, so this stays tight.
    static func looseContains(_ candidate: String, insertedTokens: [String]) -> Bool {
        guard !insertedTokens.isEmpty else { return false }
        let candidateTokens = normalizedTokens(candidate)

        // (1) bag overlap
        let candidateSet = Set(candidateTokens)
        let hits = insertedTokens.reduce(into: 0) { acc, tok in
            if candidateSet.contains(tok) { acc += 1 }
        }
        if Double(hits) / Double(insertedTokens.count) >= minTokenOverlap { return true }

        // (2) contiguous prefix+suffix anchor
        var prefix = 0
        while prefix < insertedTokens.count, prefix < candidateTokens.count,
              insertedTokens[prefix] == candidateTokens[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < insertedTokens.count - prefix, suffix < candidateTokens.count - prefix,
              insertedTokens[insertedTokens.count - 1 - suffix] == candidateTokens[candidateTokens.count - 1 - suffix] {
            suffix += 1
        }
        return Double(prefix + suffix) / Double(insertedTokens.count) >= 0.60
    }

    // MARK: Normalization (mirrors LearningEngine's match semantics)

    /// Lowercased, punctuation-stripped word tokens. The same normalization the AX
    /// path relies on for matching (copied here so the pure core has no dependency on
    /// the Accessibility engine), kept intentionally simple: fold case + diacritics,
    /// drop surrounding punctuation, split on whitespace.
    static func normalizedTokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { normalizeForMatch(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static let punctuation = CharacterSet(charactersIn: ",.!?;:\"'()[]{}…—-`")

    static func normalizeForMatch(_ token: String) -> String {
        token.trimmingCharacters(in: punctuation)
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
    }

    /// Parse the ISO-8601 timestamps Claude Code writes (`2026-07-02T18:32:26.839Z`)
    /// into a Unix time. Tries fractional seconds first (the observed format), then a
    /// plain second-resolution fallback — any unparseable stamp returns nil and the
    /// line is skipped.
    static func parseISO8601(_ string: String) -> Double? {
        if let date = iso8601Fractional.date(from: string) { return date.timeIntervalSince1970 }
        if let date = iso8601Plain.date(from: string) { return date.timeIntervalSince1970 }
        return nil
    }

    // `nonisolated(unsafe)` is accurate here: these formatters are configured once at
    // init and thereafter only ever *read* (`date(from:)`), never mutated — the exact
    // "protected by external synchronization" (immutability) escape the compiler note
    // describes. Sharing them avoids rebuilding a formatter per JSONL line.
    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// A one-shot latch shared between the two learning paths for a single insertion.
/// Reference type so both closures see the same flip; main-actor-confined so no lock
/// is needed. Whoever learns first sets `value = true`; the delayed Claude Code scan
/// reads it and stands down, preventing a duplicate rule or a second HUD ping.
@MainActor
final class LearnOnceFlag {
    var value = false
}

// MARK: - @MainActor shell (scheduling, consent, file I/O)

/// The stateful shell around `ClaudeTranscriptScan`: it owns the one-time consent
/// decision, schedules the single delayed scan, and does the (tightly-scoped) file
/// reads. Constructed once and injected from `AppDelegate`, mirroring `LearningEngine`.
@MainActor
final class ClaudeTranscriptLearner {
    /// Tri-state one-time consent, persisted as a hidden default (no settings row):
    /// we ask exactly once, the first time a scan *would* run.
    enum Consent: String {
        case unset   // never asked — the next eligible insertion triggers the offer
        case granted // user accepted; scans run
        case denied  // user declined; never ask, never scan again
    }

    /// How long after insertion we wait before scanning. The user has to read our
    /// text back, fix it, and submit — that takes a beat; 90s is a generous window
    /// that still feels like "within ~2 minutes" learning.
    private static let scanDelay: Duration = .seconds(90)
    /// The time band, around the insertion, in which a submitted prompt counts. Opens
    /// slightly before insertion (clock skew between our `Date()` and Claude Code's
    /// timestamp) and closes a bit past the scan so a prompt submitted late in the
    /// window is still caught.
    private static let windowLead: Double = 5          // seconds before insertion
    private static let windowTrail: Double = 150       // seconds after insertion

    /// Injected so tests can point at a fixture tree and control the clock; the real
    /// app uses the defaults (`~/.claude/projects`, `Date()`).
    private let projectsDirectory: URL
    private let readConsent: () -> Consent
    private let writeConsent: (Consent) -> Void

    private var scanTask: Task<Void, Never>?

    init(
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        readConsent: @escaping () -> Consent,
        writeConsent: @escaping (Consent) -> Void
    ) {
        self.projectsDirectory = projectsDirectory
        self.readConsent = readConsent
        self.writeConsent = writeConsent
    }

    /// Schedule the one-shot post-insertion scan for a dictation that landed in an
    /// AX-blind coding/terminal surface.
    ///
    /// - `alreadyLearned` lets the caller short-circuit the whole thing if the AX
    ///   watcher already learned from this same insertion (they run side by side; we
    ///   never want to double-learn or double-ping). It's read at scan time, not
    ///   scheduling time, so the AX path has its full window to win first.
    /// - `offerConsent` is invoked (on the main actor) when consent is `.unset` and a
    ///   scan would otherwise run — the caller shows the one-time HUD chip and reports
    ///   the choice back via `resolveConsent`. On `.unset` we do NOT scan this time;
    ///   the offer is the interaction, and the next eligible insertion scans if granted.
    /// - `onLearned` fires once with the from→to pair on a real hit (main actor).
    func scheduleScan(
        inserted: String,
        insertionUnix: Double,
        alreadyLearned: @escaping @MainActor () -> Bool,
        offerConsent: @escaping @MainActor () -> Void,
        onLearned: @escaping @MainActor (_ from: String, _ to: String) -> Void
    ) {
        // Consent gate FIRST — before we schedule anything, before any read. A denied
        // user costs exactly nothing; an unset user gets the offer and no scan.
        switch readConsent() {
        case .denied:
            return
        case .unset:
            offerConsent()
            return
        case .granted:
            break
        }

        scanTask?.cancel()
        let dir = projectsDirectory
        let captured = inserted
        scanTask = Task { @MainActor in
            try? await Task.sleep(for: Self.scanDelay)
            if Task.isCancelled { return }
            // If the AX watcher already caught this correction, stand down — no read,
            // no duplicate rule, no second ping.
            if alreadyLearned() { return }

            let windowLow = insertionUnix - Self.windowLead
            let window = windowLow...(insertionUnix + Self.windowTrail)
            // The file enumeration + parse is pure/off-the-hot-path work; do it in a
            // detached task so a large transcript never stutters the main actor, then
            // hop back for the callbacks. All inputs are captured as plain values so
            // nothing main-actor-isolated is read across the boundary.
            let hit = await Task.detached(priority: .utility) { () -> (from: String, to: String)? in
                let prompts = Self.collectPrompts(under: dir, within: window, notBefore: windowLow)
                    .map(\.text)
                return ClaudeTranscriptScan.extractLearnableCorrection(inserted: captured, candidates: prompts)
            }.value

            if Task.isCancelled { return }
            if let hit {
                talkieDebugLog("claude-learn: ✓ learned from a Claude Code prompt")
                onLearned(hit.from, hit.to)
            } else {
                talkieDebugLog("claude-learn: scanned, no learnable correction in the window")
            }
        }
    }

    /// Record the user's answer to the one-time offer. Persists it; a grant does NOT
    /// retroactively scan the insertion that triggered the offer (that window is gone)
    /// — it just unlocks future eligible insertions.
    func resolveConsent(granted: Bool) {
        writeConsent(granted ? .granted : .denied)
        talkieDebugLog("claude-learn: consent \(granted ? "granted" : "denied")")
    }

    /// Cancel any pending scan (a new dictation is taking over, or teardown).
    func cancel() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: File collection (nonisolated — runs off-main via detached Task)

    /// Enumerate `~/.claude/projects/*/*.jsonl`, skip files whose mtime is older than
    /// the insertion (they can't contain a post-insertion prompt), and parse the rest
    /// for in-window user prompts.
    ///
    /// Scoped hard to `projects`: we never traverse outside it, never follow into
    /// other `~/.claude` contents, and read only `.jsonl`. Any I/O error on a file is
    /// swallowed — a partial read is a no-op, not a crash.
    nonisolated static func collectPrompts(
        under projectsDirectory: URL,
        within window: ClosedRange<Double>,
        notBefore mtimeFloor: Double
    ) -> [ClaudeTranscriptScan.Prompt] {
        let fm = FileManager.default
        guard let sessionDirs = try? fm.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var prompts: [ClaudeTranscriptScan.Prompt] = []
        for sessionDir in sessionDirs {
            guard (try? sessionDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: sessionDir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                // mtime prefilter: a transcript last written before the insertion can't
                // hold a prompt submitted after it. Cheap way to skip stale sessions.
                if let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970, mtime < mtimeFloor {
                    continue
                }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                prompts.append(contentsOf: ClaudeTranscriptScan.userPrompts(fromJSONL: text, within: window))
            }
        }
        return prompts
    }
}
