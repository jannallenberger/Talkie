import SwiftUI

/// "Commands" — a front door for Talkie's voice-copilot layer: the macros you've
/// taught it, a live reference for the imperative-verb grammar, and a sandbox to
/// try any command (including the experimental cross-surface ones) against the
/// real `CommandRouter` before it ever runs live during dictation.
struct CommandsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var macros: MacroStore
    let commandRouter: CommandRouter
    let hud: HUDController
    let meetingStore: MeetingStore

    @State private var newTrigger = ""
    @State private var newExpansion = ""

    var body: some View {
        SubPage(title: "Commands",
                subtitle: "Say a verb to run a command, a trigger to expand a snippet, or ask about your meetings.") {
            trySandbox

            SettingsCard(header: "Examples") {
                exampleChips
            }

            if Dev.isEnabled {
                SettingsCard(
                    header: "Experimental",
                    footer: "Lets a spoken request like \u{201c}email Sarah the action items from my last meeting\u{201d} run as a command instead of being dictated literally. Off by default — flip it on once you've tried a few examples above."
                ) {
                    SettingsToggleRow(
                        title: "Cross-surface commands",
                        subtitle: "Runs on every dictation once enabled.",
                        isOn: $settings.crossSurfaceCommandsEnabled
                    )
                }
            }

            // New macro.
            SettingsCard(
                header: "New macro",
                footer: "Optional: write {date}, {today}, or {time} in the expansion and Talkie replaces it with the real date or time at the moment you SPEAK the trigger — not when you create the macro here."
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
                        text: "No macros yet. Add one above — for example, \u{201c}my address\u{201d} \u{2192} your full mailing address.",
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
    }

    // MARK: Try a command

    @State private var tryText = ""
    @State private var trySelection = ""
    @State private var tryFeedback: String?

    /// "make this a list" / "fix this" / "translate to German" / "summarize this"
    /// all route through `RewriteIntent`, which needs a non-empty selection to do
    /// anything — there's no real text selected anywhere while you're sitting in
    /// Settings, so this field lets you stand in for "the text you'd have
    /// highlighted" when trying one of those.
    private var trySandbox: some View {
        SettingsCard(
            header: "Try a command",
            footer: tryFeedback
        ) {
            SettingsRow(title: "Say something") {
                TextField("e.g. \u{201c}make this a list\u{201d}", text: $tryText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit { run(tryText) }
            }
            SettingsDivider()
            SettingsRow(
                title: "As if you had this selected",
                subtitle: "Only needed for commands like \u{201c}make this a list\u{201d} that act on selected text."
            ) {
                TextField("buy milk, eggs, bread", text: $trySelection)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
            }
            SettingsDivider(leadingInset: 0)
            HStack {
                Spacer()
                Button("Run") { run(tryText) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
                    .disabled(tryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
    }

    private var exampleChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(exampleCommands, id: \.self) { example in
                Button {
                    tryText = example
                    if trySelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        trySelection = "buy milk, eggs, bread"
                    }
                    run(example)
                } label: {
                    Text(example)
                        .font(.talkieHeading(12.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.surfaceSunken))
            }
        }
    }

    private var exampleCommands: [String] {
        var examples = ["make this a list", "fix this", "translate to German", "summarize this"]
        if Dev.isEnabled, settings.crossSurfaceCommandsEnabled {
            examples.append("what did I commit to this week")
        }
        return examples
    }

    /// Runs `text` through the real `CommandRouter` — the same instance live
    /// dictation uses — and previews the result through the same HUD pill.
    /// Cross-surface parsing is always exercised here (`crossSurfaceEnabled:
    /// true`) regardless of the live flag's state, so the sandbox always
    /// demonstrates the full feature even while it's dark in production.
    private func run(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tryFeedback = nil
        guard let intent = commandRouter.intent(
            for: trimmed,
            meetings: MeetingSnapshot(meetings: meetingStore.meetings),
            crossSurfaceEnabled: true
        ) else {
            tryFeedback = "No command matched — that phrase would be dictated as plain text."
            return
        }
        let selection = trySelection.trimmingCharacters(in: .whitespacesAndNewlines)
        if intent.needsSelection, selection.isEmpty {
            tryFeedback = "This command needs selected text to act on — fill in \u{201c}As if you had this selected\u{201d} above and run it again."
            return
        }
        Task {
            let ctx = CommandContext(
                spokenCommand: trimmed,
                selection: selection.isEmpty ? nil : selection,
                target: .unknown,
                graph: .empty,
                summarizer: OnDeviceLLM()
            )
            guard let result = await intent.run(ctx) else {
                tryFeedback = "The command matched, but the on-device model didn't return anything — it may be unavailable right now."
                return
            }
            hud.showCommandPreview(
                result.replacement,
                onConfirm: { copyToClipboard(result.replacement) },
                onUndo: { }
            )
        }
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: Macro CRUD

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

/// One macro row: the trigger, an arrow, the expansion, and a delete affordance.
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
