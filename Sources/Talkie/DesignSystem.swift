import SwiftUI
import AppKit

// MARK: - Talkie Design System
//
// Brand DNA: the layered-clay scarlet macaw in `icon_assets/talkie_parrot_transparent.png`
// meets Anthropic's warm, editorial "Claude" canvas.
//
//   • Canvas  — warm ivory paper (Claude's signature cream), not clinical white.
//   • Accent  — clay-coral: the macaw's body AND Anthropic's terracotta, one and
//               the same hue. This is the single brand color.
//   • Data    — the parrot's four feathers (coral / gold / blue / green) form the
//               categorical palette used by the dashboard charts + heatmap.
//   • Type    — a serif display voice (New York) for headlines and hero numbers,
//               SF Pro for everything functional. Editorial, human, calm.
//
// Every token adapts to light & dark; the cream identity is preserved in both.
// See `docs/BRAND.md` for the full guideline.

enum Theme {

    // MARK: Surfaces

    /// App background — warm ivory paper.
    static let canvas        = dyn(light: 0xF4F2EA, dark: 0x191815)
    /// Sidebar / chrome — a half-step from the canvas.
    static let canvasRaised  = dyn(light: 0xEDEADF, dark: 0x211F1B)
    /// Card / panel fill.
    static let surface       = dyn(light: 0xFBFAF5, dark: 0x24221D)
    /// Inset wells, chart tracks, empty heatmap cells.
    static let surfaceSunken = dyn(light: 0xEAE7DC, dark: 0x2C2A23)

    // MARK: Ink

    static let ink           = dyn(light: 0x21201B, dark: 0xF3F0E8)
    static let inkSecondary  = dyn(light: 0x6C685E, dark: 0xAEA99D)
    static let inkTertiary   = dyn(light: 0x9B9588, dark: 0x7B766B)
    static let hairline      = dyn(light: 0xE3DFD3, dark: 0x37342D)

    // MARK: Brand accent (clay-coral)

    /// The single brand color — buttons, gauges, active states, the parrot's body.
    static let coral         = dyn(light: 0xD65A3F, dark: 0xE67D60)
    /// A deeper press/hover state.
    static let coralDeep     = dyn(light: 0xBE4B33, dark: 0xCF6A4E)
    /// A soft coral wash for selected rows / tinted fills.
    static let coralWash     = dyn(light: 0xF6E2D8, dark: 0x3A2A22)

    // MARK: Feather palette (categorical data)

    static let featherCoral  = dyn(light: 0xDB5A40, dark: 0xE8775C)
    static let featherGold   = dyn(light: 0xE6A02B, dark: 0xF2B748)
    static let featherBlue   = dyn(light: 0x3B82C4, dark: 0x5B9BD8)
    static let featherGreen  = dyn(light: 0x2FA368, dark: 0x49BC82)
    static let featherPlum   = dyn(light: 0x8A6FB0, dark: 0xA58BC9)

    /// Ordered categorical ramp for charts (app-usage bars, etc).
    static let categorical: [Color] = [featherCoral, featherGold, featherBlue, featherGreen, featherPlum]

    // MARK: Heatmap ramp (coral, low → high)

    /// 0 = empty, then four warming steps. Used by the streak calendar.
    static func heat(_ level: Int) -> Color {
        switch max(0, min(4, level)) {
        case 0:  return surfaceSunken
        case 1:  return dyn(light: 0xF1CDB9, dark: 0x4A3328)
        case 2:  return dyn(light: 0xE3A07C, dark: 0x7E4A33)
        case 3:  return dyn(light: 0xD67049, dark: 0xB5613E)
        default: return dyn(light: 0xBE4B2C, dark: 0xDC7551)
        }
    }

    // MARK: Semantic

    static let positive      = featherGreen
    static let warning       = featherGold
    static let danger        = dyn(light: 0xC8462F, dark: 0xE07254)

    // MARK: Metrics

    enum Radius {
        static let card: CGFloat = 18
        static let control: CGFloat = 10
        static let chip: CGFloat = 8
    }

    enum Space {
        static let card: CGFloat = 20
        static let gridGap: CGFloat = 14
        static let section: CGFloat = 22
    }

    // MARK: Dynamic color helper

    /// A light/dark-adaptive color from two hex values.
    static func dyn(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

// MARK: - Typography

extension Font {
    /// Editorial serif (New York) — page titles & hero headlines.
    static func talkieDisplay(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// Serif for big metric numbers (e.g. "2,119").
    static func talkieMetric(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// Functional UI heading (SF Pro).
    static func talkieHeading(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }
    /// All-caps eyebrow label used above cards & sections.
    static var talkieEyebrow: Font { .system(size: 11, weight: .semibold) }
}

// MARK: - Card surface

extension View {
    /// Standard Talkie card: ivory surface, generous radius, hairline border,
    /// a whisper of warm elevation.
    func talkieCard(padding: CGFloat = Theme.Space.card) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.045), radius: 14, x: 0, y: 6)
    }
}

/// A small all-caps eyebrow label (e.g. "WORDS PER MINUTE").
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.talkieEyebrow)
            .tracking(0.8)
            .foregroundStyle(Theme.inkSecondary)
    }
}

// MARK: - Hex → NSColor

extension NSColor {
    /// Build an sRGB color from a 0xRRGGBB literal.
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
