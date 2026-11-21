import Foundation

/// The user-made commands, wherever they are stored: fixed-text commands are the
/// snippets in `MacroStore` (so old snippets keep working as their own dictation),
/// everything else is in `AppSettings.userFormatCommands`. One place to list, save
/// and delete them, and to build the matcher's phrase book.
@MainActor
enum UserCommandLibrary {

    static func all(settings: AppSettings, macros: MacroStore) -> [UserCommand] {
        settings.userFormatCommands + macros.macros.map(\.userCommand)
    }

    /// Create or update. A command whose kind changed between "insert a fixed text"
    /// and anything else moves to the other store under the same id.
    static func save(_ command: UserCommand, settings: AppSettings, macros: MacroStore) {
        if command.isInsertion {
            settings.userFormatCommands.removeAll { $0.id == command.id }
            var macro = Macro(command)
            if let existing = macros.macros.first(where: { $0.id == command.id }), existing.name == nil,
               command.name == existing.trigger {
                macro.name = nil   // an old snippet keeps its name-less shape
            }
            macros.upsert(macro)
        } else {
            if macros.macros.contains(where: { $0.id == command.id }) { macros.delete(id: command.id) }
            if let i = settings.userFormatCommands.firstIndex(where: { $0.id == command.id }) {
                settings.userFormatCommands[i] = command
            } else {
                settings.userFormatCommands.append(command)
            }
        }
    }

    static func delete(_ id: UUID, settings: AppSettings, macros: MacroStore) {
        settings.userFormatCommands.removeAll { $0.id == id }
        if macros.macros.contains(where: { $0.id == id }) { macros.delete(id: id) }
    }

    /// The phrase book for the current settings.
    static func book(settings: AppSettings, macros: MacroStore) -> FormatPhraseBook {
        FormatPhraseBook(disabledPresets: settings.disabledPresetSet, synonyms: settings.formatSynonyms,
                         userCommands: all(settings: settings, macros: macros))
    }
}
