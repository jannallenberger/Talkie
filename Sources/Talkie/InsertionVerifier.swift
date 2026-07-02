import AppKit
import ApplicationServices

/// Best-effort ground truth for "did the text we just inserted actually land in the
/// target field?" — the failure signal every future self-healing insertion behavior
/// keys off. After `TextInjector.insert` synthesizes ⌘V it optimistically returns
/// `.inserted`; this verifier polls the focused field's Accessibility value for a
/// short window and reports one of three verdicts.
///
/// The doctrine here deliberately mirrors `ImplicitSelectionGate`'s header: AX reads
/// false-negative on Electron/web apps (VS Code, Slack, Chrome, ChatGPT) — exactly
/// the apps people dictate into most. So this **fails open**: a field we simply
/// cannot read is reported `.unverifiable`, NEVER `.notLanded`. Only a field that IS
/// readable, where our text never appears across the whole window, earns `.notLanded`.
/// A caller must treat `.unverifiable` as "no signal" (assume success), never as a
/// failure — otherwise every paste into Slack would look like a miss.
///
/// The verdict logic is a pure function over a sequence of poll reads
/// (`decide(from:inserted:)`), so it's fully unit-testable without live AX; the async
/// `verify` is a thin shell that gathers the reads on the main actor and delegates.
///
/// This type adds detection only — it is intentionally NOT wired into the insert path
/// (that's a later package). Nothing about insertion behavior changes by its presence.
@MainActor
enum InsertionVerifier {

    /// Whether an insertion is judged to have landed in the target field.
    enum Verdict: Sendable, Equatable {
        /// The inserted text was found in the field's readable value.
        case landed
        /// The field WAS readable, but the inserted text never appeared across the
        /// whole watch window — a genuine (best-effort) miss.
        case notLanded
        /// No Accessibility value was reachable at any poll (Electron/web false-
        /// negative, or nothing focused). No signal — callers must fail open.
        case unverifiable
    }

    /// One field read during the verification window: either the field's current
    /// value, or `.unreadable` when no AX value was reachable that poll.
    enum ReadResult: Sendable, Equatable {
        case value(String)
        case unreadable
    }

    /// How many times we re-read the field before deciding.
    private static let pollCount = 4
    /// Gap between reads. 4 × 250ms ≈ 1s — long enough for the target to consume the
    /// async paste, short enough to be a cheap best-effort check.
    private static let pollInterval: Duration = .milliseconds(250)

    /// Poll the focused field and decide whether `inserted` landed. Reads on the main
    /// actor via the shared `AXFieldReader`, then hands the sequence of reads to the
    /// pure `decide` for the verdict. Returns early the moment the text is seen.
    static func verify(inserted: String) async -> Verdict {
        let needle = inserted
        guard !needle.isEmpty else { return .unverifiable }

        var reads: [ReadResult] = []
        for _ in 0..<pollCount {
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { return decide(from: reads, inserted: needle) }

            if let (_, value) = AXFieldReader.focusedElementValue() {
                reads.append(.value(value))
                // Fast-path: once we've positively confirmed the landing there's no
                // reason to keep polling.
                if AXFieldReader.looseContains(value, needle) {
                    return .landed
                }
            } else {
                reads.append(.unreadable)
            }
        }
        return decide(from: reads, inserted: needle)
    }

    /// The pure verdict function. Given the reads collected over the window (in
    /// order) and the text we inserted, classify the outcome:
    ///   • `.landed`        — any readable value loosely contains the inserted text.
    ///   • `.notLanded`     — at least one readable value, but none contained it.
    ///   • `.unverifiable`  — every read was unreadable (or there were no reads).
    ///
    /// "Loosely contains" uses `AXFieldReader.looseContains`, so reformatting the
    /// target applies on paste (smart quotes, en/em dashes, non-breaking spaces)
    /// still counts as landed. Fails open by construction: no readable value ⇒
    /// `.unverifiable`, never `.notLanded`.
    static func decide(from reads: [ReadResult], inserted: String) -> Verdict {
        var sawReadableValue = false
        for read in reads {
            guard case let .value(value) = read else { continue }
            sawReadableValue = true
            if AXFieldReader.looseContains(value, inserted) {
                return .landed
            }
        }
        return sawReadableValue ? .notLanded : .unverifiable
    }
}
