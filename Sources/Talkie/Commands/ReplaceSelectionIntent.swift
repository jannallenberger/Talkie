import Foundation

/// Replaces the current selection with provided text verbatim — the "re-dictate
/// this selection" path (feature 12). Mutating → previews and keeps an undo token
/// (the prior selection). The replacement is whatever the user just dictated; the
/// router constructs it explicitly (edit-by-voice mode), so it isn't auto-selected
/// from a plain spoken phrase.
struct ReplaceSelectionIntent: CommandIntent {
    let id = "replace-verbatim"
    let needsSelection = true
    let isMutating = true

    let replacement: String

    func run(_ ctx: CommandContext) async -> CommandResult? {
        let text = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return CommandResult(replacement: text, preview: true, undoToken: ctx.selection)
    }
}
