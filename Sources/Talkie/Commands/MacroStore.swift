import Foundation

/// A user-defined voice macro: say the trigger, insert the expansion. Matched
/// **whole-utterance** (no fuzzy / substring matching) so it never fires inside
/// normal dictation — the roadmap's resolution to the command-false-positive risk.
struct Macro: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: String
    var expansion: String
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
              let macro = macros.first(where: { Self.normalize($0.trigger) == key }) else { return nil }
        return resolveTokens(macro.expansion, now: now)
    }

    func add(trigger: String, expansion: String) {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !e.isEmpty else { return }
        macros.append(Macro(trigger: t, expansion: e))
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
