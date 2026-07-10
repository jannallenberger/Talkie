import Foundation

/// One line in the dashboard Scratchpad — a note, or a checkbox task. Persisted as
/// a flat array in `scratchpad.json`. The on-disk shape is deliberately a plain,
/// stable contract: an MCP tool may read this file later, and the L2-b AI-auto-add
/// lane (deferred) writes the same rows with `addedByAI = true`. That field is
/// carried now — unused by this package — so the file format never changes when
/// L2-b lands.
struct ScratchpadLine: Codable, Identifiable, Sendable {
    let id: UUID
    var text: String
    /// True once the line reads as a checkbox task (a leading `- ` or `[]`/`[ ]`
    /// prefix promoted it). Notes stay `false`.
    var isTask: Bool
    /// Only meaningful when `isTask`; a checked-off task strikes through.
    var done: Bool
    let createdUnix: Double
    /// The dictation this line was rescued from (`AppDelegate`'s `.leftOnClipboard`
    /// sink), or `nil` for a line the user typed here. Drives true-delete: deleting
    /// a dictation purges the lines it sourced, but typed lines survive "Clear
    /// everything" — the "rules you taught stay" contract.
    let sourceDictationID: String?
    /// Reserved for the deferred L2-b AI-auto-add lane. Always `false` today.
    var addedByAI: Bool
}

/// The dashboard Scratchpad: a zero-chrome list of notes and checkbox tasks, plus
/// the landing spot for transcripts that couldn't be pasted (they'd otherwise
/// vanish). `@MainActor`, `ObservableObject`, constructor-injected like the other
/// stores. Persists a flat array in `scratchpad.json`; a corrupt or missing file
/// decodes to empty and never crashes.
@MainActor
final class ScratchpadStore: ObservableObject {
    @Published private(set) var lines: [ScratchpadLine] = []

    private let fileURL: URL

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("scratchpad.json")
        load()
    }

    // MARK: Mutation

    /// Append a line. `text` is prefix-parsed: a leading `- ` (note→task) or a
    /// `[]` / `[ ]` / `[x]` marker makes it a checkbox task, with the marker
    /// stripped from the stored text. `[x]` also lands pre-checked. Pass a
    /// `sourceDictationID` when this is a rescued transcript so it can be purged
    /// with its dictation later.
    func addLine(_ text: String,
                 sourceDictationID: String? = nil,
                 addedByAI: Bool = false,
                 nowUnix: Double = Date().timeIntervalSince1970) {
        let parsed = Self.parse(text)
        let line = ScratchpadLine(
            id: UUID(),
            text: parsed.text,
            isTask: parsed.isTask,
            done: parsed.done,
            createdUnix: nowUnix,
            sourceDictationID: sourceDictationID,
            addedByAI: addedByAI
        )
        lines.append(line)
        save()
    }

    /// Replace a line's text, re-running prefix parsing so typing `- ` (or `[]`) in
    /// front of an existing note promotes it to a task in place. Removing the marker
    /// does NOT demote a task back to a note — a deliberate one-way promotion so a
    /// checked box can't silently lose its state on an unrelated edit.
    func update(id: UUID, text: String) {
        guard let idx = lines.firstIndex(where: { $0.id == id }) else { return }
        let parsed = Self.parse(text)
        lines[idx].text = parsed.text
        if parsed.isTask { lines[idx].isTask = true }
        save()
    }

    /// Toggle a task's checkbox. No-op on a note.
    func toggleDone(id: UUID) {
        guard let idx = lines.firstIndex(where: { $0.id == id }), lines[idx].isTask else { return }
        lines[idx].done.toggle()
        save()
    }

    func delete(id: UUID) {
        guard lines.contains(where: { $0.id == id }) else { return }
        lines.removeAll { $0.id == id }
        save()
    }

    // MARK: True-delete (paired with MemoryView)

    /// Remove every line rescued from one dictation — called when that dictation is
    /// deleted from history, so a deleted transcript can't linger here.
    func purge(sourceID: String) {
        guard lines.contains(where: { $0.sourceDictationID == sourceID }) else { return }
        lines.removeAll { $0.sourceDictationID == sourceID }
        save()
    }

    /// Remove every dictation-sourced line, keeping the ones the user typed here.
    /// Called from "Clear everything": rescued transcripts are part of your dictation
    /// history and go with it, but notes/tasks you wrote yourself are yours to keep.
    func purgeAllDictationSourced() {
        guard lines.contains(where: { $0.sourceDictationID != nil }) else { return }
        lines.removeAll { $0.sourceDictationID != nil }
        save()
    }

    /// Wipe everything (used by resets/tests).
    func clearAll() {
        guard !lines.isEmpty else { return }
        lines = []
        save()
    }

    func reset() { clearAll() }

    // MARK: Prefix parsing (pure, static)

    /// The result of reading a row's leading marker: the display text with the
    /// marker stripped, whether it's a task, and (for `[x]`) whether it starts done.
    struct Parsed: Equatable { var text: String; var isTask: Bool; var done: Bool }

    /// Promote a row to a checkbox task from a leading marker:
    ///   • `- ` (dash + space)            → task, unchecked
    ///   • `[]` / `[ ]`                   → task, unchecked
    ///   • `[x]` / `[X]`                  → task, checked
    /// The marker is stripped from the stored text and one following space is eaten.
    /// Anything else is a plain note. Pure so the parser and its tests can't drift.
    static func parse(_ raw: String) -> Parsed {
        let trimmedLeading = raw.drop(while: { $0 == " " })

        // "- " bullet → task.
        if trimmedLeading.hasPrefix("- ") {
            let body = String(trimmedLeading.dropFirst(2))
            return Parsed(text: body, isTask: true, done: false)
        }
        // Checkbox markers "[]" / "[ ]" / "[x]" / "[X]".
        for (marker, done) in [("[]", false), ("[ ]", false), ("[x]", true), ("[X]", true)] {
            if trimmedLeading.hasPrefix(marker) {
                var body = trimmedLeading.dropFirst(marker.count)
                if body.first == " " { body = body.dropFirst() }
                return Parsed(text: String(body), isTask: true, done: done)
            }
        }
        return Parsed(text: raw, isTask: false, done: false)
    }

    // MARK: Persistence

    private func load() {
        guard let decoded = StoreLoad.loadJSONWithQuarantine([ScratchpadLine].self, from: fileURL) else { return }
        lines = decoded
    }

    /// Atomic write of the flat array. Encode failure is swallowed (never crash on
    /// a save), matching the other stores.
    private func save() {
        guard let data = try? JSONEncoder().encode(lines) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
