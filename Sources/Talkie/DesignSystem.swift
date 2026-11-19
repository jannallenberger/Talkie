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
    /// Darkened/lightened from the original 0x969AA1 / 0x70747B (~2.6:1 light,
    /// ~3.7:1 dark against `surface` — fails WCAG AA) to ~4.5:1+ against both
    /// `surface` and `canvas` in each mode. Same cool undertone (hue ratio
    /// preserved, only luminance shifted) so the small body text this styles
    /// everywhere (captions, hints, meta lines) stays legible without looking
    /// like a different color.
    static let inkTertiary   = dyn(light: 0x6A6E76, dark: 0x80848B)
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

    /// The single shared warm gold→red data-viz ramp (gauges, progress fills).
    static var emberRamp: Gradient { Gradient(colors: [featherGold, featherCoral]) }

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

    /// The streak heatmap ramp, tied to `emberRamp` so the grid reads as the same
    /// warm family as the gauge and words-per-day chart. Level 0 is the empty cell;
    /// 1…4 interpolate featherGold → featherCoral by intensity. The heatmap cells
    /// AND the "Less … More" legend must both use this so they never drift apart.
    static func emberHeat(_ level: Int) -> Color {
        let l = max(0, min(4, level))
        return l == 0 ? surfaceSunken
                      : featherGold.mix(with: featherCoral, by: Double(l - 1) / 3.0)
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
    /// The brand surface treatment, padding-free: a squircle fill, clipped to the
    /// corner so stacked rows / dividers can't poke past it, lifted by two whisper
    /// shadows. `talkieCard` adds padding on top; grouped row-stacks (the settings
    /// cards) apply it directly so their hairlines clip cleanly.
    func talkieSurface(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.surface)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.07), radius: 20, x: 0, y: 10)
    }

    /// Standard Talkie card: borderless — a clean surface lifted by a single
    /// whisper shadow, squircle corner. No outline (v2).
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
            .background(Capsule(style: .continuous).fill(fill))
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 && isEnabled }
    }

    private var foreground: Color {
        switch kind {
        case .primary:     return .white
        case .secondary:   return Theme.ink
        case .destructive: return Theme.featherRed
        case .quiet:       return tint ?? (hovering ? Theme.ink : Theme.inkSecondary)
        }
    }

    private var fill: Color {
        let pressed = configuration.isPressed && isEnabled
        switch kind {
        case .primary:
            let base = tint ?? Theme.coral
            if pressed { return tint == nil ? Theme.coralDeep : base.opacity(0.8) }
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
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Theme.brand, lineWidth: isSelected ? 2 : 0))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.07), radius: 20, x: 0, y: 10)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 && isEnabled }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        let base = isSelected ? Theme.surface.mix(with: Theme.brandWash, by: 0.6) : Theme.surface
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
            .fill(Theme.canvas)
            .shadow(color: .black.opacity(0.18), radius: 0.5, x: 0, y: 1))
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

/// What paints behind a page: the flat canvas, the Dashboard's ambient ember,
/// or nothing (the caller paints, e.g. a drop-target wash over the canvas).
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
        content
            .padding(.top, Theme.Space.pageTop)
            .padding(.horizontal, Theme.Space.pageSide)
            .padding(.bottom, bottom ? Theme.Space.pageBottom : 0)
    }
}

/// The scrolling page container every main-window page sits in: one ScrollView,
/// the fixed page insets, a left-aligned column, and the page background.
struct TalkieScrollPage<Content: View>: View {
    var spacing: CGFloat = 18
    var background: TalkiePageBackground = .canvas
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .talkiePagePadding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        // No toolbar material when content scrolls under the transparent toolbar.
        .scrollEdgeEffectHidden(true, for: .top)
        .background { backgroundView }
    }

    @ViewBuilder private var backgroundView: some View {
        switch background {
        case .canvas:  Theme.canvas
        case .ambient: LiveBackground(mood: .ambient)
        case .none:    Color.clear
        }
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

    /// The marketing / project home URL. Today the product's home IS its public
    /// GitHub repository, so this is a documented alias of `repoURL` (same
    /// Info.plist-sourced value, kept out of Swift source so `check-no-network.sh`
    /// stays green). Kept as a distinct accessor so a future marketing site can be
    /// pointed at its own Info.plist key without touching call sites.
    @MainActor static var marketingURL: String? { repoURL }

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
    static let mcpConnectorVersion = "0.4.0"

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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : max(0, x - spacing)
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
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
