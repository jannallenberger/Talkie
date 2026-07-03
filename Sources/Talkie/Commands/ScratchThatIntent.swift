import Foundation

/// "scratch that" / "delete that" — remove the text you just dictated (B9). Unlike
/// a rewrite, this never runs the on-device model and never asks for a live AX
/// selection: its target is always the last dictation (threaded in as
/// `ctx.lastInserted`), so `needsSelection` is false. It's mutating, but B9's edits
/// execute IMMEDIATELY with a tap-optional Undo pill (byte-exact, and the RSI user
/// this feature is for can't reach for a confirm tap) rather than the two-step
/// preview a fuzzy LLM rewrite requires — so the actual delete + undo live in a
/// dedicated branch of the dispatch site (`AppDelegate`), and this intent's job is to
/// (a) claim the utterance during routing and (b) expose the computed result.
///
/// Eligibility (an eligible `lastInserted` exists at all) is enforced by the router
/// via `ImplicitSelectionGate` BEFORE this intent is ever constructed; if no eligible
/// last dictation exists, "scratch that" is never routed here and inserts literally.
struct ScratchThatIntent: CommandIntent {
    let id = "scratch-that"
    let needsSelection = false
    let isMutating = true

    /// The just-inserted text this scratch targets, captured at routing time. The
    /// result is always the empty string (delete everything), but carrying the
    /// original lets the dispatch site size the backward delete and re-insert it on
    /// Undo without re-reading history.
    let original: String

    /// A `CommandResult` is produced for protocol conformance / test symmetry, but the
    /// B9 execution branch reads `original` directly (it deletes rather than inserts a
    /// replacement). The empty replacement is the honest "there is nothing to type"
    /// signal, matching how side-effect intents already report.
    func run(_ ctx: CommandContext) async -> CommandResult? {
        CommandResult(replacement: "", preview: false, undoToken: original)
    }
}
