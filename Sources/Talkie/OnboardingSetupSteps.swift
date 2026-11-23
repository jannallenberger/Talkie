import SwiftUI
import AppKit

// MARK: - Onboarding: the setup steps
//
// After the try-it: about you (name, app language, the languages you dictate in), the
// style (colours and how text comes out), and, after the permissions, connecting an
// AI agent. Each step applies what you pick at once, through the same setters as
// Settings, and can be left as it is with Continue. Copy is short and plain: a title,
// at most one line under it, labels on the controls. Controls sit on the sunken fill
// (no glass inside the glass card); fields have their label above (`TalkieField`).

/// The title and the optional one line under it.
struct OnboardingStepHeader: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey? = nil

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.talkieDisplay(28))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.talkieHeading(14, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: About you

/// Your name, the app language and the languages you dictate in.
struct OnboardingAboutStep: View {
    @ObservedObject var settings: AppSettings
    /// Restart into the newly chosen app language, coming back to the next step.
    let onRestartForLanguage: () -> Void

    @State private var appLanguage = AppLanguage.current()

    /// What the app would show after a restart with this choice.
    private var effectiveChoice: String {
        guard appLanguage == AppLanguage.system else { return appLanguage }
        return Locale.preferredLanguages.lazy.compactMap(AppLanguage.normalized).first ?? "en"
    }

    var body: some View {
        VStack(spacing: 18) {
            OnboardingStepHeader(title: "About you")
            VStack(alignment: .leading, spacing: 14) {
                TalkieField(label: "Your name") {
                    TextField("Your name".loc, text: $settings.userName)
                        .textFieldStyle(.roundedBorder)
                }
                TalkieField(label: "App language") {
                    HStack(spacing: 10) {
                        TalkieMenuPicker(selection: $appLanguage) {
                            Text(verbatim: AppLanguage.displayName(AppLanguage.system)).tag(AppLanguage.system)
                            ForEach(AppLanguage.supported, id: \.self) { code in
                                Text(verbatim: AppLanguage.displayName(code)).tag(code)
                            }
                        } label: {
                            Text(verbatim: AppLanguage.displayName(appLanguage))
                        }
                        if effectiveChoice != AppLanguage.showing {
                            Text("Takes effect after a restart.")
                                .font(.talkieHeading(11.5, weight: .regular))
                                .foregroundStyle(Theme.inkTertiary)
                            Spacer(minLength: 6)
                            Button("Restart now".loc, action: onRestartForLanguage)
                                .buttonStyle(.talkie(.secondary, size: .small))
                        } else {
                            Spacer(minLength: 0)
                        }
                    }
                }
                TalkieField(label: "Languages you speak", help: "The first one is your main language.") {
                    FlowLayout(spacing: 6) {
                        ForEach(talkieLanguageCatalog) { language in
                            Toggle(isOn: Binding(
                                get: { settings.spokenLanguages.contains(language.id) },
                                set: { _ in toggleSpokenLanguage(language.id, in: settings) }
                            )) {
                                Text(verbatim: "\(language.flag) \(language.name)")
                                    .font(.talkieHeading(12, weight: .medium))
                                    .padding(.vertical, 2)
                            }
                            .toggleStyle(.talkieChip)
                        }
                    }
                }
            }
            .multilineTextAlignment(.leading)
        }
        .onChange(of: appLanguage) { _, code in AppLanguage.set(code) }
    }
}

// MARK: Style

/// How text comes out, as presets over the per-app cleanup styles.
enum OnboardingWritingChoice: String, CaseIterable, Identifiable {
    case asSpoken, cleanedUp, perApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asSpoken:  return "As spoken".loc
        case .cleanedUp: return "Cleaned up".loc
        case .perApp:    return "Per app".loc
        }
    }

    var detail: String {
        switch self {
        case .asSpoken:  return "No changes.".loc
        case .cleanedUp: return "Fixes slips and punctuation.".loc
        case .perApp:    return "Casual in chats, formal in email, unchanged in code.".loc
        }
    }

    /// The per-app styles this choice sets (every `AppCategory`).
    @MainActor
    var styles: [String: String] {
        var out: [String: String] = [:]
        for category in AppCategory.allCases {
            let style: CleanupStyle
            switch self {
            case .asSpoken:  style = .off
            case .cleanedUp: style = (category == .coding || category == .terminal) ? .faithful : .neutral
            case .perApp:
                style = AppSettings.defaultAppCleanupStyles[category.rawValue].flatMap(CleanupStyle.init) ?? .neutral
            }
            out[category.rawValue] = style.rawValue
        }
        return out
    }

    /// The choice the current styles match, if any (a hand-made mix matches none).
    @MainActor
    static func matching(_ styles: [String: String]) -> OnboardingWritingChoice? {
        allCases.first { choice in
            AppCategory.allCases.allSatisfy { styles[$0.rawValue] == choice.styles[$0.rawValue] }
        }
    }
}

/// Colours (the backdrop, which brings its accent) and how text comes out. The page
/// behind the card is the preview.
struct OnboardingStyleStep: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var appearance = AppearanceStore.shared

    var body: some View {
        let look = appearance.look
        let current = OnboardingWritingChoice.matching(settings.appCleanupStyles)
        VStack(spacing: 18) {
            OnboardingStepHeader(title: "Style")
            VStack(alignment: .leading, spacing: 16) {
                TalkieField(label: "Colors") {
                    HStack(spacing: 8) {
                        ForEach(TalkieBackdropStyle.allCases) { style in
                            BackdropSwatch(style: style, angle: look.angle, selected: look.backdrop == style) {
                                appearance.update { $0.backdrop = style; $0.accent = style.accent }
                            }
                        }
                    }
                }
                TalkieField(label: "Text",
                            help: CleanupEngine.isAvailable ? nil : "Cleaning up needs Apple Intelligence.") {
                    VStack(spacing: 6) {
                        ForEach(OnboardingWritingChoice.allCases) { choice in
                            Button {
                                settings.appCleanupStyles = choice.styles
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(verbatim: choice.title)
                                            .font(.talkieHeading(13.5, weight: .semibold))
                                            .foregroundStyle(Theme.ink)
                                        Text(verbatim: choice.detail)
                                            .font(.talkieHeading(12, weight: .regular))
                                            .foregroundStyle(Theme.inkSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 6)
                                    if current == choice {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(Theme.brand)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.talkieChoice(selected: current == choice))
                            .accessibilityAddTraits(current == choice ? .isSelected : [])
                        }
                    }
                }
            }
            .multilineTextAlignment(.leading)
        }
    }
}

// MARK: Your AI agent (MCP)

/// Optional: connect an AI agent through Talkie's local MCP.
struct OnboardingAgentStep: View {
    @State private var copied = false
    @State private var desktopStatus: String?

    var body: some View {
        VStack(spacing: 18) {
            OnboardingStepHeader(title: "Connect your AI agent",
                                 detail: "Optional. Lets Claude or another AI agent change your settings, write meeting summaries and add words to your dictionary. You can undo every change.")
            if let binaryPath = MCPConnector.binaryPath() {
                HStack(spacing: 10) {
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(MCPSetupPrompt.setupPrompt(binaryPath: binaryPath), forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2.5)); copied = false }
                    } label: {
                        Label(copied ? "Copied".loc : "Copy setup prompt".loc,
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.talkie(.secondary))
                    if MCPConnector.mcpbURL() != nil {
                        Button("Open in Claude Desktop".loc) { desktopStatus = MCPConnector.openInClaudeDesktop() }
                            .buttonStyle(.talkie(.secondary))
                    }
                }
                Text(verbatim: desktopStatus ?? "Paste the prompt into a new chat with your agent.".loc)
                    .font(.talkieHeading(12, weight: .regular))
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                TalkieStatusLine(text: "The connector isn't part of this build.".loc, tone: .warning)
            }
        }
    }
}

// MARK: - Choice row style

/// A full-width choice row inside a glass card: the sunken fill (no glass inside
/// glass), hover one step darker, the brand wash and a brand rim when selected.
struct TalkieChoiceButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        TalkieChoiceBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct TalkieChoiceBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Theme.brand, lineWidth: isSelected ? 1.5 : 0))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }

    private var fill: Color {
        if isSelected { return Theme.brandWash }
        return hovering ? Theme.surfaceSunken.mix(with: Theme.ink, by: 0.05) : Theme.surfaceSunken
    }
}

extension ButtonStyle where Self == TalkieChoiceButtonStyle {
    static func talkieChoice(selected: Bool) -> TalkieChoiceButtonStyle { TalkieChoiceButtonStyle(isSelected: selected) }
}
