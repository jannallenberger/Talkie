import SwiftUI
import AppKit

// MARK: - Talkie Design System (v2 — native macOS 26)
//
// Brand DNA: the layered scarlet-macaw logo on a clean, system-native canvas.
//
//   • Canvas  — pure white in light, true black in dark. Surfaces lift by
//               contrast + one whisper shadow, never an outline (borderless).
//   • Accent  — macaw BLUE leads the chrome (primary action, selection, focus,
//               the HUD, the mic FAB). Kept here under the historical name
//               `coral` so every existing call site stays valid — the *value*
//               is now blue. New code can read it as the brand accent.
//   • Data    — the macaw's feathers (red / gold / blue / green / plum) are the
//               categorical palette: charts, the streak heatmap, per-item nav
//               tints. `featherCoral` is the macaw RED.
//   • Type    — Young Serif (bundled) for titles & hero numbers; SF Pro for the
//               functional UI. Squircle (superellipse) corners.
//
// Mirrors the finished design tokens in Talkie.zip / talkie.css. Every token
// adapts to light & dark. See `docs/BRAND.md` + the migration pipeline in the vault.

enum Theme {

    // MARK: Surfaces

    /// App background — pure white / true black.
    static let canvas        = dyn(light: 0xFFFFFF, dark: 0x000000)
    /// Sidebar / chrome fallback (the real sidebar is Liquid Glass).
    static let canvasRaised  = dyn(light: 0xEFF1F3, dark: 0x121214)
    /// Card / panel fill — the higher surface.
    static let surface       = dyn(light: 0xF5F6F8, dark: 0x1B1B1E)
    /// Inset wells, chart tracks, empty heatmap cells.
    static let surfaceSunken = dyn(light: 0xE9EBEE, dark: 0x29292D)

    // MARK: Ink

    static let ink           = dyn(light: 0x1C1D20, dark: 0xF4F5F6)
    static let inkSecondary  = dyn(light: 0x5E626A, dark: 0xA6AAB0)
    static let inkTertiary   = dyn(light: 0x969AA1, dark: 0x70747B)
    /// Row dividers only — never an element outline.
    static let hairline      = dyn(light: 0xE6E8EB, dark: 0x2B2B2F)

    // MARK: Brand accent — macaw blue (leads the chrome)

    /// The brand accent. Buttons, selection, focus, the HUD, the mic FAB.
    /// (Named `coral` for call-site compatibility; the value is macaw blue.)
    static let coral         = dyn(light: 0x1F66B3, dark: 0x4AA0E6)
    /// Deeper press/emphasis state.
    static let coralDeep     = dyn(light: 0x18548F, dark: 0x79B8EE)
    /// Soft wash for selected rows / tinted fills.
    static let coralWash     = dyn(light: 0xE1ECF6, dark: 0x122739)
    /// Semantic alias — prefer this name in new code.
    static var brand: Color { coral }
    static var brandDeep: Color { coralDeep }
    static var brandWash: Color { coralWash }

    // MARK: Feather palette (categorical data + nav tints)

    /// The macaw RED — data, the Dashboard nav tint, the speed gauge, the streak.
    static let featherCoral  = dyn(light: 0xE0342B, dark: 0xF0473B)
    static let featherGold   = dyn(light: 0xEFA21E, dark: 0xF4B33E)
    static let featherBlue   = dyn(light: 0x2585CE, dark: 0x4AA0E6)
    static let featherGreen  = dyn(light: 0x1FA85C, dark: 0x34C172)
    static let featherPlum   = dyn(light: 0x8A6FB0, dark: 0xA98FCB)
    /// Clearer alias for the macaw red.
    static var featherRed: Color { featherCoral }

    /// Ordered categorical ramp for charts (app-usage bars, etc).
    static let categorical: [Color] = [featherCoral, featherGold, featherBlue, featherGreen, featherPlum]

    // MARK: Heatmap ramp (deep red, low → high)

    /// 0 = empty, then four warming steps toward the deep-red `heat.hot`.
    static func heat(_ level: Int) -> Color {
        switch max(0, min(4, level)) {
        case 0:  return surfaceSunken
        case 1:  return dyn(light: 0xD99D9A, dark: 0x793533)
        case 2:  return dyn(light: 0xD07570, dark: 0xA03B35)
        case 3:  return dyn(light: 0xC84E46, dark: 0xC84138)
        default: return dyn(light: 0xC0271C, dark: 0xF0473B)
        }
    }

    // MARK: Semantic

    static let positive      = featherGreen
    static let warning       = featherGold
    static let danger        = featherCoral

    // MARK: Metrics

    enum Radius {
        /// Squircle (superellipse) card corner.
        static let card: CGFloat = 22
        static let control: CGFloat = 13
        static let chip: CGFloat = 9
    }

    enum Space {
        static let card: CGFloat = 20
        static let gridGap: CGFloat = 14
        static let section: CGFloat = 24
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
    /// Display serif (Young Serif, bundled) — page titles & hero headlines.
    /// Falls back to the system serif if the bundled face isn't registered.
    static func talkieDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        TalkieFonts.display(size: size, weight: weight)
    }
    /// Serif for big metric numbers (e.g. "184,920").
    static func talkieMetric(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        TalkieFonts.display(size: size, weight: weight)
    }
    /// Functional UI heading (SF Pro).
    static func talkieHeading(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }
    /// All-caps eyebrow label used above cards & sections.
    static var talkieEyebrow: Font { .system(size: 11, weight: .semibold) }
}

/// Resolves the bundled display serif once, with a graceful serif fallback so
/// debug builds (which don't assemble the .app) still render a serif headline.
enum TalkieFonts {
    static let displayName = "Young Serif"

    /// True when the bundled face is registered (it's installed via the app
    /// bundle's `ATSApplicationFontsPath` at launch).
    static let hasDisplay: Bool = NSFont(name: displayName, size: 12) != nil

    static func display(size: CGFloat, weight: Font.Weight) -> Font {
        if hasDisplay {
            return .custom(displayName, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Card surface

extension View {
    /// Standard Talkie card: borderless — a clean surface lifted by a single
    /// whisper shadow, squircle corner. No outline (v2).
    func talkieCard(padding: CGFloat = Theme.Space.card) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surface)
            )
            .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.07), radius: 20, x: 0, y: 10)
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

// MARK: - Native material (vibrancy / translucency)

/// A real macOS vibrancy material — the system sidebar/HUD translucency the
/// custom views can't fake. Used as the sidebar background so the desktop
/// frosts through, exactly like a native Mac app.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.state = .active
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
