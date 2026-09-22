import SwiftUI

/// The dashboard hero card: a zero-chrome adaptive Scratchpad. Notes and checkbox
/// tasks live as editable rows bound to `ScratchpadStore`; typing a leading `- ` or
/// `[]` promotes a row to a task, tapping the box toggles it (done rows strike
/// through), and Return commits the row and drops a fresh one below. Dictating into
/// it needs no special plumbing — the user focuses a row and dictates like any text
/// field. Failed insertions also land here (see AppDelegate's `.leftOnClipboard`
/// rescue), so nothing you said quietly disappears.
struct ScratchpadCard: View {
    @ObservedObject var scratchpad: ScratchpadStore

    /// Which row currently owns keyboard focus (nil = the trailing "new line" row).
    @FocusState private var focusedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Scratchpad")

            if scratchpad.lines.isEmpty {
                // EmptyHint renders its `text` via `Text(String)`, which does NOT
                // auto-localize (only string *literals* do), so localize explicitly.
                EmptyHint(icon: "square.and.pencil",
                          text: "Jot a note or a task here — type “- ” for a checkbox. Anything Talkie can’t paste lands here too, so it’s never lost.".loc)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(scratchpad.lines) { line in
                    ScratchpadRow(
                        line: line,
                        isFocused: focusedID == line.id,
                        onToggle: { scratchpad.toggleDone(id: line.id) },
                        onCommit: { newText in commit(id: line.id, text: newText) },
                        onSubmit: { insertRowBelow() },
                        onDelete: { scratchpad.delete(id: line.id) }
                    )
                    .focused($focusedID, equals: line.id)
                }

                // The always-present composer row: type here to add a line, Return to
                // keep going. Kept out of the store until it has content so an empty
                // trailing row is never persisted.
                NewLineRow { text in
                    scratchpad.addLine(text)
                    // Focus follows into the freshly added row for a natural flow.
                    focusedID = scratchpad.lines.last?.id
                }
                .focused($focusedID, equals: nil)
            }
        }
        .talkieCard()
    }

    /// Commit an edited row's text back to the store (re-parsing prefixes). An empty
    /// commit deletes the row, so clearing a line and moving on tidies up after
    /// itself.
    private func commit(id: UUID, text: String) {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            scratchpad.delete(id: id)
        } else {
            scratchpad.update(id: id, text: text)
        }
    }

    /// Return in a row inserts a new empty line below and moves focus to the
    /// composer row (nil), so the next keystroke starts a fresh line.
    private func insertRowBelow() {
        focusedID = nil
    }
}

// MARK: - Row

/// One editable Scratchpad line. Holds a local edit buffer so keystrokes don't
/// thrash the store; commits on focus loss and on Return. A task shows a tappable
/// checkbox; a done task strikes through.
private struct ScratchpadRow: View {
    let line: ScratchpadLine
    let isFocused: Bool
    let onToggle: () -> Void
    let onCommit: (String) -> Void
    let onSubmit: () -> Void
    let onDelete: () -> Void

    @State private var draft: String
    @State private var hovering = false

    init(line: ScratchpadLine, isFocused: Bool,
         onToggle: @escaping () -> Void, onCommit: @escaping (String) -> Void,
         onSubmit: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.line = line
        self.isFocused = isFocused
        self.onToggle = onToggle
        self.onCommit = onCommit
        self.onSubmit = onSubmit
        self.onDelete = onDelete
        _draft = State(initialValue: line.text)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if line.isTask {
                Button(action: onToggle) {
                    Image(systemName: line.done ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(line.done ? Theme.positive : Theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .help(line.done ? "Mark as not done" : "Mark as done")
            } else if line.addedByAI {
                // L2-b: a line Talkie suggested from your dictation — a subtle coral
                // sparkle marks it as auto-added, not typed by you. It's a visible,
                // editable, deletable suggestion (and purges with its dictation), never
                // a silent commitment.
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.coral.opacity(0.85))
                    .frame(width: 14)
                    .help("Suggested by \(Brand.displayName) from your dictation — edit or delete it freely.")
                    .accessibilityLabel("Suggested by \(Brand.displayName)")
            } else {
                // A dim dot keeps notes aligned with tasks without a checkbox.
                Circle()
                    .fill(Theme.inkTertiary.opacity(0.35))
                    .frame(width: 4, height: 4)
                    .padding(.leading, 5)
                    .padding(.trailing, 5)
            }

            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(line.done ? Theme.inkTertiary : Theme.ink)
                .strikethrough(line.done, color: Theme.inkTertiary)
                .onSubmit {
                    onCommit(draft)
                    onSubmit()
                }
                // Commit when focus leaves the row.
                .onChange(of: isFocused) { _, nowFocused in
                    if !nowFocused { onCommit(draft) }
                }
                // Keep the buffer in step if the store rewrites the line (e.g. a
                // prefix promotion stripped the marker on commit).
                .onChange(of: line.text) { _, newValue in
                    if newValue != draft { draft = newValue }
                }

            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .help("Delete this line")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The trailing composer row: an empty field that, once you type and press Return
/// (or it loses focus with content), hands its text to the store as a new line and
/// clears itself for the next one.
private struct NewLineRow: View {
    let onAdd: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary.opacity(0.7))
                .frame(width: 14)
            TextField("Add a note or task…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.ink)
                .onSubmit { flush() }
        }
        .padding(.vertical, 3)
    }

    private func flush() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        onAdd(draft)
        draft = ""
    }
}
