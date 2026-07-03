import Foundation

/// **L2-b — the "added by Chirp" auto-add gate, decision half.**
///
/// A pure, side-effect-free predicate that decides whether an extracted commitment
/// is worth *suggesting* as a Scratchpad line. It writes nothing and touches no
/// store — the only consumer today is `AutoAddPreviewLog`, which records what this
/// gate WOULD do so Jann can calibrate the threshold from real logs before any live
/// write ships (see that file's header). When the live lane lands, the same predicate
/// gates the actual `ScratchpadStore` write; keeping the decision pure means the
/// preview data and the eventual live behavior can never diverge.
///
/// **Philosophy: default EXCLUDE, bias hard toward silence.** A false positive here
/// would drop noise into the one hand-curated surface on the dashboard; a false
/// negative just means Jann types the line himself. So every condition must pass for
/// a suggestion, the reasons are always returned (for the calibration log), and any
/// missing signal fails closed.
enum AutoAddGate {

    /// Where the commitment came from. The two live extraction paths have very
    /// different precision, so the gate treats them differently.
    enum CommitmentSource: String, Sendable {
        /// F3's Stage-2 on-device LLM extractor (`GraphLLMExtractor`, run at meeting
        /// finalize). It is explicitly prompted to emit only genuine commitments
        /// ("an explicit promise or task the speaker takes on") and to not invent —
        /// so an LLM commitment is trusted on source alone.
        case llmExtractor

        /// The Stage-1 cue-phrase heuristic (`ContextGraphExtractor.commitments`,
        /// 10 broad first-person cues). Cheap and model-free, but noisy: it fires on
        /// any clause merely *containing* a cue substring. A heuristic hit therefore
        /// has to clear a stricter second-person/future commitment check before it
        /// can be suggested.
        case heuristic
    }

    /// The frontmost app the dictation went INTO, as the gate needs to see it. A
    /// value type (not `TargetApp`) so the gate stays pure and trivially testable.
    ///
    /// `nil` means "we don't know the target" — which is exactly the state when
    /// context awareness is off (the pipeline never reads the frontmost app's window
    /// title, and passes `nil` here). The gate treats an unknown target as
    /// fail-closed: it will not suggest, but the caller still logs the attempt so the
    /// fail-closed rate is visible in the calibration data.
    struct FrontApp: Sendable, Equatable {
        var bundleID: String?
        var category: AppCategory
        /// The terminal/agent window title, when context awareness captured one.
        /// Used only to ask `AgentTerminalDetector` whether this is an agent CLI.
        var windowTitle: String?

        init(bundleID: String?, category: AppCategory, windowTitle: String?) {
            self.bundleID = bundleID
            self.category = category
            self.windowTitle = windowTitle
        }
    }

    /// The verdict plus the human-readable reasons each condition passed or failed.
    /// The reasons are the whole point of the preview lane — they are what Jann reads
    /// to tune the threshold — so they are returned on BOTH outcomes.
    struct Decision: Sendable, Equatable {
        var suggest: Bool
        var reasons: [String]
    }

    // MARK: - The task-executing surfaces (reused Claude / agent-terminal signal)

    /// Bundle-id fragments for surfaces where a dictation IS the act of getting the
    /// work done — the Claude desktop app and other coding-agent chat clients.
    /// Anything dictated INTO one of these is already being executed by an agent, so
    /// re-adding it as a personal reminder is pure noise. Matched as a lowercased
    /// substring of the bundle id (mirrors `AppCategory.classify`'s own matching).
    ///
    /// This is the "reuse AgentTerminalDetector's set" intent adapted to the two real
    /// signals that exist: `AgentTerminalDetector` keys off the *window title* (for a
    /// coding agent running inside a terminal), which we consult separately below;
    /// there is no standalone Claude *bundle* set in the codebase, so the desktop /
    /// chat-client bundles are named here alongside it. Kept deliberately short.
    static let agentAppBundleFragments: [String] = [
        "com.anthropic.claude",   // Claude desktop app
        "claude",                 // any other Claude-branded client bundle
    ]

    /// True when the frontmost app is a surface that already *executes* what you
    /// dictate — a coding editor, a terminal, a terminal running a coding agent, or
    /// the Claude desktop app. Suggesting a commitment you dictated into one of these
    /// as a to-do would be redundant with the thing already doing it.
    static func isTaskExecutingSurface(_ app: FrontApp) -> Bool {
        // A coding editor or a terminal: the work happens here.
        if app.category == .coding || app.category == .terminal { return true }
        // A terminal (or any surface) whose title names a coding-agent CLI.
        if AgentTerminalDetector.isAgentSession(windowTitle: app.windowTitle) { return true }
        // The Claude desktop app / a Claude-branded client, by bundle id.
        if let b = app.bundleID?.lowercased(),
           agentAppBundleFragments.contains(where: { b.contains($0) }) {
            return true
        }
        return false
    }

    // MARK: - The predicate

    /// Decide whether `commitmentText` (from `source`, dictated into `frontApp`)
    /// should be suggested as a Scratchpad line, given the `existingLines` already
    /// there. Pure: no I/O, no store access, no logging — the caller records the
    /// result. Default EXCLUDE; every condition must pass.
    ///
    /// The three conditions, all required:
    ///   (a) **Trusted commitment.** LLM-extracted commitments pass on source. A
    ///       heuristic commitment must additionally clear
    ///       `passesStrictFutureCommitment` (a real forward-looking "I will / I need
    ///       to …" or "you should …" construction, not a loose cue-substring hit).
    ///   (b) **Not a task-executing surface.** The dictation's frontmost app must not
    ///       be Claude / an agent terminal / an editor / a terminal — dictating a
    ///       commitment into one of those means it's already being acted on. An
    ///       unknown app (context awareness off → `frontApp == nil`) fails this,
    ///       closed.
    ///   (c) **Not a near-duplicate.** The normalized commitment text must not already
    ///       match an existing Scratchpad line.
    static func shouldSuggest(
        commitmentText: String,
        source: CommitmentSource,
        frontApp: FrontApp?,
        existingLines: [String]
    ) -> Decision {
        var reasons: [String] = []

        let trimmed = commitmentText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Pre-condition: a commitment that's empty or trivially short is never worth
        // suggesting (matches the extractors' own lower bounds). Fail closed.
        guard trimmed.count >= 4 else {
            reasons.append("reject:empty-or-too-short")
            return Decision(suggest: false, reasons: reasons)
        }

        // (a) Trusted commitment.
        let sourceOK: Bool
        switch source {
        case .llmExtractor:
            sourceOK = true
            reasons.append("pass:source-llm")
        case .heuristic:
            if passesStrictFutureCommitment(trimmed) {
                sourceOK = true
                reasons.append("pass:source-heuristic-strict-future")
            } else {
                sourceOK = false
                reasons.append("reject:heuristic-not-strict-future")
            }
        }

        // (b) Not a task-executing surface. Unknown app → fail closed.
        let appOK: Bool
        if let app = frontApp {
            if isTaskExecutingSurface(app) {
                appOK = false
                reasons.append("reject:task-executing-surface(\(app.category.rawValue))")
            } else {
                appOK = true
                reasons.append("pass:app-not-executing(\(app.category.rawValue))")
            }
        } else {
            appOK = false
            reasons.append("reject:front-app-unknown-fail-closed")
        }

        // (c) Not a near-duplicate of an existing line.
        let dupOK: Bool
        if isNearDuplicate(trimmed, of: existingLines) {
            dupOK = false
            reasons.append("reject:near-duplicate")
        } else {
            dupOK = true
            reasons.append("pass:not-duplicate")
        }

        return Decision(suggest: sourceOK && appOK && dupOK, reasons: reasons)
    }

    // MARK: - Condition (a): the stricter heuristic gate

    /// The extra bar a *heuristic* commitment must clear. The Stage-1 cues are broad
    /// first-person substrings that fire on any clause merely containing e.g.
    /// "follow up" or "let me"; this check demands the clause actually be a
    /// forward-looking commitment — a first-person-future or second-person-directive
    /// construction ("I will …", "I need to …", "I'm going to …", "you should …",
    /// "let's …") — and rejects questions and past-tense recollections that a loose
    /// cue can otherwise sweep in.
    ///
    /// (The spec calls this the "stricter second-person-future check"; in practice a
    /// dictated self-commitment is first-person-future, so the marker set covers both
    /// persons. It is intentionally conservative — a rejected heuristic commitment
    /// just doesn't get suggested, which is the safe direction.)
    static func passesStrictFutureCommitment(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "

        // A trailing question mark means it's a question, not a commitment.
        if text.hasSuffix("?") { return false }

        // Forward-looking commitment constructions. Each is a real "about to do X"
        // phrasing, not a bare cue that could sit mid-sentence in a recollection.
        let futureMarkers = [
            " i will ", " i'll ", " i am going to ", " i'm going to ", " i need to ",
            " i have to ", " i've got to ", " i gotta ", " i must ", " i should ",
            " we will ", " we'll ", " we need to ", " we have to ", " we should ",
            " you need to ", " you should ", " you'll ", " you will ", " you have to ",
            " let's ", " let me ", " going to ", " need to ",
        ]
        guard futureMarkers.contains(where: { lower.contains($0) }) else { return false }

        // Reject obvious past-tense recollections that a future marker's substring can
        // still appear inside (e.g. "I needed to" would not match " i need to ", but
        // guard the common "was going to" / "had to" retrospectives explicitly).
        let pastMarkers = [" was going to ", " were going to ", " had to ", " used to ", " wanted to "]
        if pastMarkers.contains(where: { lower.contains($0) }) { return false }

        return true
    }

    // MARK: - Condition (c): near-duplicate detection

    /// Normalize a line for duplicate comparison: lowercase, strip a leading task
    /// marker (`- ` / `[]` / `[ ]` / `[x]`), collapse internal whitespace, and drop
    /// surrounding punctuation. Two lines that normalize equal are "the same line" for
    /// the purpose of not adding a second copy. Pure + static so its behavior is
    /// pinned by tests and can't drift from the live path.
    static func normalizedForDuplicate(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a leading checkbox/bullet marker so "buy milk" and "- buy milk" and
        // "[] buy milk" all collapse together.
        if s.hasPrefix("- ") {
            s = String(s.dropFirst(2))
        } else {
            for marker in ["[]", "[ ]", "[x]"] where s.hasPrefix(marker) {
                s = String(s.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Collapse all whitespace runs to single spaces.
        let collapsed = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")

        // Trim surrounding punctuation so a trailing period / quote doesn't defeat the
        // match.
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'`()[]{} "))
    }

    /// True when `text` normalizes equal to any existing line — i.e. it's already on
    /// the Scratchpad and re-adding it would duplicate.
    static func isNearDuplicate(_ text: String, of existingLines: [String]) -> Bool {
        let key = normalizedForDuplicate(text)
        guard !key.isEmpty else { return false }
        return existingLines.contains { normalizedForDuplicate($0) == key }
    }
}
