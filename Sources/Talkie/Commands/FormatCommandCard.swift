import SwiftUI

/// One command card on the Commands page. The whole card opens its details (a button
/// with the shared card style — hover wash, pressed scale); a small switch on the card
/// turns the command on or off and is NOT the same thing as opening it, so the card no
/// longer shows a "selected" ring while its popover is open. Off cards are dimmed and
/// carry an "Off" tag.
struct FormatCommandCard: View {
    let illustration: CommandIllustration.Kind
    let name: String
    /// What to say: the main wording first, then the others.
    let phrases: [String]
    let slower: Bool
    /// nil = no switch (the "New command" card).
    var isOn: Binding<Bool>?
    /// Shown instead of phrases (the "New command" card).
    var caption: String? = nil
    let helpOpen: String
    let onOpen: () -> Void

    static let height: CGFloat = 188
    static let illustrationHeight: CGFloat = 48

    private var on: Bool { isOn?.wrappedValue ?? true }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: onOpen) {
                FormatCommandCardLabel(illustration: illustration, name: name, phrases: phrases,
                                       slower: slower, isOff: !on, caption: caption)
            }
            .buttonStyle(.talkieCard(selected: false))
            .help(helpOpen)
            if let isOn {
                // The switch sits in the card's footer, away from the artwork; it is
                // separate from the card button, so opening a card never toggles it.
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.brand)
                    .padding(.trailing, 16)
                    .padding(.bottom, 13)
                    .help(String(format: "Turn %@ on or off".loc, name))
                    .accessibilityLabel(String(format: "Use %@".loc, name))
            }
        }
        .frame(height: Self.height)
    }
}

/// The card's content: illustration, name, the main wording and the other ways to say
/// it as quieter text, and a footer with "Off" / "slower" tags and "+N" (the switch
/// sits at the footer's trailing edge).
struct FormatCommandCardLabel: View {
    let illustration: CommandIllustration.Kind
    let name: String
    let phrases: [String]
    let slower: Bool
    let isOff: Bool
    var caption: String? = nil

    private var summary: FormatPhraseCatalog.Summary? { FormatPhraseCatalog.summary(phrases) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            CommandIllustration(kind: illustration, height: FormatCommandCard.illustrationHeight)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(.talkieHeading(14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let caption {
                    Text(verbatim: caption)
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                } else if let summary {
                    Text(verbatim: "\u{201C}\(summary.main)\u{201D}")
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                    if !summary.more.isEmpty {
                        Text(verbatim: summary.more.map { "\u{201C}\($0)\u{201D}" }.joined(separator: " \u{00B7} "))
                            .font(.talkieHeading(11.5, weight: .regular))
                            .foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if isOff { TalkieTag(text: "Off".loc) }
                if slower { TalkieTag(text: "slower".loc) }
                if let summary, summary.hidden > 0 {
                    Text(verbatim: "+\(summary.hidden)")
                        .font(.talkieHeading(11.5, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 22)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: FormatCommandCard.height, maxHeight: FormatCommandCard.height,
               alignment: .topLeading)
        .opacity(isOff ? 0.55 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOff ? String(format: "%@, off".loc, name) : name)
        .accessibilityValue(spokenSummary)
    }

    private var spokenSummary: String {
        if let caption { return caption }
        return phrases.prefix(3).joined(separator: ", ")
    }
}
