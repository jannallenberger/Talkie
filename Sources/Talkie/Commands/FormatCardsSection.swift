import SwiftUI

extension AppSettings {
    /// Whether a built-in format is switched on (not in the off list).
    func isFormatOn(_ preset: FormatPreset) -> Bool { !disabledPresetSet.contains(preset) }

    func setFormat(_ preset: FormatPreset, on: Bool) {
        var set = Set(disabledFormatPresets)
        if on { set.remove(preset.rawValue) } else { set.insert(preset.rawValue) }
        disabledFormatPresets = set.sorted()
    }

    /// The languages whose wordings the Commands page shows first.
    var commandPhraseLanguages: [String] {
        FormatPhraseCatalog.languages(spoken: spokenLanguages, uiLanguage: Bundle.main.preferredLocalizations.first)
    }
}

/// The "Formats" group: a card per built-in format, per user-made command, and the "+"
/// card. Each card shows its wordings and has its own on/off switch; opening a card
/// shows every wording and where to add your own.
struct FormatCardsSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var macros: MacroStore

    /// The card whose popover is open (not a "selected" or "active" look).
    @State private var open: CommandCardID?

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: Theme.Space.gridGap, alignment: .top)]
    private var uiLanguageCode: String? { Bundle.main.preferredLocalizations.first }
    private var userCommands: [UserCommand] { UserCommandLibrary.all(settings: settings, macros: macros) }
    private var globalOn: Bool { settings.formatCommandsEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            TalkieSectionLabel(
                title: "Formats".loc,
                subtitle: "Each format has its own switch. Open a card to see every way to say it and to add your own wording.".loc)
            if !globalOn {
                TalkieStatusLine(text: "Commands are off, so these formats do nothing until you turn commands on above. Your dictation is not affected.".loc,
                                 tone: .warning)
                    .padding(.horizontal, 4)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.gridGap) {
                ForEach(FormatPreset.allCases) { presetCard($0) }
                ForEach(userCommands) { userCard($0) }
                newCard
            }
            // The whole grid reads as "not active" while commands are off.
            .opacity(globalOn ? 1 : 0.6)
        }
    }

    private func isOpen(_ id: CommandCardID) -> Binding<Bool> {
        Binding(get: { open == id }, set: { if !$0, open == id { open = nil } })
    }

    private func presetCard(_ preset: FormatPreset) -> some View {
        let id = CommandCardID.preset(preset)
        return FormatCommandCard(
            illustration: .preset(preset), name: preset.displayName,
            phrases: FormatPhraseCatalog.phrases(preset, languages: settings.commandPhraseLanguages,
                                                 own: settings.formatSynonyms[preset.rawValue] ?? []),
            slower: preset.usesModel,
            isOn: Binding(get: { settings.isFormatOn(preset) }, set: { settings.setFormat(preset, on: $0) }),
            helpOpen: String(format: "Show %@".loc, preset.displayName),
            onOpen: { open = id })
        .popover(isPresented: isOpen(id), arrowEdge: .bottom) {
            FormatCommandDetail(preset: preset, settings: settings, macros: macros, uiLanguageCode: uiLanguageCode)
        }
    }

    private func userCard(_ command: UserCommand) -> some View {
        let id = CommandCardID.user(command.id)
        return FormatCommandCard(
            illustration: .user(command.action), name: command.name, phrases: command.phrases,
            slower: command.usesModel,
            isOn: Binding(get: { command.enabled }, set: { on in
                var copy = command
                copy.enabled = on
                UserCommandLibrary.save(copy, settings: settings, macros: macros)
            }),
            helpOpen: String(format: "Edit %@".loc, command.name),
            onOpen: { open = id })
        .popover(isPresented: isOpen(id), arrowEdge: .bottom) {
            UserCommandEditor(settings: settings, macros: macros, existing: command) { open = nil }
        }
    }

    private var newCard: some View {
        FormatCommandCard(illustration: .newCommand, name: "New command".loc, phrases: [], slower: false,
                          isOn: nil, caption: "Make your own".loc,
                          helpOpen: "Make your own command".loc,
                          onOpen: { open = .new })
        .accessibilityLabel("New command".loc)
        .popover(isPresented: isOpen(.new), arrowEdge: .bottom) {
            UserCommandEditor(settings: settings, macros: macros, existing: nil) { open = nil }
        }
    }
}

// MARK: - Built-in command detail

/// A format card's popover: on/off, EVERY wording that works (the user's languages
/// first, the others a click away), a one-line example, and "Add your own wording".
struct FormatCommandDetail: View {
    let preset: FormatPreset
    @ObservedObject var settings: AppSettings
    @ObservedObject var macros: MacroStore
    let uiLanguageCode: String?

    @State private var draft = ""
    @State private var problem: FormatPhraseBook.Refusal?
    @State private var showOthers = false

    private var isOn: Binding<Bool> {
        Binding(get: { settings.isFormatOn(preset) }, set: { settings.setFormat(preset, on: $0) })
    }

    private var synonyms: Binding<[String]> {
        Binding(get: { settings.formatSynonyms[preset.rawValue] ?? [] },
                set: { settings.formatSynonyms[preset.rawValue] = $0.isEmpty ? nil : $0 })
    }

    private var shownLanguages: [String] { settings.commandPhraseLanguages }

    /// (language code, wordings) groups: the user's languages, then — on request — the rest.
    private var groups: [(code: String, phrases: [String])] {
        var codes = shownLanguages
        if showOthers { codes += FormatPhraseCatalog.otherLanguages(than: shownLanguages) }
        var seen = Set<String>()
        return codes.compactMap { code in
            // A wording already listed under an earlier language is not repeated.
            let fresh = FormatPhrases.phrases(preset, language: code).filter { phrase in
                let key = FormatPhraseMatcher.normalizedTokens(phrase).joined()
                return !key.isEmpty && seen.insert(key).inserted
            }
            return fresh.isEmpty ? nil : (code, fresh)
        }
    }

    private func languageName(_ code: String) -> String {
        let ui = Locale(identifier: uiLanguageCode ?? "en")
        return (ui.localizedString(forLanguageCode: code) ?? code).capitalized(with: ui)
    }

    var body: some View {
        TalkiePopover(title: preset.displayName, width: Theme.Width.popoverWide) {
            if preset.usesModel {
                TalkieTag(text: "slower — uses the on-device model".loc)
            }
            TalkieSwitchRow(title: "Use this command".loc,
                            subtitle: "When it's off, saying it does nothing special.".loc,
                            isOn: isOn)
            TalkiePopoverDivider()
            TalkieField(label: "You can say".loc,
                        help: "Any of these works, in any language you speak — you can mix them. Words around it, like “please” or “as a”, are fine.".loc) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups, id: \.code) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: languageName(group.code))
                                .font(.talkieHeading(11.5, weight: .medium))
                                .foregroundStyle(Theme.inkTertiary)
                            FlowLayout(spacing: 6) {
                                ForEach(group.phrases, id: \.self) { TalkieTag(verbatim: $0) }
                            }
                        }
                    }
                    Button((showOthers ? "Hide other languages" : "Show other languages").loc) {
                        showOthers.toggle()
                    }
                    .buttonStyle(.talkie(.secondary, size: .small))
                }
            }
            TalkieField(label: "For example".loc) {
                Text(verbatim: "\(Self.oneLine(preset.example.before))  \u{2192}  \(Self.oneLine(preset.example.after))")
                    .font(.talkieHeading(12, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TalkiePopoverDivider()
            TalkieField(label: "Add your own wording".loc,
                        help: "It works like the built-in ones. Your own words can be removed again with the ×.".loc) {
                PhraseListEditor(phrases: synonyms, placeholder: "Your own wording".loc,
                                 draft: $draft, problem: $problem, addIsPrimary: true) { phrase in
                    UserCommandLibrary.book(settings: settings, macros: macros)
                        .refusal(for: phrase, owner: .preset(preset))
                }
            }
        }
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}
