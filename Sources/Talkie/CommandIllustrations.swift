import SwiftUI

/// The small "before → after" drawings on the Commands page's cards.
///
/// Rule applied (docs/BRAND_VISUAL_LANGUAGE.md §3): these are FUNCTIONAL
/// illustrations — they explain what a command does, sit inside a control well under
/// 28 pt per element and must follow light/dark — so they are vector shapes drawn in
/// SwiftUI from Theme tokens (ink for text lines, brand blue for what the command
/// adds), never raster clay art, which is reserved for identity/category icons and
/// cannot theme. Decorative and `accessibilityHidden`: the card's name and phrase
/// carry the meaning.
struct CommandIllustration: View {
    enum Kind: Equatable {
        case preset(FormatPreset)
        case user(UserCommandAction)
        case edit(EditCommandKind)
        case newCommand
    }

    let kind: Kind
    var height: CGFloat = 64

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Theme.surfaceSunken,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .newCommand:
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.brand)
        default:
            HStack(spacing: 10) {
                before
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary)
                after
            }
        }
    }

    // MARK: Before

    @ViewBuilder
    private var before: some View {
        switch kind {
        case .preset(.allCaps): Glyphs(text: "abc", color: Theme.inkSecondary)
        case .preset(.lowercase): Glyphs(text: "ABC", color: Theme.inkSecondary)
        case .preset(.formal): WavyLines()
        case .preset(.shorter): Lines(widths: [44, 40, 44, 30])
        case .preset(.translateToEnglish): LanguageBubble(code: "DE", accent: false)
        case .preset(.translateToGerman): LanguageBubble(code: "EN", accent: false)
        case .preset(.bulletList), .preset(.numberedList), .preset(.todoList):
            Lines(widths: [16, 14, 18], axis: .horizontal)
        case .user(.textCase): Glyphs(text: "ab", color: Theme.inkSecondary)
        case .user(.insert): Lines(widths: [24, 18], axis: .horizontal)
        case .edit(.replace): Glyphs(text: "Mon", color: Theme.inkSecondary, size: 13)
        case .edit(.spell): Glyphs(text: "k·8·s", color: Theme.inkSecondary, size: 12)
        case .edit(.rewrite): Lines(widths: [40, 34, 40], highlight: true)
        case .edit(.scratch): Lines(widths: [40, 30])
        case .edit(.shortcut): Lines(widths: [30], axis: .horizontal)
        default: Lines(widths: [40, 32, 38])
        }
    }

    // MARK: After

    @ViewBuilder
    private var after: some View {
        switch kind {
        case .preset(let p): presetAfter(p)
        case .user(let action): userAfter(action)
        case .edit(let e): editAfter(e)
        case .newCommand: EmptyView()
        }
    }

    @ViewBuilder
    private func presetAfter(_ p: FormatPreset) -> some View {
        switch p {
        case .bulletList: MarkedLines(marker: .dot)
        case .numberedList: MarkedLines(marker: .number)
        case .todoList: MarkedLines(marker: .box)
        case .allCaps: Glyphs(text: "ABC", color: Theme.brand)
        case .lowercase: Glyphs(text: "abc", color: Theme.brand)
        case .quotes: Wrapped(open: "\u{201C}", close: "\u{201D}")
        case .parentheses: Wrapped(open: "(", close: ")")
        case .heading:
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Theme.brand).frame(width: 40, height: 7)
                Bar(width: 34)
                Bar(width: 28)
            }
        case .verbatim:
            HStack(spacing: 3) {
                Glyphs(text: "</>", color: Theme.brand, size: 11)
                Bar(width: 22)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Theme.brand.opacity(0.6), lineWidth: 1))
        case .email: EnvelopeLayout()
        case .formal: Lines(widths: [40, 40, 40], color: Theme.brand)
        case .shorter: Lines(widths: [36, 22], color: Theme.brand)
        case .translateToEnglish: LanguageBubble(code: "EN", accent: true)
        case .translateToGerman: LanguageBubble(code: "DE", accent: true)
        }
    }

    @ViewBuilder
    private func userAfter(_ action: UserCommandAction) -> some View {
        switch action {
        case .wrap(let before, let after):
            Wrapped(open: Self.short(before, fallback: "["), close: Self.short(after, fallback: "]"))
        case .linePrefix(let prefix):
            MarkedLines(marker: .text(Self.short(prefix, fallback: ">")))
        case .textCase(let c):
            Glyphs(text: c == .upper ? "AB" : (c == .lower ? "ab" : "Ab"), color: Theme.brand)
        case .rewrite:
            ZStack(alignment: .topTrailing) {
                Lines(widths: [38, 30, 36], color: Theme.brand)
                Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.brand)
                    .offset(x: 8, y: -8)
            }
        case .insert:
            HStack(spacing: 3) {
                Bar(width: 12)
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Theme.brand).frame(width: 18, height: 9)
                Bar(width: 10)
            }
        }
    }

    @ViewBuilder
    private func editAfter(_ e: EditCommandKind) -> some View {
        switch e {
        case .rewrite: Lines(widths: [40, 36], color: Theme.brand)
        case .scratch:
            Capsule().fill(Theme.brand).frame(width: 2, height: 14)
        case .replace: Glyphs(text: "Fri", color: Theme.brand, size: 13)
        case .spell: Glyphs(text: "k8s", color: Theme.brand, size: 13)
        case .shortcut:
            Image(systemName: "square.2.layers.3d")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.brand)
        }
    }

    /// The first characters of a user's wrap/prefix text for the drawing.
    static func short(_ text: String, fallback: String) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? fallback : String(t.prefix(2))
    }
}

/// The spoken commands that edit selected text (their cards on the Commands page).
enum EditCommandKind: CaseIterable, Equatable {
    case rewrite, scratch, replace, spell, shortcut
}

// MARK: - Primitives

private struct Bar: View {
    var width: CGFloat
    var color: Color = Theme.inkTertiary.opacity(0.55)
    var body: some View { Capsule().fill(color).frame(width: width, height: 4) }
}

private struct Lines: View {
    var widths: [CGFloat]
    var axis: Axis = .vertical
    var color: Color = Theme.inkTertiary.opacity(0.55)
    var highlight = false

    var body: some View {
        Group {
            if axis == .vertical {
                VStack(alignment: .leading, spacing: 5) { bars }
            } else {
                HStack(spacing: 4) { bars }
            }
        }
        .padding(highlight ? 4 : 0)
        .background(highlight ? Theme.brandWash : .clear,
                    in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    @ViewBuilder private var bars: some View {
        ForEach(Array(widths.enumerated()), id: \.offset) { _, w in Bar(width: w, color: color) }
    }
}

private struct MarkedLines: View {
    enum Marker: Equatable { case dot, number, box, text(String) }
    let marker: Marker

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 4) {
                    mark(i).frame(width: 9, alignment: .center)
                    Bar(width: [30, 24, 28][i])
                }
            }
        }
    }

    @ViewBuilder private func mark(_ i: Int) -> some View {
        switch marker {
        case .dot: Circle().fill(Theme.brand).frame(width: 4, height: 4)
        case .number: Text(verbatim: "\(i + 1)").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.brand)
        case .box:
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .strokeBorder(Theme.brand, lineWidth: 1.2)
                .background(i == 0 ? RoundedRectangle(cornerRadius: 1.5).fill(Theme.brand) : nil)
                .frame(width: 7, height: 7)
        case .text(let t):
            Text(verbatim: t).font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.brand)
                .lineLimit(1).fixedSize()
        }
    }
}

private struct Glyphs: View {
    let text: String
    let color: Color
    var size: CGFloat = 15
    var body: some View {
        Text(verbatim: text)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

private struct Wrapped: View {
    let open: String
    let close: String
    var body: some View {
        HStack(spacing: 3) {
            Glyphs(text: open, color: Theme.brand, size: 15)
            Bar(width: 26)
            Glyphs(text: close, color: Theme.brand, size: 15)
        }
    }
}

private struct WavyLines: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Wave().stroke(Theme.inkTertiary.opacity(0.55), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: [40, 30, 36][i], height: 5)
            }
        }
    }

    private struct Wave: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.midY))
            let steps = 4
            let w = r.width / CGFloat(steps)
            for s in 0..<steps {
                let x = r.minX + CGFloat(s) * w
                p.addQuadCurve(to: CGPoint(x: x + w, y: r.midY),
                               control: CGPoint(x: x + w / 2, y: s.isMultiple(of: 2) ? r.minY : r.maxY))
            }
            return p
        }
    }
}

private struct EnvelopeLayout: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Theme.brand.opacity(0.7), lineWidth: 1.2)
            Flap()
                .stroke(Theme.brand.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                .frame(height: 9)
            VStack(alignment: .leading, spacing: 3) {
                Bar(width: 12, color: Theme.brand)
                Bar(width: 28)
                Bar(width: 22)
                Bar(width: 14, color: Theme.brand)
            }
            .padding(.top, 12)
            .padding(.leading, 6)
        }
        .frame(width: 44, height: 44)
    }

    private struct Flap: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX + 1, y: r.minY + 1))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX - 1, y: r.minY + 1))
            return p
        }
    }
}

private struct LanguageBubble: View {
    let code: String
    let accent: Bool
    var body: some View {
        Text(verbatim: code)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(accent ? Color.white : Theme.inkSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(accent ? Theme.brand : Theme.inkTertiary.opacity(0.25),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
