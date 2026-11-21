import Foundation

/// A user-defined voice macro: say the trigger, insert the expansion. Matched
/// **whole-utterance** (no fuzzy / substring matching) so it never fires inside
/// normal dictation — the roadmap's resolution to the command-false-positive risk.
///
/// On the Commands page a macro is a user-made "insert a fixed text" command: it
/// also works said with the format key held, mid-dictation. `name`, `synonyms` and
/// `enabled` were added later and are optional, so every existing macros.json
/// decodes unchanged (nil = no name / no synonyms / on).
struct Macro: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: String
    var expansion: String
    var name: String?
    var synonyms: [String]?
    var enabled: Bool?

    var isEnabled: Bool { enabled ?? true }
    /// Every phrase that triggers it: the trigger first, then the synonyms.
    var phrases: [String] { [trigger] + (synonyms ?? []) }
    var displayName: String {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? trigger : n
    }

    /// The user-made command this macro is on the Commands page.
    var userCommand: UserCommand {
        UserCommand(id: id, name: displayName, phrases: phrases, action: .insert(text: expansion),
                    enabled: isEnabled)
    }

    /// A fixed-text user command stored as a macro (same id, so edits keep it).
    init(_ command: UserCommand) {
        id = command.id
        trigger = command.phrases.first ?? command.name
        if case .insert(let text) = command.action { expansion = text } else { expansion = "" }
        name = command.name
        synonyms = Array(command.phrases.dropFirst())
        enabled = command.enabled
    }

    init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

/// Stores voice macros and resolves a spoken phrase to its expansion. On-device
/// only. `{date}` / `{today}` / `{time}` tokens are filled at insert time.
@MainActor
final class MacroStore: ObservableObject {
    @Published var macros: [Macro] = []

    private let fileURL: URL

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("macros.json")
        load()
    }

    /// Resolve a spoken phrase to a macro expansion (tokens filled), or nil if there
    /// is no whole-utterance match. Case-insensitive; ignores surrounding
    /// whitespace and trailing punctuation.
    func match(_ spoken: String, now: Date = Date()) -> String? {
        let key = Self.normalize(spoken)
        guard !key.isEmpty,
              let macro = macros.first(where: { m in
                  m.isEnabled && m.phrases.contains { Self.normalize($0) == key }
              }) else { return nil }
        return resolveTokens(macro.expansion, now: now)
    }

    func add(trigger: String, expansion: String) {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !e.isEmpty else { return }
        macros.append(Macro(trigger: t, expansion: e))
        save()
    }

    /// Insert or replace (by id) — the Commands page's create/edit of a fixed-text command.
    func upsert(_ macro: Macro) {
        if let i = macros.firstIndex(where: { $0.id == macro.id }) {
            macros[i] = macro
        } else {
            macros.append(macro)
        }
        save()
    }

    func delete(id: UUID) {
        macros.removeAll { $0.id == id }
        save()
    }

    func delete(_ macro: Macro) {
        macros.removeAll { $0.id == macro.id }
        save()
    }

    // MARK: Tokens

    func resolveTokens(_ expansion: String, now: Date = Date()) -> String {
        guard expansion.contains("{") else { return expansion }
        let dateF = DateFormatter(); dateF.dateStyle = .long; dateF.timeStyle = .none
        let timeF = DateFormatter(); timeF.dateStyle = .none; timeF.timeStyle = .short
        return expansion
            .replacingOccurrences(of: "{date}", with: dateF.string(from: now))
            .replacingOccurrences(of: "{today}", with: dateF.string(from: now))
            .replacingOccurrences(of: "{time}", with: timeF.string(from: now))
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.,!?;:"))
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Macro].self, from: data) else { return }
        macros = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(macros) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
