import Foundation

/// `replace <X> with <Y>` / `change <X> to <Y>` — fix a word or phrase in the text
/// you just dictated, in place (B9). Fully deterministic: no on-device model, no live
/// AX selection (the target is the last dictation, threaded in as `ctx.lastInserted`),
/// so `needsSelection` is false.
///
/// The FALSE-POSITIVE KILL SWITCH is enforced twice, fail-closed: the router only
/// constructs this intent when an eligible `lastInserted` exists AND X literally
/// occurs (case-insensitive, word-bounded) in it — so "replace the filter with a new
/// cartridge" is a command only when "the filter" is actually in what you just
/// dictated. This intent additionally recomputes the edit from `find`/`replacement`
/// against `original`; if the find-word somehow isn't present at run time it returns
/// nil, and the dispatch site inserts the phrase literally (current behaviour).
///
/// Like `ScratchThatIntent`, the real in-place edit + tap-optional Undo pill execute
/// in a dedicated branch of the dispatch site (`AppDelegate`): B9 edits apply
/// immediately (byte-exact; the RSI user can't reach a confirm tap), not via the
/// two-step preview an LLM rewrite needs. This intent claims the utterance during
/// routing and exposes the computed rightmost-occurrence swap.
struct ReplaceWordIntent: CommandIntent {
    let id = "replace-word"
    let needsSelection = false
    let isMutating = true

    /// The just-inserted text this edit targets, captured at routing time.
    let original: String
    /// The spoken find-word/phrase (X) and its replacement (Y).
    let find: String
    let replacement: String

    /// The edited text — the rightmost word-bounded occurrence of `find` in `original`
    /// swapped for `replacement` — or nil if `find` isn't present (the dispatch site
    /// then inserts literally). Computed by the same pure helper the routing gate and
    /// the tests use, so routing, execution, and tests can never disagree.
    var editedText: String? {
        EditCommandParser.edited(.replace(find: find, replacement: replacement), in: original)
    }

    func run(_ ctx: CommandContext) async -> CommandResult? {
        guard let edited = editedText else { return nil }
        return CommandResult(replacement: edited, preview: false, undoToken: original)
    }
}
