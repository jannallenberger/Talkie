import Foundation

/// When a rewrite-style command ("make this a list") has no live AX text
/// selection to act on — the common case, since the natural voice workflow is
/// "dictate, pause, say a follow-up command" and nothing is ever manually
/// selected in that flow — this decides whether the most recent dictation is
/// safe to treat as an implicit selection instead of giving up. Pure and
/// `Sendable` so it's unit-testable without AX/HistoryStore/MainActor
/// plumbing, mirroring `CrossSurfaceParser`'s shape.
///
/// Deliberately does NOT verify the target field still contains this text via
/// Accessibility before allowing a replace — `TextInjector.hasEditableFocus()`
/// already documents that AX reads false-negative on Electron/web apps (VS
/// Code, Slack, Chrome, ChatGPT), exactly the apps this feature most needs to
/// work in. A second, stricter AX read would be equally unreliable there,
/// trading a rare-by-construction miss (time + app gating) for a
/// false-confidence check that fails silently where it matters most. The real
/// safety net is this gate plus the mandatory "replacing: …" preview shown
/// before any text is touched (see `HUD.showCommandPreview`).
enum ImplicitSelectionGate {
    /// How recently the last dictation must have landed to still be assumed
    /// "what's on screen right now." Covers "dictate → re-read → decide to fix
    /// it," which routinely runs past 10-20s once reading is factored in;
    /// short enough that it rarely spans an unrelated context switch.
    static let maxAge: TimeInterval = 45

    /// Returns the entry to use as an implicit selection, or `nil` if none of
    /// the conditions hold. Every check fails CLOSED on missing data (a
    /// pre-migration entry with no recorded `bundleID` is never eligible just
    /// because it's recent) rather than guessing.
    static func eligible(
        lastEntry: DictationEntry?,
        now: Date,
        currentTarget: TargetApp
    ) -> DictationEntry? {
        guard let entry = lastEntry else { return nil }
        guard now.timeIntervalSince(entry.date) <= maxAge else { return nil }
        guard let lastBundleID = entry.bundleID, let currentBundleID = currentTarget.bundleID,
              lastBundleID == currentBundleID else { return nil }
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return entry
    }
}
