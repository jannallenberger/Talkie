import SwiftUI

/// "Voice commands" — manage the macros that expand when you say their trigger,
/// and explain the parsed-leading-imperative command model. Reuses the shared
/// `SubPage` / `SettingsCard` / `SettingsRow` vocabulary so it matches the other
/// settings panes exactly.
///
/// Macros are CRUD over `MacroStore`: a trigger phrase → an expansion. Saying a
/// trigger by itself (whole-utterance) inserts the expansion; this never fires
/// mid-dictation. The footer explains the imperative side (verbs run a command on
/// your selection) so the two halves of command mode read as one honest story.
struct VoiceCommandsSettings: View {
    @ObservedObject var macros: MacroStore

    @State private var newTrigger = ""
    @State private var newExpansion = ""

    var body: some View {
        SubPage(title: "Voice commands",
                subtitle: "Say a verb to run a command, or a trigger to expand a snippet.") {
            // How it works — the honest two-part model.
            SettingsCard(header: "How it works") {
                SettingsNote(
                    text: "Start a dictation with a verb like “make”, “fix”, or “translate” to run that command on whatever text you have selected — Talkie shows the result before it replaces anything.",
                    tone: Theme.inkSecondary
                )
                SettingsDivider(leadingInset: 0)
                SettingsNote(
                    text: "Say a macro’s trigger by itself to expand it into the text below. A macro only fires when it’s the whole utterance, so it never shows up inside normal dictation.",
                    tone: Theme.inkSecondary
                )
            }

            // Add a macro.
            SettingsCard(
                header: "New macro",
                footer: "Use {date}, {today}, or {time} in the expansion to drop in the moment you say it."
            ) {
                SettingsRow(title: "When I say") {
                    TextField("a trigger phrase", text: $newTrigger)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                SettingsDivider()
                SettingsRow(title: "Insert") {
                    TextField("the expansion", text: $newExpansion, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .frame(width: 240)
                }
                SettingsDivider(leadingInset: 0)
                HStack {
                    Spacer()
                    Button("Add macro", action: addMacro)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.coral)
                        .disabled(!canAdd)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }

            // Existing macros.
            SettingsCard(header: macros.macros.isEmpty ? nil : "Your macros") {
                if macros.macros.isEmpty {
                    SettingsNote(
                        text: "No macros yet. Add one above — for example, “my address” → your full mailing address.",
                        tone: Theme.inkTertiary
                    )
                } else {
                    ForEach(Array(macros.macros.enumerated()), id: \.element.id) { index, macro in
                        if index > 0 { SettingsDivider() }
                        MacroRow(macro: macro) { macros.delete(macro) }
                    }
                }
            }
        }
    }

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

/// One macro row: the trigger, an arrow, the expansion, and a delete affordance —
/// the same shape the Dictionary's replacement rows use, so the two read as kin.
private struct MacroRow: View {
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
            .buttonStyle(.plain)
            .help("Delete this macro")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
