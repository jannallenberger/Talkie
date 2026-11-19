import SwiftUI

/// "Punctuation you can say" on the Commands page. Calm by default: the switch, one
/// plain sentence on how it works, and one row of six everyday examples in the UI
/// language. "Show all" opens the full lists (UI language first, then English). Only
/// words that worked with the real recognizer are listed (`SpokenPunctuationTables.reference`).
struct SpokenPunctuationCard: View {
    @ObservedObject var settings: AppSettings
    let uiLanguageCode: String?
    @State private var expanded: Bool

    init(settings: AppSettings, uiLanguageCode: String?, expanded: Bool = false) {
        self.settings = settings
        self.uiLanguageCode = uiLanguageCode
        _expanded = State(initialValue: expanded)
    }

    private var uiBase: String {
        let base = uiLanguageCode.map { String($0.lowercased().prefix(2)) } ?? "en"
        return SpokenPunctuationTables.verifiedLanguages.contains(base) ? base : "en"
    }

    /// UI language first (when its words are verified), then English.
    private var listLanguages: [String] { uiBase == "en" ? ["en"] : [uiBase, "en"] }

    var body: some View {
        let on = settings.spokenPunctuation
        SettingsCard(header: "Punctuation you can say") {
            SettingsToggleRow(
                title: "Say punctuation".loc,
                subtitle: "Say a punctuation word on its own and it becomes the sign. Inside a normal sentence it stays a word. \u{201C}New line\u{201D} and \u{201C}new paragraph\u{201D} need a short pause before and after.".loc,
                isOn: $settings.spokenPunctuation)
            SettingsDivider()
            VStack(alignment: .leading, spacing: 12) {
                marks(SpokenPunctuationTables.examples(language: uiBase))
                if on, expanded {
                    ForEach(listLanguages, id: \.self) { code in
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow(text: languageName(code))
                            marks(SpokenPunctuationTables.reference(language: code))
                        }
                    }
                }
                if on {
                    TalkieDisclosureButton(isExpanded: $expanded)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .opacity(on ? 1 : 0.45)
            .accessibilityHidden(!on)
        }
    }

    private func marks(_ items: [(word: String, mark: String)]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                TalkieWordMark(word: item.word, mark: item.mark)
            }
        }
    }

    private func languageName(_ code: String) -> String {
        Locale(identifier: uiLanguageCode ?? "en").localizedString(forLanguageCode: code)?.capitalized ?? code
    }
}
