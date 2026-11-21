import SwiftUI

/// "Commands", for people who have never heard of a voice command: one sentence, one
/// "how it works" strip, a grid of format cards (the last one, "+", makes your own),
/// the spoken edit commands as a second small group, and an Options card.
struct CommandsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var macros: MacroStore
    // Kept for the call site's shape; the page no longer runs commands itself.
    let commandRouter: CommandRouter
    let hud: HUDController
    let meetingStore: MeetingStore

    private let editColumns = [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.gridGap, alignment: .top)]
    private var uiLanguageCode: String? { Bundle.main.preferredLocalizations.first }

    var body: some View {
        SubPage(title: "Commands") {
            CommandsMasterCard(settings: settings)
            HowItWorksStrip(dictationKey: settings.activationKey, formatKey: settings.effectiveFormatCommandKey)
            FormatCardsSection(settings: settings, macros: macros)
            editGroup
            SpokenPunctuationCard(settings: settings, uiLanguageCode: uiLanguageCode)
            optionsCard
        }
    }

    // MARK: Edit selected text

    private var editGroup: some View {
        VStack(alignment: .leading, spacing: 9) {
            TalkieSectionLabel(
                title: "Edit selected text".loc,
                subtitle: "Say one of these as its own dictation. With nothing selected, it changes what you just dictated.".loc)
            LazyVGrid(columns: editColumns, alignment: .leading, spacing: Theme.Space.gridGap) {
                ForEach(EditCommandKind.allCases, id: \.self) { kind in
                    EditCommandCard(kind: kind)
                }
            }
        }
    }

    // MARK: Options

    private var optionsCard: some View {
        SettingsCard(header: "Options") {
            SettingsToggleRow(
                title: "Ask about your meetings".loc,
                subtitle: "Requests like \u{201C}email Sarah the action items from my last meeting\u{201D} run as a command, with a preview first. Uses only what is on this Mac.".loc,
                isOn: $settings.crossSurfaceCommandsEnabled)
        }
    }
}

/// Which card's popover is open.
enum CommandCardID: Hashable {
    case preset(FormatPreset)
    case user(UUID)
    case new
}

extension FormatCommand {
    /// The "back to normal" phrase to show in the UI language.
    static func shownEndPhrase(uiLanguageCode: String?) -> String {
        FormatPhrases.endPhrases(language: FormatPhrases.language(of: uiLanguageCode) ?? "en").first ?? "normal"
    }
}

/// A spoken edit command: the same card, smaller and not clickable (nothing to set).
struct EditCommandCard: View {
    let kind: EditCommandKind

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            CommandIllustration(kind: .edit(kind), height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.talkieHeading(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                // What CommandRouter understands — English, so deliberately not localized.
                Text(verbatim: say)
                    .font(.talkieHeading(11.5, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132, alignment: .topLeading)
        .talkieSurface()
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch kind {
        case .rewrite: return "Rewrite it".loc
        case .scratch: return "Take it back".loc
        case .replace: return "Swap a word".loc
        case .spell: return "Spell it out".loc
        case .shortcut: return "Run a Shortcut".loc
        }
    }

    private var say: String {
        switch kind {
        case .rewrite: return "\u{201C}make this a list\u{201D} \u{00B7} \u{201C}fix this\u{201D}"
        case .scratch: return "\u{201C}scratch that\u{201D}"
        case .replace: return "\u{201C}replace Monday with Friday\u{201D}"
        case .spell: return "\u{201C}spell kilo eight sierra\u{201D}"
        case .shortcut: return "\u{201C}run shortcut Ship It\u{201D}"
        }
    }
}

// MARK: - How it works

/// Three steps with the user's real keys and a tiny pill: hold the dictation key and
/// talk → hold the format key and say the format → let go and keep talking.
struct HowItWorksStrip: View {
    let dictationKey: ActivationKey
    let formatKey: ActivationKey

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The one-sentence rule, before the three steps.
            Text("While you hold the format key, what you say is read as a format, in any of your languages. If no format is caught, your words are simply kept as text.".loc)
                .font(.talkieHeading(13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            steps
        }
        .talkieCard(padding: 16)
    }

    private var steps: some View {
        HStack(alignment: .top, spacing: 10) {
            step(String(format: "Hold %@ and talk".loc, dictationKey.displayName)) {
                TalkieKeycap(text: dictationKey.displayName, symbol: dictationKey.symbolName)
            }
            arrow
            step(String(format: "Also hold %@ and say a format".loc, formatKey.displayName)) {
                HStack(spacing: 8) {
                    TalkieKeycap(text: formatKey.displayName, symbol: formatKey.symbolName)
                    PillMock()
                }
            }
            arrow
            step("Let go and keep talking — it comes out formatted".loc) {
                CommandIllustration(kind: .preset(.bulletList), height: 40)
                    .frame(maxWidth: 150)
            }
        }
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.inkTertiary)
            .frame(height: 40)
            .accessibilityHidden(true)
    }

    private func step<V: View>(_ caption: String, @ViewBuilder visual: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            visual().frame(height: 40, alignment: .leading)
            Text(verbatim: caption)
                .font(.talkieHeading(12, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A tiny stand-in for the dictation pill in the "format" state: blue waveform and
/// the format chip (the pill itself is always black).
private struct PillMock: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.featherRed).frame(width: 6, height: 6)
            HStack(spacing: 2) {
                ForEach([6, 11, 8, 13, 7], id: \.self) { h in
                    Capsule().fill(Theme.featherBlue).frame(width: 2.5, height: CGFloat(h))
                }
            }
            Text("Bullet list".loc)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.featherBlue)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.featherBlue.opacity(0.2)))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black))
        .accessibilityHidden(true)
    }
}

// MARK: - Phrase list

/// A list of phrases as removable chips, a field to add one, and the one-line reason
/// when a phrase can't be added.
struct PhraseListEditor: View {
    @Binding var phrases: [String]
    let placeholder: String
    /// The phrase being typed (owned by the caller, so Save can take it too).
    @Binding var draft: String
    /// Why the typed phrase can't be added; shown under the field.
    @Binding var problem: FormatPhraseBook.Refusal?
    /// Why a phrase can't be added (nil = it can). Checked against every other command.
    /// Add is the primary action when this is the popover's only action (the format
    /// details); inside a form with its own Save it stays secondary.
    var addIsPrimary = false
    let refusal: (String) -> FormatPhraseBook.Refusal?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !phrases.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(phrases, id: \.self) { phrase in
                        Button { phrases.removeAll { $0 == phrase } } label: {
                            HStack(spacing: 5) {
                                Text(verbatim: phrase)
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                        }
                        .buttonStyle(.talkieChip)
                        .help(String(format: "Remove \u{201C}%@\u{201D}".loc, phrase))
                        .accessibilityLabel(String(format: "Remove \u{201C}%@\u{201D}".loc, phrase))
                    }
                }
            }
            HStack(spacing: 8) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                    .onChange(of: draft) { problem = nil }
                Button("Add".loc) { add() }
                    .buttonStyle(.talkie(addIsPrimary ? .primary : .secondary, size: .small))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let problem {
                TalkieStatusLine(text: problem.message, tone: .warning)
            }
        }
    }

    /// Add the typed phrase; returns false (and shows why) when it's refused.
    @discardableResult
    func add() -> Bool {
        switch Self.check(draft, in: phrases, refusal: refusal) {
        case .success(let phrase):
            if let phrase { phrases.append(phrase) }
            draft = ""
            return true
        case .failure(let reason):
            problem = reason
            return false
        }
    }

    /// The trimmed phrase to add (nil = nothing typed), or why it can't be added.
    static func check(_ draft: String, in phrases: [String],
                      refusal: (String) -> FormatPhraseBook.Refusal?) -> Result<String?, FormatPhraseBook.Refusal> {
        let phrase = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return .success(nil) }
        let ownKey = FormatPhraseMatcher.normalizedTokens(phrase).joined()
        if phrases.contains(where: { FormatPhraseMatcher.normalizedTokens($0).joined() == ownKey }) {
            return .failure(.alreadyListed)
        }
        if let reason = refusal(phrase) { return .failure(reason) }
        return .success(phrase)
    }
}

// MARK: - User-made command editor

/// The "+" card's popover (and a user-made card's): a name, "When I say…", and one
/// of five plain "Do this" kinds.
struct UserCommandEditor: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var macros: MacroStore
    let existing: UserCommand?
    let onDone: () -> Void

    @State private var name = ""
    @State private var phrases: [String] = []
    @State private var kind: UserCommandAction.Kind = .wrap
    @State private var before = ""
    @State private var after = ""
    @State private var prefix = "> "
    @State private var textCase: UserTextCase = .upper
    @State private var instruction = ""
    @State private var fixedText = ""
    @State private var enabled = true
    @State private var confirmDelete = false
    @State private var draft = ""
    @State private var problem: FormatPhraseBook.Refusal?

    init(settings: AppSettings, macros: MacroStore, existing: UserCommand?, onDone: @escaping () -> Void) {
        self.settings = settings
        self.macros = macros
        self.existing = existing
        self.onDone = onDone
        if let existing {
            _name = State(initialValue: existing.name)
            _phrases = State(initialValue: existing.phrases)
            _enabled = State(initialValue: existing.enabled)
            _kind = State(initialValue: existing.action.kind)
            switch existing.action {
            case .wrap(let b, let a): _before = State(initialValue: b); _after = State(initialValue: a)
            case .linePrefix(let p): _prefix = State(initialValue: p)
            case .textCase(let c): _textCase = State(initialValue: c)
            case .rewrite(let i): _instruction = State(initialValue: i)
            case .insert(let t): _fixedText = State(initialValue: t)
            }
        }
    }

    private var action: UserCommandAction {
        switch kind {
        case .wrap: return .wrap(before: before, after: after)
        case .linePrefix: return .linePrefix(prefix)
        case .textCase: return .textCase(textCase)
        case .rewrite: return .rewrite(instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines))
        case .insert: return .insert(text: fixedText)
        }
    }

    private var actionIsComplete: Bool {
        switch kind {
        case .wrap: return !before.isEmpty || !after.isEmpty
        case .linePrefix: return !prefix.isEmpty
        case .textCase: return true
        case .rewrite: return !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .insert: return !fixedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && actionIsComplete
            && (!phrases.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Every other command's phrases (this one's own list is checked by the editor).
    private func refusal(_ phrase: String) -> FormatPhraseBook.Refusal? {
        let others = UserCommandLibrary.all(settings: settings, macros: macros).filter { $0.id != existing?.id }
        return FormatPhraseBook(disabledPresets: [], synonyms: settings.formatSynonyms, userCommands: others)
            .refusal(for: phrase, owner: .user(existing?.id ?? UUID()))
    }

    var body: some View {
        TalkiePopover(title: existing == nil ? "New command" : "Edit command",
                      subtitle: "Hold the format key while you say it.",
                      width: Theme.Width.popoverWide) {
            TalkieField(label: "Name") {
                TextField("For example, Shout".loc, text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            TalkieField(label: "When I say…") {
                PhraseListEditor(phrases: $phrases, placeholder: "Add a phrase".loc,
                                 draft: $draft, problem: $problem, refusal: refusal)
            }
            TalkiePopoverDivider()
            TalkieField(label: "Do this") {
                TalkieMenuPicker(selection: $kind) {
                    ForEach(UserCommandAction.Kind.allCases) { k in
                        Text(Self.label(k)).tag(k)
                    }
                } label: {
                    Text(Self.label(kind))
                }
            }
            kindFields
            if existing != nil {
                TalkiePopoverDivider()
                TalkieSwitchRow(title: "Use this command".loc,
                                subtitle: "When it's off, saying it does nothing special.".loc,
                                isOn: $enabled)
            }
        } actions: {
            TalkieActionRow {
                if existing != nil {
                    Button("Delete".loc) { confirmDelete = true }
                        .buttonStyle(.talkie(.destructive))
                }
            } trailing: {
                Button("Cancel".loc, action: onDone)
                    .buttonStyle(.talkie(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Create".loc : "Save".loc, action: save)
                    .buttonStyle(.talkie(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .confirmationDialog("Delete this command?".loc, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete".loc, role: .destructive) {
                if let existing { UserCommandLibrary.delete(existing.id, settings: settings, macros: macros) }
                onDone()
            }
            Button("Cancel".loc, role: .cancel) {}
        } message: {
            Text(String(format: "\u{201C}%@\u{201D} stops working, also when said as its own dictation.".loc,
                        existing?.name ?? ""))
        }
    }

    @ViewBuilder
    private var kindFields: some View {
        switch kind {
        case .wrap:
            HStack(spacing: 10) {
                TalkieField(label: "Before") {
                    TextField(String("**"), text: $before).textFieldStyle(.roundedBorder)
                }
                TalkieField(label: "After") {
                    TextField(String("**"), text: $after).textFieldStyle(.roundedBorder)
                }
            }
        case .linePrefix:
            TalkieField(label: "Each line starts with") {
                TextField(String("> "), text: $prefix).textFieldStyle(.roundedBorder)
            }
        case .textCase:
            TalkieField(label: "Make it") {
                TalkieMenuPicker(selection: $textCase) {
                    ForEach(UserTextCase.allCases, id: \.self) { c in Text(Self.caseLabel(c)).tag(c) }
                } label: {
                    Text(Self.caseLabel(textCase))
                }
            }
        case .rewrite:
            TalkieField(label: "Rewrite it like this",
                        help: "Runs on the on-device model, so it's slower. If the model isn't available, your words are pasted as they are.") {
                TextField("For example, friendlier and shorter".loc, text: $instruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }
            TalkieTag(text: "slower — uses the on-device model")
        case .insert:
            TalkieField(label: "Text to insert",
                        help: "Write {date} or {time} to insert the date or time. Also works when you say the phrase as its own dictation.") {
                TextField("For example, your address".loc, text: $fixedText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        // A phrase typed but not yet added counts — unless it's refused (then say why).
        var phrases = self.phrases
        switch PhraseListEditor.check(draft, in: phrases, refusal: refusal) {
        case .success(let phrase):
            if let phrase { phrases.append(phrase) }
        case .failure(let reason):
            problem = reason
            return
        }
        guard !phrases.isEmpty else { return }
        let command = UserCommand(id: existing?.id ?? UUID(),
                                  name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                  phrases: phrases, action: action, enabled: enabled)
        UserCommandLibrary.save(command, settings: settings, macros: macros)
        onDone()
    }

    static func label(_ kind: UserCommandAction.Kind) -> String {
        switch kind {
        case .wrap: return "Put text before and after".loc
        case .linePrefix: return "Start every line with some text".loc
        case .textCase: return "Change to UPPER, lower or Title case".loc
        case .rewrite: return "Rewrite it like this".loc
        case .insert: return "Insert a fixed text".loc
        }
    }

    static func caseLabel(_ c: UserTextCase) -> String {
        switch c {
        case .upper: return "UPPER CASE".loc
        case .lower: return "lower case".loc
        case .title: return "Title Case".loc
        }
    }
}
