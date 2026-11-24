import SwiftUI
import AppKit

// MARK: - Talkie Design System (v3 — logo colours on Liquid Glass)
//
// Brand DNA: the layered scarlet-macaw logo, its colours behind every page, and
// glass on top.
//
//   • Backdrop — a one-direction gradient of the logo's feathers over the canvas
//               (white in light, near-black in dark), turned a step per page
//               (`TalkieBackdrop`, Appearance.swift). The user picks the palette,
//               its strength and its angle.
//   • Surfaces — cards are Liquid Glass over that backdrop (`talkieSurface`);
//               opaque when the user picks Solid or the Mac reduces transparency.
//   • Accent  — one feather leads the chrome (primary action, selection, focus).
//               EMBER by default; the user can pick another. Kept under the
//               historical name `coral` so every existing call site stays valid.
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

    /// The base under the backdrop gradient — pure white / near black.
    static let canvas        = dyn(light: 0xFFFFFF, dark: 0x050506)
    /// Sidebar / chrome fallback (the real sidebar is Liquid Glass).
    static let canvasRaised  = dyn(light: 0xEFF1F3, dark: 0x121214)
    /// The opaque card fill: Solid cards, Reduce Transparency, and anything that
    /// must not show what is behind it.
    static let surfaceSolid  = dyn(light: 0xF5F6F8, dark: 0x1B1B1E)
    /// A frosted fill for small raised pieces drawn straight on the page (tiles,
    /// floating labels). Cards themselves use `.talkieSurface()` (Liquid Glass).
    static var surface: Color { ThemeState.flatSurfaces ? surfaceSolid : surfaceFrost }
    private static let surfaceFrost = dyn(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.62, darkAlpha: 0.10)
    /// The row surface's fill when cards are Clear glass: thinner than the frost, so
    /// rows of a long list read like the clear cards around them.
    static let surfaceRowClear = dyn(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.42, darkAlpha: 0.07)
    /// The row surface's fine light edge (the glass rim, as one colour).
    static let rowRim = dyn(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.7, darkAlpha: 0.12)
    /// Inset wells, chart tracks, chips, empty heatmap cells: a translucent ink
    /// tint, so it reads as "pressed in" on glass and on the page alike.
    static let surfaceSunken = dyn(light: 0x1C1D20, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.11)

    // MARK: Ink

    static let ink           = dyn(light: 0x1C1D20, dark: 0xF4F5F6)
    static let inkSecondary  = dyn(light: 0x5E626A, dark: 0xA6AAB0)
    /// Darkened/lightened from the original 0x969AA1 / 0x70747B (~2.6:1 light,
    /// ~3.7:1 dark against `surface` — fails WCAG AA) to ~4.5:1+ against both
    /// `surface` and `canvas` in each mode. Same cool undertone (hue ratio
    /// preserved, only luminance shifted) so the small body text this styles
    /// everywhere (captions, hints, meta lines) stays legible without looking
    /// like a different color.
    static let inkTertiary   = dyn(light: 0x6A6E76, dark: 0x80848B)
    /// Row dividers only — never an element outline.
    static let hairline      = dyn(light: 0xE6E8EB, dark: 0x2B2B2F)

    // MARK: Brand accent — the feather the user picked (ember by default)

    /// The brand accent. Buttons, selection, focus, links.
    /// (Named `coral` for call-site compatibility; the value follows the
    /// accent chosen in Settings ▸ Appearance.)
    static var coral: Color { ThemeState.accent.palette.base }
    /// Deeper press/emphasis state.
    static var coralDeep: Color { ThemeState.accent.palette.deep }
    /// Soft wash for selected rows / tinted fills.
    static var coralWash: Color { ThemeState.accent.palette.wash }
    /// Semantic alias — prefer this name in new code.
    static var brand: Color { coral }
    static var brandDeep: Color { coralDeep }
    static var brandWash: Color { coralWash }
    /// Text and glyphs on a `brand` fill (white, or ink on the light feathers in dark mode).
    static var onBrand: Color { ThemeState.accent.palette.on }
    /// A raised key cap: opaque, lighter than the card it sits on.
    static let keycap        = dyn(light: 0xFFFFFF, dark: 0x3A3A3F)
    /// The light catching the top edge of glass and of raised controls.
    static let glassRim      = dyn(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.85, darkAlpha: 0.22)

    // MARK: Feather palette (categorical data + nav tints)

    /// The macaw RED — data, the Dashboard nav tint, the speed gauge, the streak.
    static let featherCoral  = dyn(light: 0xE0342B, dark: 0xF0473B)
    static let featherGold   = dyn(light: 0xEFA21E, dark: 0xF4B33E)
    static let featherBlue   = dyn(light: 0x2585CE, dark: 0x4AA0E6)
    static let featherGreen  = dyn(light: 0x1FA85C, dark: 0x34C172)
    static let featherPlum   = dyn(light: 0x8A6FB0, dark: 0xA98FCB)
    /// Clearer alias for the macaw red.
    static var featherRed: Color { featherCoral }

    /// The colours of charts, gauges and progress fills: the feathers of the
    /// backdrop the user picked, so graphs are tuned to the page behind them.
    static var dataColors: [Color] { ThemeState.backdrop.dataColors }
    /// `dataColors` as one ramp (gauge sweeps, progress fills).
    static var dataRamp: Gradient { Gradient(colors: dataColors) }
    /// The data ramp under its historical name (it was a fixed gold→red).
    static var emberRamp: Gradient { dataRamp }
    /// The colour at `fraction` (0…1) along the data ramp.
    static func dataColor(at fraction: Double) -> Color {
        let colors = dataColors
        guard colors.count > 1 else { return colors.first ?? featherCoral }
        let position = min(1, max(0, fraction)) * Double(colors.count - 1)
        let index = min(colors.count - 2, Int(position))
        return colors[index].mix(with: colors[index + 1], by: position - Double(index))
    }
    /// The `index`-th categorical colour of the data palette (series, legend dots),
    /// wrapping round.
    static func dataColor(series index: Int) -> Color {
        let colors = dataColors
        return colors[((index % colors.count) + colors.count) % colors.count]
    }

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

    /// The streak heatmap ramp: level 0 is the empty cell, 1…4 are the accent
    /// growing stronger — one hue, so "more" always reads as "more" whatever the
    /// backdrop's colours are. The heatmap cells AND the "Less … More" legend must
    /// both use this so they never drift apart.
    static func emberHeat(_ level: Int) -> Color {
        let l = max(0, min(4, level))
        return l == 0 ? surfaceSunken : brand.opacity(0.22 + 0.26 * Double(l - 1))
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
        /// Window top edge → page title. The window has no toolbar strip, so this
        /// is the whole top area (it still clears the traffic lights, which sit
        /// over the sidebar).
        static let pageTop: CGFloat = 36
        /// Leading/trailing page inset.
        static let pageSide: CGFloat = 28
        /// Bottom inset under the last card of a scrolling page.
        static let pageBottom: CGFloat = 28
        /// The zone at the top and bottom of a scrolling page where content runs
        /// into the system's scroll edge blur.
        static let edgeBar: CGFloat = 28
        /// Inner padding of a popover (`TalkiePopover`).
        static let popover: CGFloat = 16
        /// Inner padding of a sheet.
        static let sheet: CGFloat = 20
    }

    /// Fixed widths for transient surfaces, so popovers and sheets line up app-wide.
    enum Width {
        /// A popover holding a short form (one field, one switch).
        static let popover: CGFloat = 320
        /// A popover with longer help text or two columns of controls.
        static let popoverWide: CGFloat = 360
        static let sheet: CGFloat = 480
        static let sheetWide: CGFloat = 560
    }

    // MARK: Dynamic color helper

    /// A light/dark-adaptive color from two hex values.
    static func dyn(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let color = NSColor(hex: isDark ? dark : light)
            let alpha = isDark ? darkAlpha : lightAlpha
            return alpha < 1 ? color.withAlphaComponent(alpha) : color
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
    /// The brand surface treatment, padding-free: Liquid Glass in a squircle,
    /// clipped to the corner so stacked rows / dividers can't poke past it.
    /// `talkieCard` adds padding on top; grouped row-stacks (the settings cards)
    /// apply it directly so their hairlines clip cleanly. Opaque (with the two
    /// whisper shadows) when the user chose Solid cards or reduces transparency.
    func talkieSurface(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        modifier(TalkieGlassSurface(cornerRadius: cornerRadius))
    }

    /// Standard Talkie card: padded content on the glass surface, squircle corner.
    func talkieCard(padding: CGFloat = Theme.Space.card, fill: Bool = false) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: fill ? .topLeading : .leading)
            .talkieSurface()
    }
}

/// A small all-caps eyebrow label (e.g. "WORDS PER MINUTE").
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.loc.uppercased())
            .font(.talkieEyebrow)
            .tracking(0.8)
            .foregroundStyle(Theme.inkSecondary)
    }
}

// MARK: - Section label

/// A section label above a group of cards: the eyebrow caps, optionally with
/// one line of sentence-case help under it. The one section-label style on every
/// main-window page (Settings groups included).
struct TalkieSectionLabel: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(text: title)
            if let subtitle {
                Text(LocalizedStringKey(subtitle))
                    .font(.talkieHeading(12, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

// MARK: - Buttons

/// The four button roles of the main window.
///   • primary     — filled accent capsule; one per area, the main action.
///   • secondary   — soft surface capsule (ink label); every other action.
///   • quiet       — icon-only, no fill until hovered; toolbar-like affordances.
///   • destructive — the secondary shape with a feather-red label.
enum TalkieButtonKind {
    case primary, secondary, quiet, destructive
}

/// Regular for page-level actions, small for inline rows. When a site doesn't
/// say, the size follows the environment's `controlSize` (`.small`/`.mini` →
/// small), so existing `.controlSize(.small)` rows keep reading as inline.
enum TalkieButtonSize {
    case regular, small
}

struct TalkieButtonStyle: ButtonStyle {
    var kind: TalkieButtonKind
    var size: TalkieButtonSize? = nil
    /// Overrides the accent for `.primary` (the fill) and `.quiet` (the glyph).
    /// Only for recording (featherRed); everything else stays on the brand accent.
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        TalkieButtonBody(configuration: configuration, kind: kind, size: size, tint: tint)
    }
}

extension ButtonStyle where Self == TalkieButtonStyle {
    /// `.buttonStyle(.talkie(.primary))`, `.buttonStyle(.talkie(.secondary, size: .small))`.
    static func talkie(_ kind: TalkieButtonKind, size: TalkieButtonSize? = nil,
                       tint: Color? = nil) -> TalkieButtonStyle {
        TalkieButtonStyle(kind: kind, size: size, tint: tint)
    }
}

private struct TalkieButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: TalkieButtonKind
    let size: TalkieButtonSize?
    let tint: Color?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @ObservedObject private var appearance = AppearanceStore.shared
    @State private var hovering = false

    private var small: Bool {
        if let size { return size == .small }
        return controlSize == .small || controlSize == .mini
    }

    private var height: CGFloat { small ? 24 : 30 }

    var body: some View {
        configuration.label
            .font(.system(size: small ? 12 : 13, weight: kind == .primary ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .quiet ? 0 : (small ? 9 : 14))
            .frame(minWidth: kind == .quiet ? height : nil, minHeight: height)
            .background(background)
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 && isEnabled }
    }

    /// The capsule: its fill, then the light on its top edge (the "shine").
    /// Primary is a lit accent gradient with a soft glow of its own colour;
    /// secondary and destructive are a pressed-in tint with a fine rim.
    @ViewBuilder private var background: some View {
        let capsule = Capsule(style: .continuous)
        switch kind {
        case .primary:
            let base = tint ?? appearance.look.accent.palette.base
            capsule
                .fill(LinearGradient(colors: [fill.mix(with: .white, by: 0.16), fill],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(capsule.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: base.opacity(isEnabled ? 0.30 : 0), radius: small ? 4 : 7, x: 0, y: small ? 2 : 3)
        case .secondary, .destructive:
            capsule
                .fill(fill)
                .overlay(capsule.strokeBorder(
                    LinearGradient(colors: [Theme.glassRim, Theme.glassRim.opacity(0.15)],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
        case .quiet:
            capsule.fill(fill)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary:     return tint == nil ? appearance.look.accent.palette.on : .white
        case .secondary:   return Theme.ink
        case .destructive: return Theme.featherRed
        case .quiet:       return tint ?? (hovering ? Theme.ink : Theme.inkSecondary)
        }
    }

    private var fill: Color {
        let pressed = configuration.isPressed && isEnabled
        let accent = appearance.look.accent.palette
        switch kind {
        case .primary:
            let base = tint ?? accent.base
            if pressed { return tint == nil ? accent.deep : base.opacity(0.8) }
            return hovering ? base.opacity(0.9) : base
        case .secondary, .destructive:
            if pressed { return Theme.surfaceSunken.mix(with: Theme.ink, by: 0.12) }
            return hovering ? Theme.surfaceSunken.mix(with: Theme.ink, by: 0.06) : Theme.surfaceSunken
        case .quiet:
            if pressed { return Theme.surfaceSunken.mix(with: Theme.ink, by: 0.06) }
            return hovering ? Theme.surfaceSunken : .clear
        }
    }
}

/// An on/off chip (a button-shaped toggle): accent wash + accent label when on,
/// the soft surface when off. Replaces `.toggleStyle(.button)`, whose look would
/// otherwise come from the page's button style and lose the on/off state.
struct TalkieChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(configuration.isOn ? Theme.coral : Theme.inkSecondary)
                .padding(.horizontal, 8)
                .frame(minWidth: 26, minHeight: 22)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(configuration.isOn ? Theme.coralWash : Theme.surfaceSunken)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

extension ToggleStyle where Self == TalkieChipToggleStyle {
    static var talkieChip: TalkieChipToggleStyle { TalkieChipToggleStyle() }
}

// MARK: - Menu picker

/// A picker that looks like the secondary button: a capsule whose label the
/// caller supplies (usually the current choice), opening a menu with the
/// options checkmarked like a native pop-up. Selection writes go through the
/// binding unchanged, so confirmations wired into it keep working.
struct TalkieMenuPicker<Value: Hashable, Options: View, MenuLabel: View>: View {
    @Binding var selection: Value
    @ViewBuilder var options: Options
    @ViewBuilder var label: MenuLabel

    var body: some View {
        Menu {
            Picker(selection: $selection) { options } label: { EmptyView() }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                label
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.talkie(.secondary))
        .fixedSize()
    }
}

/// An action menu ("Export…") that looks like the secondary button and, like
/// `TalkieMenuPicker`, carries a chevron so it reads as a menu, not a button.
struct TalkieMenuButton<Items: View, MenuLabel: View>: View {
    var size: TalkieButtonSize? = nil
    @ViewBuilder var items: Items
    @ViewBuilder var label: MenuLabel

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: 6) {
                label
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.talkie(.secondary, size: size))
        .fixedSize()
    }
}

// MARK: - Chips, tags, keycaps

/// A clickable chip (a speaker name, a removable term): chip radius, sunken fill
/// that darkens on hover, pressed scale. Callers add a trailing action glyph
/// (`pencil`, `xmark`, `chevron.down`) so a chip never reads as a static tag.
struct TalkieChipButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        TalkieChipBody(configuration: configuration, isSelected: isSelected)
    }
}

extension ButtonStyle where Self == TalkieChipButtonStyle {
    /// `.buttonStyle(.talkieChip)`.
    static var talkieChip: TalkieChipButtonStyle { TalkieChipButtonStyle() }
    static func talkieChip(selected: Bool) -> TalkieChipButtonStyle { TalkieChipButtonStyle(isSelected: selected) }
}

private struct TalkieChipBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
        configuration.label
            .font(.talkieHeading(12, weight: .semibold))
            .foregroundStyle(isSelected ? Theme.brand : Theme.ink)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(minHeight: 24)
            .background(shape.fill(fill))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 && isEnabled }
    }

    private var fill: Color {
        let base = isSelected ? Theme.brandWash : Theme.surfaceSunken
        if configuration.isPressed && isEnabled { return base.mix(with: Theme.ink, by: 0.12) }
        return hovering ? base.mix(with: Theme.ink, by: 0.06) : base
    }
}

// MARK: - Selectable cards

/// A whole card that is one button (a grid of choices, e.g. the Commands page's
/// format cards): the card surface and radius, a one-step fill shift on hover, the
/// pressed scale, and — when selected — a brand ring with the brand wash, so the
/// selection never relies on colour alone (the ring changes the outline too).
struct TalkieCardButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        TalkieCardButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

extension ButtonStyle where Self == TalkieCardButtonStyle {
    /// `.buttonStyle(.talkieCard(selected: …))`.
    static func talkieCard(selected: Bool) -> TalkieCardButtonStyle { TalkieCardButtonStyle(isSelected: selected) }
}

private struct TalkieCardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The state (hover, pressed, selected) is a tint laid on the glass.
            .background(shape.fill(tintFill))
            .talkieSurface()
            .overlay(shape.strokeBorder(Theme.brand, lineWidth: isSelected ? 2 : 0))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 && isEnabled }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var tintFill: Color {
        let base = isSelected ? Theme.brand.opacity(0.12) : Color.clear
        if configuration.isPressed && isEnabled { return base.mix(with: Theme.ink, by: 0.08) }
        return hovering ? base.mix(with: Theme.ink, by: 0.04) : base
    }
}

/// A static, non-interactive tag ("slower"). Capsule, no hover, no glyph — so it
/// can never be mistaken for a chip button.
struct TalkieTag: View {
    let text: String
    /// Show `text` exactly as given (spoken phrases, names) — never look it up as a
    /// localisation key.
    var isVerbatim = false

    init(text: String) { self.text = text }

    init(verbatim text: String) {
        self.text = text
        self.isVerbatim = true
    }

    var body: some View {
        Group {
            if isVerbatim { Text(verbatim: text) } else { Text(LocalizedStringKey(text)) }
        }
            .font(.talkieHeading(11, weight: .medium))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(Theme.surfaceSunken))
    }
}

/// A spoken word next to the character it becomes ("colon" -> ":"). Static and never
/// clickable: sunken chip radius for the character, quiet text for the word, so it reads
/// as a reference entry and cannot be mistaken for a chip button.
struct TalkieWordMark: View {
    let word: String
    let mark: String

    var body: some View {
        HStack(spacing: 7) {
            Text(verbatim: mark)
                .font(.talkieHeading(12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 18)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(Theme.surfaceSunken))
            Text(verbatim: word)
                .font(.talkieHeading(12, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(word): \(mark)"))
    }
}

/// "Show all" / "Show fewer" under a shortened list: a small secondary button (so it
/// has the shared hover and press feedback) with a chevron that turns when open.
struct TalkieDisclosureButton: View {
    @Binding var isExpanded: Bool
    var collapsedTitle: String = "Show all".loc
    var expandedTitle: String = "Show fewer".loc

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text(isExpanded ? expandedTitle : collapsedTitle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .buttonStyle(.talkie(.secondary, size: .small))
        .accessibilityValue(Text(isExpanded ? "Expanded".loc : "Collapsed".loc))
    }
}

/// One of the user's real keys drawn as a key cap (dictation key, format key).
/// Never clickable; pair it with a separate "Change…" button.
struct TalkieKeycap: View {
    let text: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.talkieHeading(12, weight: .semibold))
            }
            Text(verbatim: text)
        }
        .font(.talkieHeading(13, weight: .semibold))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // A raised key (canvas + a 1pt key shadow), deliberately unlike the sunken
        // fill of buttons and chips: a keycap shows a key, it is not clickable.
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
            .fill(Theme.keycap)
            .shadow(color: .black.opacity(0.18), radius: 0.5, x: 0, y: 1))
    }
}

// MARK: - Slider

/// The arithmetic of `TalkieSlider`, pure so it is unit-tested.
enum TalkieSliderMath {
    /// The value under a pointer at `x` in a track `width` wide whose thumb is
    /// `thumb` across: the thumb's centre follows the pointer, clamped to the track.
    static func value(atX x: CGFloat, width: CGFloat, thumb: CGFloat,
                      range: ClosedRange<Double>, step: Double?) -> Double {
        let travel = max(1, width - thumb)
        let fraction = Double(min(1, max(0, (x - thumb / 2) / travel)))
        return snapped(range.lowerBound + fraction * (range.upperBound - range.lowerBound), range: range, step: step)
    }

    /// Where the thumb's leading edge sits for `value`.
    static func thumbOffset(value: Double, width: CGFloat, thumb: CGFloat, range: ClosedRange<Double>) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let fraction = min(1, max(0, (value - range.lowerBound) / span))
        return CGFloat(fraction) * max(0, width - thumb)
    }

    /// `value` moved by `steps` keyboard/VoiceOver increments (a twentieth of the
    /// range each, or one `step`).
    static func nudged(_ value: Double, by steps: Int, range: ClosedRange<Double>, step: Double?) -> Double {
        let unit = step ?? (range.upperBound - range.lowerBound) / 20
        return snapped(value + Double(steps) * unit, range: range, step: step)
    }

    static func snapped(_ value: Double, range: ClosedRange<Double>, step: Double?) -> Double {
        var v = value
        if let step, step > 0 { v = range.lowerBound + ((v - range.lowerBound) / step).rounded() * step }
        return min(range.upperBound, max(range.lowerBound, v))
    }
}

/// The one slider: a sunken track filled with the accent up to a white, lit thumb.
/// Drag anywhere on it, or click to jump; arrow keys and VoiceOver adjust it.
struct TalkieSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double? = nil
    /// What the slider sets, for VoiceOver ("Strength").
    let label: String
    /// The spoken value ("40 %", "135°"); the fraction of the range when nil.
    var valueText: String? = nil

    @Environment(\.isEnabled) private var isEnabled
    @ObservedObject private var appearance = AppearanceStore.shared
    @State private var dragging = false
    @State private var hovering = false
    @FocusState private var focused: Bool

    private static let thumb: CGFloat = 20
    private static let track: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let offset = TalkieSliderMath.thumbOffset(value: value, width: width, thumb: Self.thumb, range: range)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.surfaceSunken)
                    .frame(height: Self.track)
                Capsule(style: .continuous)
                    .fill(appearance.look.accent.palette.base)
                    .frame(width: offset + Self.thumb / 2, height: Self.track)
                Circle()
                    .fill(LinearGradient(colors: [.white, Color(white: 0.93)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.22), radius: dragging ? 5 : 3, x: 0, y: dragging ? 2 : 1)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .scaleEffect(dragging ? 1.12 : (hovering ? 1.05 : 1))
                    .offset(x: offset)
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragging = true
                        let next = TalkieSliderMath.value(atX: gesture.location.x, width: width, thumb: Self.thumb,
                                                          range: range, step: step)
                        if next != value { value = next }
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 24)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.12), value: dragging)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 && isEnabled }
        .focusable()
        .focused($focused)
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: value = TalkieSliderMath.nudged(value, by: -1, range: range, step: step)
            case .right, .up:  value = TalkieSliderMath.nudged(value, by: 1, range: range, step: step)
            default: break
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: valueText ?? defaultValueText))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = TalkieSliderMath.nudged(value, by: 1, range: range, step: step)
            case .decrement: value = TalkieSliderMath.nudged(value, by: -1, range: range, step: step)
            @unknown default: break
            }
        }
    }

    private var defaultValueText: String {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return "" }
        return "\(Int(((value - range.lowerBound) / span * 100).rounded())) %"
    }
}

// MARK: - Status lines & notices

enum TalkieStatusTone {
    case info, progress, success, warning, error
}

/// One inline line of status: a spinner or a tone icon, then the text. The single
/// look for "Identifying speakers…", "Couldn't read this voice", "Still off: …".
struct TalkieStatusLine: View {
    let text: String
    var tone: TalkieStatusTone = .info

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            leading
            Text(verbatim: text)
                .font(.talkieHeading(12, weight: .regular))
                .foregroundStyle(tone == .error ? Theme.danger : Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var leading: some View {
        switch tone {
        case .progress:
            ProgressView().controlSize(.small).scaleEffect(0.75)
                .frame(width: 13, height: 13)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        case .info:    icon("info.circle", Theme.inkTertiary)
        case .success: icon("checkmark.circle.fill", Theme.positive)
        case .warning: icon("exclamationmark.triangle.fill", Theme.warning)
        case .error:   icon("exclamationmark.octagon.fill", Theme.danger)
        }
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 13)
            .accessibilityHidden(true)
    }
}

/// A dismissible inline notice on a control-radius surface: an icon, the message,
/// optional actions, and a quiet × (e.g. the update reminder on the Dashboard).
struct TalkieNotice<Actions: View>: View {
    let text: String
    var icon: String = "info.circle"
    var onDismiss: (() -> Void)? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.talkieHeading(12.5, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.talkie(.quiet, size: .small))
                .help("Dismiss".loc)
                .accessibilityLabel("Dismiss".loc)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .talkieSurface(cornerRadius: Theme.Radius.control)
    }
}

// MARK: - Forms

/// A labelled field for popovers and sheets: the label above, the field at full
/// width, optional help text under it.
struct TalkieField<Field: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(label))
                .font(.talkieHeading(12, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
            field
                .frame(maxWidth: .infinity, alignment: .leading)
            if let help {
                Text(LocalizedStringKey(help))
                    .font(.talkieHeading(11.5, weight: .regular))
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A switch with its title and one-line subtitle (the consequence, e.g. a privacy
/// note), switch on the right. No outer padding: `SettingsToggleRow` pads it for a
/// card; a popover uses it as-is.
struct TalkieSwitchRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.talkieHeading(14, weight: .medium)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(verbatim: subtitle).font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.brand)
        }
        .frame(maxWidth: .infinity)
        // The title lives beside a `.labelsHidden()` switch: fold it into the label.
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The sunken well a multi-line `TextEditor` sits in (notes, transcript edits).
    func talkieWell() -> some View {
        self
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Theme.surfaceSunken,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

// MARK: - Popover / sheet scaffold

/// The one popover layout: a sentence-case title (+ optional subtitle), the
/// content, then the action row last. Fixed width from `Theme.Width`.
struct TalkiePopover<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var width: CGFloat = Theme.Width.popover
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.talkieHeading(15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            actions
        }
        .padding(Theme.Space.popover)
        .frame(width: width, alignment: .leading)
    }
}

extension TalkiePopover where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, width: CGFloat = Theme.Width.popover,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, width: width, content: content, actions: { EmptyView() })
    }
}

/// A full-width hairline between sections of a popover or sheet.
struct TalkiePopoverDivider: View {
    var body: some View {
        Divider().overlay(Theme.hairline)
            .padding(.horizontal, -Theme.Space.popover)
    }
}

/// The action row at the bottom of a popover or sheet: a destructive or clearing
/// action at the leading edge; Cancel then the primary at the trailing edge
/// (primary rightmost, `.defaultAction`; Cancel `.cancelAction`).
struct TalkieActionRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 12)
            trailing
        }
        .padding(.top, 2)
    }
}

extension TalkieActionRow where Leading == EmptyView {
    init(@ViewBuilder trailing: () -> Trailing) {
        self.init(leading: { EmptyView() }, trailing: trailing)
    }
}

// MARK: - Page scaffold

extension Font {
    /// The page title: serif 26 on every main-window page.
    static var talkiePageTitle: Font { .talkieDisplay(26) }
}

private struct TalkiePushedPageKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a page pushed onto a `NavigationStack` (set by the
    /// `navigationDestination`s via `.talkiePushedPage()`).
    var talkiePushedPage: Bool {
        get { self[TalkiePushedPageKey.self] }
        set { self[TalkiePushedPageKey.self] = newValue }
    }
}

/// Which back control a page shows. Exactly one per pushed page: an in-page
/// Liquid Glass back button at the leading edge of the title row (visible in
/// windowed AND fullscreen mode — the toolbar auto-hides in fullscreen, so a
/// toolbar back button would be hidden in the slide-down bar). The system
/// navigation back button is hidden, so the toolbar carries no page items.
/// Root pages show neither.
enum TalkieBackPolicy {
    struct Controls: Equatable {
        let inPageGlassButton: Bool
        let systemBackButton: Bool
    }

    static func controls(pushed: Bool) -> Controls {
        Controls(inPageGlassButton: pushed, systemBackButton: false)
    }
}

extension View {
    /// Marks a navigation destination as a pushed page: its header shows the
    /// in-page glass back button and the system back button is hidden.
    /// Also re-applies the page default button style: navigation destinations
    /// don't inherit the environment set around the hosting `NavigationStack`.
    func talkiePushedPage() -> some View {
        environment(\.talkiePushedPage, true)
            .buttonStyle(.talkie(.secondary))
            .navigationBarBackButtonHidden(!TalkieBackPolicy.controls(pushed: true).systemBackButton)
    }
}

extension VerticalAlignment {
    private enum TalkieTitleCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    /// The vertical centre of a page title's first line, so the back button
    /// centres on the title rather than on title + subtitle.
    static let talkieTitleCenter = VerticalAlignment(TalkieTitleCenter.self)
}

/// The back control of a pushed page: a circular Liquid Glass button (the
/// system glass style, interactive) with a chevron, at the leading edge of the
/// title row. Renders nothing on root pages. Pops via `dismiss`; ⌘[ works too.
struct TalkieBackButton: View {
    @Environment(\.talkiePushedPage) private var pushed
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if TalkieBackPolicy.controls(pushed: pushed).inPageGlassButton {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help("Back".loc)
            .accessibilityLabel(Text("Back".loc))
            .keyboardShortcut("[", modifiers: .command)
            .alignmentGuide(.talkieTitleCenter) { $0[VerticalAlignment.center] }
        }
    }
}

/// The one page header: (glass back button when pushed) · serif-26 title + optional
/// 13pt subtitle · optional trailing actions, top-aligned with the title.
struct TalkiePageHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        // Actions sit beside the title while the title column keeps a readable
        // width; on a narrower window they drop to their own row under it.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                titledRow
                    .frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity, alignment: .leading)
                actionRow
            }
            VStack(alignment: .leading, spacing: 12) {
                titledRow
                actionRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Back button (pushed pages only) centred on the title's line, title block
    /// to its right.
    private var titledRow: some View {
        HStack(alignment: .talkieTitleCenter, spacing: 12) {
            TalkieBackButton()
            titleBlock
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title))
                .font(.talkiePageTitle)
                .foregroundStyle(Theme.ink)
                .alignmentGuide(.talkieTitleCenter) { $0[VerticalAlignment.center] }
            if let subtitle {
                Text(LocalizedStringKey(subtitle))
                    .font(.talkieHeading(13, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) { actions }
            .fixedSize()
    }
}

extension TalkiePageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// What paints behind a page. The main window draws the logo-colour backdrop
/// once, behind the sidebar and every page, so pages themselves are see-through:
/// `canvas` and `ambient` both mean "the shared backdrop"; `none` is for a caller
/// that lays a wash of its own over it (a drop target).
enum TalkiePageBackground {
    case canvas, ambient, none
}

extension View {
    /// The fixed page insets (top / sides / bottom) from `Theme.Space`.
    func talkiePagePadding(bottom: Bool = true) -> some View {
        modifier(TalkiePagePadding(bottom: bottom))
    }
}

private struct TalkiePagePadding: ViewModifier {
    let bottom: Bool

    func body(content: Content) -> some View {
        // The scroll edge bars (`talkieScrollEdgeFades`) already take `edgeBar`
        // of the top and the bottom.
        content
            .padding(.top, Theme.Space.pageTop - Theme.Space.edgeBar)
            .padding(.horizontal, Theme.Space.pageSide)
            .padding(.bottom, bottom ? Theme.Space.pageBottom - Theme.Space.edgeBar : 0)
    }
}

/// The scrolling page container every main-window page sits in: one ScrollView,
/// the fixed page insets, a left-aligned column, and the page background.
struct TalkieScrollPage<Content: View>: View {
    var spacing: CGFloat = 18
    var background: TalkiePageBackground = .canvas
    @ViewBuilder var content: Content

    @ObservedObject private var appearance = AppearanceStore.shared

    var body: some View {
        ScrollView {
            // No `GlassEffectContainer` around the page: it draws every card's glass
            // in one layer ABOVE anything that is not inside a card, so a control
            // laid over a card from outside (a switch in a card's corner) ended up
            // behind the glass.
            VStack(alignment: .leading, spacing: spacing) { content }
                .talkiePagePadding()
                .frame(maxWidth: .infinity, alignment: .leading)
                // A new accent, backdrop or card style repaints the page (colour
                // tokens are plain reads).
                .id(appearance.look.paintKey)
        }
        .scrollContentBackground(.hidden)
        // The system's soft scroll edge effect, top and bottom (the bars it needs
        // take `Space.edgeBar` of each edge; the page padding is trimmed to match).
        .talkieScrollEdgeFades()
    }
}

/// The standard page: header (title, subtitle, actions) over scrolling content.
struct TalkiePage<Actions: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var spacing: CGFloat = 18
    var background: TalkiePageBackground = .canvas
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        TalkieScrollPage(spacing: spacing, background: background) {
            TalkiePageHeader(title: title, subtitle: subtitle) { actions }
            content
        }
    }
}

extension TalkiePage where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, spacing: CGFloat = 18,
         background: TalkiePageBackground = .canvas, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, spacing: spacing, background: background,
                  actions: { EmptyView() }, content: content)
    }
}

// MARK: - Brand assets (the real logo + generated art, bundled in Resources/Brand)

/// Loads brand imagery shipped in the app bundle. Use the *actual* parrot logo
/// here — not `NSApp.applicationIconImage` (the rounded-square app icon).
enum Brand {
    /// The scarlet-macaw logo on transparent — the in-app mark.
    @MainActor static let logo: NSImage = image("TalkieLogo") ?? NSApp.applicationIconImage

    /// Talkie's public repository base URL, read from the `TalkieRepoURL` Info.plist
    /// key at runtime. Deliberately NOT a Swift string literal: a hard-coded web URL
    /// in `Sources/Talkie` would trip `check-no-network.sh` (it scans for the URL
    /// scheme even in comments), and the URL is config (not a user setting), so it
    /// lives in Info.plist. Used only to hand a link to the user's browser (the
    /// bug-report card) — never fetched in-process, so the zero-network wall holds.
    /// `nil` if the key is somehow absent (e.g. an un-assembled debug run), which
    /// callers treat as "no repo link available".
    @MainActor static var repoURL: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "TalkieRepoURL") as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The app's user-facing display name — the SINGLE source of truth for every
    /// chrome-tier surface (menu bar, About/Quit, window title, dashboard wordmark,
    /// proof card, bird-buddy labels, connector copy). Reads `CFBundleDisplayName`
    /// from `Bundle.main`, so a rebrand is a one-line Info.plist change that every
    /// display site follows — see `docs/REBRAND.md`.
    ///
    /// The `"Talkie"` fallback is load-bearing: a bare `swift test` run (or any
    /// context without the assembled app bundle) has no Info.plist, and without the
    /// fallback these strings would render empty. It is NOT a second brand constant —
    /// it only backstops the plist read.
    ///
    /// This is the DISPLAY name only. Every load-bearing identifier — the bundle id
    /// `com.coralate.talkie`, the executable `Contents/MacOS/Talkie`, the MCP
    /// protocol id `"talkie"`, the support/meetings directories, the `.talkiepack`
    /// UTType, the keychain service, the repo slug — is deliberately FROZEN and must
    /// never be derived from this value. See the FREEZE list in `docs/REBRAND.md`.
    ///
    /// `nonisolated`: this only reads `Bundle.main` (thread-safe), so it never needed
    /// the main actor. Making that explicit lets nonisolated contexts route brand text
    /// through it — notably `LocalizedError.errorDescription`, which the protocol
    /// declares nonisolated (so a `@MainActor`-only `displayName` could not be used to
    /// build a localized error message, the compile error that blocked that path).
    nonisolated static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "Talkie"
    }

    /// The website's base URL from the `TalkieWebsiteURL` Info.plist key (kept out
    /// of Swift source for `check-no-network.sh`); nil when absent. Only ever
    /// handed to the browser.
    nonisolated static var websiteURL: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "TalkieWebsiteURL") as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The product's home page: the website, else the repository.
    @MainActor static var marketingURL: String? { websiteURL ?? repoURL }

    /// The name to show for the on-device MCP connector in user-facing copy — a
    /// documented alias of `displayName`. The MCP *protocol* id stays the frozen
    /// literal `"talkie"` (see `MCPServer.swift` serverInfo and `BrandMirror`);
    /// only the human-readable label follows the display name.
    @MainActor static var mcpDisplayName: String { displayName }

    /// The version of the MCP connector THIS app bundles — the single in-app copy of
    /// the number that also lives in `connector/manifest.json` (the `.mcpb`),
    /// `MCPServer.swift` serverInfo, and the Claude Code plugin/marketplace manifests.
    /// `scripts/check-mcp-drift.sh` fails CI if these disagree, so this constant can
    /// be trusted as "what a freshly-installed connector reports". The connector card
    /// compares it against the version of an ALREADY-installed Claude Desktop
    /// extension to tell the user, honestly, whether theirs is stale after an app
    /// upgrade — the trap that otherwise leaves a months-old 6-tool connector running
    /// silently. Bump all copies together via `scripts/bump-connector-version.sh`.
    static let mcpConnectorVersion = "0.5.0"

    /// Decoded-once cache. Without it, `image(_:)` re-read the PNG from the
    /// bundle on every SwiftUI `body` pass, handing `Image` a fresh `NSImage`
    /// each time — so a hover-driven re-render re-decoded the bitmap and the tile
    /// flickered instead of just scaling. Caching keeps the instance (and thus
    /// `Image`'s identity) stable across re-renders.
    @MainActor private static var cache: [String: NSImage] = [:]

    /// Any bundled brand PNG by name (generated feather art, flags, …), memoized
    /// so repeated lookups return the same instance.
    @MainActor static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }
}

/// A bundled clay brand icon (Resources/Brand/<name>.png), with an SF Symbol
/// fallback if the asset is missing (e.g. an un-assembled debug run).
struct ClayIcon: View {
    let name: String
    var size: CGFloat = 24
    var fallback: String = "app.dashed"

    var body: some View {
        if let img = Brand.image(name) {
            Image(nsImage: img).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            Image(systemName: fallback)
                .font(.system(size: size * 0.78, weight: .semibold))
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Flow layout (left-packed, wrapping — for chips/tags)

/// Lays subviews left-to-right with a fixed gap, wrapping to the next line when
/// they run out of width. Unlike a grid, chips keep their natural width and an
/// even gap — no ragged equal-width cells.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    /// Each subview's natural size, measured once per change of the subviews instead
    /// of on every sizing AND placement pass (a hundred-plus vocabulary chips were
    /// measured several times per layout).
    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func updateCache(_ cache: inout [CGSize], subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for (index, _) in subviews.enumerated() {
            let size = cache[index]
            if x > 0, x + size.width > maxWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : max(0, x - spacing)
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for (index, sub) in subviews.enumerated() {
            let size = cache[index]
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
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
