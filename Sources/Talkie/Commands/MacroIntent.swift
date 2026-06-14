import Foundation

/// The simplest `CommandIntent`: insert a stored macro expansion (feature 11).
/// Non-mutating — it inserts at the cursor rather than transforming a selection —
/// so no preview is needed. The router constructs it with the already-resolved
/// expansion (tokens filled).
struct MacroIntent: CommandIntent {
    let id = "insert-macro"
    let needsSelection = false
    let isMutating = false

    let expansion: String

    func run(_ ctx: CommandContext) async -> CommandResult? {
        let text = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return CommandResult(replacement: text, preview: false, undoToken: nil)
    }
}
