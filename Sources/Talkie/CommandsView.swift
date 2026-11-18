import SwiftUI

/// "Commands" — three plain sections: format while you dictate (hold a second key,
/// say a format), the spoken commands that edit selected text, and snippets.
struct CommandsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var macros: MacroStore
    // Kept for the call site's shape; the page no longer runs commands itself.
    let commandRouter: CommandRouter
    let hud: HUDController
    let meetingStore: MeetingStore

    @State private var newTrigger = ""
    @State private var newExpansion = ""

    /// German UI → the German phrases; otherwise the English ones (the two languages
    /// the format matcher understands — both always work, whatever the UI language).
    private var uiLanguageCode: String? { Bundle.main.preferredLocalizations.first }

    var body: some View {
        SubPage(title: "Commands",
                subtitle: "Format text while you dictate, edit text by voice, and keep snippets you use often.") {
            formatSection
            editSection
            snippetsSection
        }
    }

    // MARK: 1 · Format while you dictate

    private var commandKeyBinding: Binding<ActivationKey> {
        Binding(get: { settings.effectiveFormatCommandKey },
                set: { settings.formatCommandKey = $0 })
    }

    @ViewBuilder
    private var formatSection: some View {
        let dictationKey = settings.activationKey
        let commandKey = settings.effectiveFormatCommandKey
        SettingsCard(
            header: "Format while you dictate",
            footer: "Formats marked \u{201C}slower\u{201D} use the on-device model. If it isn't available, your words are pasted as plain text and the pill says so.".loc
        ) {
            SettingsToggleRow(
                title: "Format while you dictate".loc,
                subtitle: "Turn the next part of a dictation into a list, an e-mail, capitals and more.".loc,
                isOn: $settings.formatCommandsEnabled
            )
            if settings.formatCommandsEnabled {
                SettingsDivider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        CommandKeycap(key: dictationKey)
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                        CommandKeycap(key: commandKey)
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                        Text(String(format: "say \u{201C}%@\u{201D}".loc,
                                    FormatPreset.bulletList.shownPhrase(uiLanguageCode: uiLanguageCode)))
                            .font(.talkieHeading(13, weight: .medium))
                            .foregroundStyle(Theme.ink)
                    }
                    Text(String(format: "While you dictate, hold %@, say a format and let go — what you say next is pasted in that format. Tap %@ again, or say \u{201C}%@\u{201D}, to go back to normal text.".loc,
                                commandKey.displayName, commandKey.displayName,
                                FormatCommand.shownEndPhrase(uiLanguageCode: uiLanguageCode)))
                        .font(.talkieHeading(12.5, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                SettingsDivider()
                SettingsRow(
                    title: "Format key".loc,
                    subtitle: "Only listened to while you dictate. Pressed together with any other key or a click, it does nothing.".loc
                ) {
                    ActivationKeyRecorder(key: commandKeyBinding) { candidate in
                        FormatCommandKey.refusal(for: candidate, dictationKey: settings.activationKey)
                    }
                }
            }
        }

        if settings.formatCommandsEnabled {
            SettingsCard(header: "Formats") {
                ForEach(Array(FormatPreset.allCases.enumerated()), id: \.element.id) { index, preset in
                    if index > 0 { SettingsDivider() }
                    FormatPresetRow(preset: preset, uiLanguageCode: uiLanguageCode)
                }
            }
        }
    }

    // MARK: 2 · Edit selected text

    @ViewBuilder
    private var editSection: some View {
        SettingsCard(
            header: "Edit selected text",
            footer: "Say the command as its own dictation. With nothing selected, it works on what you just dictated in the same app (within the last 45 seconds). Rewrites always show a preview first.".loc
        ) {
            VoiceCommandRow(say: "\u{201C}make this a list\u{201D} · \u{201C}fix this\u{201D} · \u{201C}translate to German\u{201D}",
                            does: "Start with an English editing word (make, fix, rewrite, translate, summarize, shorten, rephrase …) and the selected text is rewritten on this Mac.".loc)
            SettingsDivider()
            VoiceCommandRow(say: "\u{201C}scratch that\u{201D} · \u{201C}delete that\u{201D}",
                            does: "Removes what you just dictated.".loc)
            SettingsDivider()
            VoiceCommandRow(say: "\u{201C}replace Monday with Friday\u{201D} · \u{201C}change Monday to Friday\u{201D}",
                            does: "Swaps a word in what you just dictated — only if that word is in it.".loc)
            SettingsDivider()
            VoiceCommandRow(say: "\u{201C}spell kilo eight sierra\u{201D}",
                            does: "Types k8s — for codes and names that are hard to dictate.".loc)
            SettingsDivider()
            VoiceCommandRow(say: "\u{201C}run shortcut Ship It\u{201D}",
                            does: "Runs the Shortcut with exactly that name.".loc)
        }

        SettingsCard(
            header: "Ask about your meetings",
            footer: "Uses only meetings and notes already on this Mac and never sends anything. Off by default.".loc
        ) {
            SettingsToggleRow(
                title: "Let requests about my meetings run as commands".loc,
                subtitle: "A spoken request like \u{201C}email Sarah the action items from my last meeting\u{201D} runs as a command instead of being typed, and shows a preview before anything is inserted.".loc,
                isOn: $settings.crossSurfaceCommandsEnabled
            )
        }
    }

    // MARK: 3 · Snippets

    @ViewBuilder
    private var snippetsSection: some View {
        SettingsCard(
            header: "Snippets",
            footer: "Say the trigger as its own dictation and the text is inserted instead. Write {date}, {today} or {time} to insert the date or time at the moment you say it.".loc
        ) {
            SettingsRow(title: "When I say".loc) {
                TextField("a trigger phrase".loc, text: $newTrigger)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            SettingsDivider()
            SettingsRow(title: "Insert".loc) {
                TextField("the text to insert".loc, text: $newExpansion, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .frame(width: 240)
            }
            SettingsDivider(leadingInset: 0)
            HStack {
                Spacer()
                Button("Add snippet".loc, action: addMacro)
                    .buttonStyle(.talkie(.primary))
                    .disabled(!canAdd)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }

        SettingsCard(header: macros.macros.isEmpty ? nil : "Your snippets") {
            if macros.macros.isEmpty {
                SettingsNote(
                    text: "No snippets yet. Add one above — for example, \u{201C}my address\u{201D} \u{2192} your full mailing address.".loc,
                    tone: Theme.inkTertiary
                )
            } else {
                ForEach(Array(macros.macros.enumerated()), id: \.element.id) { index, macro in
                    if index > 0 { SettingsDivider() }
                    CommandMacroRow(macro: macro) { macros.delete(macro) }
                }
            }
        }
    }

    // MARK: Snippet CRUD

    private var canAdd: Bool {
        !newTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newExpansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addMacro() {
        macros.add(trigger: newTrigger, expansion: newExpansion)
        newTrigger = ""
        newExpansion = ""
    }
}

extension FormatCommand {
    /// The "back to normal" phrase to show in the UI language.
    static func shownEndPhrase(uiLanguageCode: String?) -> String {
        uiLanguageCode?.lowercased().hasPrefix("de") == true ? germanEndPhrases[0] : englishEndPhrases[0]
    }
}

/// One preset: its name (+ "slower" for model formats), what to say, and a tiny
/// before → after example.
private struct FormatPresetRow: View {
    let preset: FormatPreset
    let uiLanguageCode: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(preset.displayName)
                        .font(.talkieHeading(14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    if preset.usesModel {
                        TalkieTag(text: "slower".loc)
                    }
                }
                Text(String(format: "Say \u{201C}%@\u{201D}".loc, preset.shownPhrase(uiLanguageCode: uiLanguageCode)))
                    .font(.talkieHeading(12.5, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(preset.example.before)
                    .font(.talkieHeading(12, weight: .regular))
                    .foregroundStyle(Theme.inkTertiary)
                Text(preset.example.after)
                    .font(.talkieHeading(12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// One spoken command: what to say, and what happens.
private struct VoiceCommandRow: View {
    /// The literal spoken command — English, as `CommandRouter` understands it, so it
    /// is deliberately not localized.
    let say: String
    let does: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(say)
                .font(.talkieHeading(14, weight: .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(does)
                .font(.talkieHeading(12.5, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

/// A key cap showing one of the user's real keys (the shared `TalkieKeycap`).
private struct CommandKeycap: View {
    let key: ActivationKey

    var body: some View {
        TalkieKeycap(text: key.displayName, symbol: key.symbolName)
    }
}

/// One snippet row: the trigger, an arrow, the inserted text, and a delete affordance.
private struct CommandMacroRow: View {
    let macro: Macro
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(macro.trigger)
                    .font(.talkieHeading(14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                    Text(macro.expansion)
                        .font(.talkieHeading(12.5, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.danger : Theme.inkTertiary)
            }
            .buttonStyle(.talkie(.quiet, size: .small))
            .help("Delete this snippet".loc)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
