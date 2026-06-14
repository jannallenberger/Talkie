import SwiftUI

/// Renders the simple markdown the on-device model produces (bold + bullet
/// lists with 2-space nesting) as proper formatted text — line by line, so the
/// `**bold**` and `*` markers don't show up literally. Inherits the ambient font
/// and foreground color; the parent sets `.font(...)` / `.foregroundStyle(...)`.
struct MarkdownText: View {
    let markdown: String
    var bulletColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(parsedLines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .blank:
                    Color.clear.frame(height: 4)
                case let .text(indent, isBullet, attributed):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if isBullet {
                            Text("•").foregroundStyle(bulletColor)
                        }
                        Text(attributed)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                }
            }
        }
    }

    private enum Line {
        case blank
        case text(indent: Int, isBullet: Bool, AttributedString)
    }

    private var parsedLines: [Line] {
        markdown.components(separatedBy: "\n").map { raw in
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }

            var s = Substring(raw)
            var leadingSpaces = 0
            while let first = s.first, first == " " {
                s = s.dropFirst()
                leadingSpaces += 1
            }
            var isBullet = false
            if s.hasPrefix("* ") || s.hasPrefix("- ") || s.hasPrefix("• ") {
                isBullet = true
                s = s.dropFirst(2)
            }
            let content = String(s).trimmingCharacters(in: .whitespaces)
            let attributed = (try? AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(content)
            return .text(indent: leadingSpaces / 2, isBullet: isBullet, attributed)
        }
    }
}
