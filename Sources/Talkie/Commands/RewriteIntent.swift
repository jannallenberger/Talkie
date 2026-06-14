import Foundation

/// Rewrites the current selection per a spoken instruction — "make this a bullet
/// list", "fix the grammar", "translate to German", "make it more concise"
/// (feature 08) — using the injected `Summarizer` (on-device by default; the
/// opt-in Claude bridge when enabled). Mutating → always previews, so a bad
/// rewrite is reversible (undo restores the prior selection).
struct RewriteIntent: CommandIntent {
    let id = "rewrite"
    let needsSelection = true
    let isMutating = true

    func run(_ ctx: CommandContext) async -> CommandResult? {
        let selection = (ctx.selection ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { return nil }
        guard let rewritten = await ctx.summarizer.generate(
            instructions: Self.instructions(for: ctx.spokenCommand),
            input: selection
        ), !rewritten.isEmpty else { return nil }
        return CommandResult(replacement: rewritten, preview: true, undoToken: selection)
    }

    /// Turn the spoken command into a system instruction. The command itself is the
    /// instruction; the wrapper just pins "output only the transformed text".
    static func instructions(for spoken: String) -> String {
        """
        You transform the user's selected text per an instruction. Output ONLY the \
        transformed text — no preamble, no quotes, no explanation. Preserve meaning \
        and do not invent facts. Instruction: \
        \(spoken.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }
}
