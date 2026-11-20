import SwiftUI
import AppKit

// MARK: - Appearance (v3 — logo colours on glass)
//
// The look the user can shape: light or dark, which feather leads the chrome,
// which logo-colour gradient sits behind every page (and how strong, and at what
// angle), and how see-through the glass cards are. One store, read directly by
// the few design-system views that paint with it (`TalkieBackdrop`, the glass
// surface, buttons), so every window, panel, popover and sheet follows it without
// any wiring at their roots.

/// Light, dark, or whatever the Mac is set to.
enum TalkieAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Match the Mac".loc
        case .light:  return "Light (appearance)".loc
        case .dark:   return "Dark (appearance)".loc
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

/// The feather that leads the chrome: primary buttons, selection, focus, links.
enum TalkieAccent: String, CaseIterable, Identifiable, Sendable {
    case blue, red, gold, green, plum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue:  return "Blue".loc
        case .red:   return "Red".loc
        case .gold:  return "Gold".loc
        case .green: return "Green".loc
        case .plum:  return "Plum".loc
        }
    }

    /// The four colour roles of one accent, each light/dark adaptive.
    struct Palette {
        /// Fills and labels: ≥ 4.5:1 under white text in light mode.
        let base: Color
        /// Pressed and emphasised.
        let deep: Color
        /// The soft tint behind a selected row or chip.
        let wash: Color
        /// Text and glyphs on a `base` fill.
        let on: Color
    }

    var palette: Palette {
        switch self {
        case .blue:  return Self.bluePalette
        case .red:   return Self.redPalette
        case .gold:  return Self.goldPalette
        case .green: return Self.greenPalette
        case .plum:  return Self.plumPalette
        }
    }

    // Built once: `Theme.brand` is read on every render pass.
    private static let white: UInt32 = 0xFFFFFF
    private static let ink: UInt32 = 0x1C1D20
    private static let bluePalette = Palette(
        base: Theme.dyn(light: 0x1F66B3, dark: 0x4AA0E6), deep: Theme.dyn(light: 0x18548F, dark: 0x79B8EE),
        wash: Theme.dyn(light: 0xE1ECF6, dark: 0x122739), on: Theme.dyn(light: white, dark: white))
    private static let redPalette = Palette(
        base: Theme.dyn(light: 0xD12B22, dark: 0xF0473B), deep: Theme.dyn(light: 0xAE2019, dark: 0xF5766C),
        wash: Theme.dyn(light: 0xFBE4E2, dark: 0x3A1614), on: Theme.dyn(light: white, dark: white))
    private static let goldPalette = Palette(
        base: Theme.dyn(light: 0xA66300, dark: 0xF4B33E), deep: Theme.dyn(light: 0x875000, dark: 0xF8C96A),
        wash: Theme.dyn(light: 0xFBEFD9, dark: 0x33260B), on: Theme.dyn(light: white, dark: ink))
    private static let greenPalette = Palette(
        base: Theme.dyn(light: 0x15803F, dark: 0x34C172), deep: Theme.dyn(light: 0x0F6732, dark: 0x6ED79A),
        wash: Theme.dyn(light: 0xDDF3E6, dark: 0x0F2A1B), on: Theme.dyn(light: white, dark: ink))
    private static let plumPalette = Palette(
        base: Theme.dyn(light: 0x6F539A, dark: 0xA98FCB), deep: Theme.dyn(light: 0x5A4380, dark: 0xC3AEDF),
        wash: Theme.dyn(light: 0xECE6F4, dark: 0x221A30), on: Theme.dyn(light: white, dark: white))
}

/// The gradient behind every page, mixed from the logo's feathers.
enum TalkieBackdropStyle: String, CaseIterable, Identifiable, Sendable {
    /// All four logo colours: gold, red, blue, green.
    case macaw
    /// The warm half: red into gold.
    case ember
    /// The cool half: green into blue.
    case lagoon
    /// Plum into blue.
    case dusk
    /// No gradient: the plain canvas.
    case plain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macaw:  return "Macaw".loc
        case .ember:  return "Ember".loc
        case .lagoon: return "Lagoon".loc
        case .dusk:   return "Dusk".loc
        case .plain:  return "Plain".loc
        }
    }

    /// The gradient's colours in order along its direction (the logo's own values).
    /// Macaw runs gold → red → blue → green, so every blend between neighbours is a
    /// clean hue (orange, violet, teal) — gold next to green goes olive when dimmed.
    var colors: [Color] {
        switch self {
        case .macaw:  return [Self.gold, Self.red, Self.blue, Self.green]
        case .ember:  return [Self.red, Self.gold]
        case .lagoon: return [Self.green, Self.blue]
        case .dusk:   return [Self.plum, Self.blue]
        case .plain:  return []
        }
    }

    /// The colours charts, gauges and progress fills use over this backdrop — the
    /// same feathers, in the same order, in their light/dark data values — so the
    /// graphs read as part of the page behind them. Plain keeps the warm classic.
    var dataColors: [Color] {
        switch self {
        case .macaw:  return [Theme.featherGold, Theme.featherRed, Theme.featherBlue, Theme.featherGreen]
        case .ember:  return [Theme.featherGold, Theme.featherRed]
        case .lagoon: return [Theme.featherGreen, Theme.featherBlue]
        case .dusk:   return [Theme.featherPlum, Theme.featherBlue]
        case .plain:  return [Theme.featherGold, Theme.featherRed]
        }
    }

    /// The accent that sits best on this backdrop; choosing a backdrop in Settings
    /// also sets it (the accent can still be changed afterwards).
    var accent: TalkieAccent {
        switch self {
        case .macaw, .plain: return .blue
        case .ember:  return .red
        case .lagoon: return .green
        case .dusk:   return .plum
        }
    }

    // Sampled from `TalkieLogo.png`.
    static let red   = Color(nsColor: NSColor(hex: 0xF2403F))
    static let gold  = Color(nsColor: NSColor(hex: 0xF5A623))
    static let green = Color(nsColor: NSColor(hex: 0x12A865))
    static let blue  = Color(nsColor: NSColor(hex: 0x2B8DE3))
    static let plum  = Color(nsColor: NSColor(hex: 0x8A6FB0))
}

/// How see-through cards are.
enum TalkieGlassStyle: String, CaseIterable, Identifiable, Sendable {
    /// Liquid Glass with little frosting: the backdrop shows through clearly.
    case clear
    /// Liquid Glass, frosted (the default).
    case frosted
    /// Opaque cards: no glass. Also what Reduce Transparency gives.
    case solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clear:   return "Clear (glass)".loc
        case .frosted: return "Frosted".loc
        case .solid:   return "Solid".loc
        }
    }
}

/// Everything the appearance settings decide, as one value.
struct TalkieLook: Equatable, Sendable {
    var mode: TalkieAppearanceMode = .system
    var accent: TalkieAccent = .blue
    var backdrop: TalkieBackdropStyle = .macaw
    /// 0 (a whisper) … 1 (vivid).
    var intensity: Double = 0.5
    /// Direction the gradient runs in, degrees clockwise from "left to right".
    var angle: Double = 135
    /// Each page turns the gradient a step further, so pages are told apart.
    var variesByPage = true
    var glass: TalkieGlassStyle = .frosted

    /// Changes whenever a colour token changes value (accent or backdrop): page
    /// content re-identifies on it, because tokens are plain reads.
    var paintKey: String { "\(accent.rawValue)-\(backdrop.rawValue)" }
}

/// The token side of the look: what `Theme.brand` and friends read. Kept outside
/// the main-actor store so colour tokens stay plain static reads from anywhere.
enum ThemeState {
    nonisolated(unsafe) static var accent: TalkieAccent = .blue
    nonisolated(unsafe) static var backdrop: TalkieBackdropStyle = .macaw
    /// True when small raised fills must be opaque: Solid cards, or no gradient
    /// behind them (a frosted white tile would vanish on the plain white canvas).
    nonisolated(unsafe) static var flatSurfaces = false

    static func adopt(_ look: TalkieLook) {
        accent = look.accent
        backdrop = look.backdrop
        flatSurfaces = look.glass == .solid || look.backdrop == .plain
    }
}

/// The user's appearance choices, persisted in `UserDefaults`.
@MainActor
final class AppearanceStore: ObservableObject {
    static let shared = AppearanceStore()

    @Published private(set) var look: TalkieLook

    private let defaults: UserDefaults

    private enum Keys {
        static let mode = "appearanceMode"
        static let accent = "appearanceAccent"
        static let backdrop = "appearanceBackdrop"
        static let intensity = "appearanceBackdropIntensity"
        static let angle = "appearanceBackdropAngle"
        static let variesByPage = "appearanceBackdropVariesByPage"
        static let glass = "appearanceGlass"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var l = TalkieLook()
        if let v = defaults.string(forKey: Keys.mode).flatMap(TalkieAppearanceMode.init) { l.mode = v }
        if let v = defaults.string(forKey: Keys.accent).flatMap(TalkieAccent.init) { l.accent = v }
        if let v = defaults.string(forKey: Keys.backdrop).flatMap(TalkieBackdropStyle.init) { l.backdrop = v }
        if defaults.object(forKey: Keys.intensity) != nil { l.intensity = Self.clamp01(defaults.double(forKey: Keys.intensity)) }
        if defaults.object(forKey: Keys.angle) != nil { l.angle = Self.normalizedAngle(defaults.double(forKey: Keys.angle)) }
        if defaults.object(forKey: Keys.variesByPage) != nil { l.variesByPage = defaults.bool(forKey: Keys.variesByPage) }
        if let v = defaults.string(forKey: Keys.glass).flatMap(TalkieGlassStyle.init) { l.glass = v }
        look = l
        ThemeState.adopt(l)
    }

    /// Change the look; persists it and applies the light/dark choice to the app.
    func update(_ change: (inout TalkieLook) -> Void) {
        var next = look
        change(&next)
        next.intensity = Self.clamp01(next.intensity)
        next.angle = Self.normalizedAngle(next.angle)
        guard next != look else { return }
        let modeChanged = next.mode != look.mode
        ThemeState.adopt(next)
        look = next
        defaults.set(next.mode.rawValue, forKey: Keys.mode)
        defaults.set(next.accent.rawValue, forKey: Keys.accent)
        defaults.set(next.backdrop.rawValue, forKey: Keys.backdrop)
        defaults.set(next.intensity, forKey: Keys.intensity)
        defaults.set(next.angle, forKey: Keys.angle)
        defaults.set(next.variesByPage, forKey: Keys.variesByPage)
        defaults.set(next.glass.rawValue, forKey: Keys.glass)
        if modeChanged { applyMode() }
    }

    /// Back to the look Talkie ships with.
    func reset() { update { $0 = TalkieLook() } }

    /// Push the light/dark choice to AppKit (every window follows `NSApp.appearance`).
    func applyMode() {
        NSApp?.appearance = look.mode.nsAppearance
    }

    nonisolated static func clamp01(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0.5 }

    /// Any angle folded into 0 ..< 360.
    nonisolated static func normalizedAngle(_ v: Double) -> Double {
        guard v.isFinite else { return 135 }
        let r = v.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}

// MARK: - Backdrop

private struct TalkieBackdropTurnKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// Which step of the per-page rotation this page is on (0 = the set angle).
    var talkieBackdropTurn: Int {
        get { self[TalkieBackdropTurnKey.self] }
        set { self[TalkieBackdropTurnKey.self] = newValue }
    }
}

/// The geometry of the backdrop gradient. Pure, so the angles are unit-tested.
enum TalkieBackdropGeometry {
    /// Degrees each page turns the gradient further.
    static let turnStep: Double = 40

    /// The direction for a page: the set angle, plus one step per page when pages vary.
    static func angle(base: Double, turn: Int, variesByPage: Bool) -> Double {
        AppearanceStore.normalizedAngle(base + (variesByPage ? Double(turn) * turnStep : 0))
    }

    /// Start and end of a gradient that crosses the whole unit square in `degrees`
    /// (0 = left to right, 90 = top to bottom), running corner to corner on the
    /// diagonals so every colour is on screen at any angle.
    static func points(degrees: Double) -> (start: UnitPoint, end: UnitPoint) {
        let r = degrees * .pi / 180
        let dx = cos(r), dy = sin(r)
        // Half the square's extent along the direction.
        let half = (abs(dx) + abs(dy)) / 2
        return (UnitPoint(x: 0.5 - dx * half, y: 0.5 - dy * half),
                UnitPoint(x: 0.5 + dx * half, y: 0.5 + dy * half))
    }

    /// How much of the gradient shows through the canvas, for an intensity 0…1.
    static func opacity(intensity: Double, dark: Bool) -> Double {
        let t = AppearanceStore.clamp01(intensity)
        return dark ? 0.10 + 0.40 * t : 0.08 + 0.38 * t
    }
}

/// The page backdrop: the logo-colour gradient over the canvas, running in one
/// direction. Still by design — nothing animates while a page is at rest.
struct TalkieBackdrop: View {
    /// Overrides the environment's page turn (the main window passes its tab's).
    var turn: Int? = nil

    @ObservedObject private var appearance = AppearanceStore.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.talkieBackdropTurn) private var environmentTurn

    var body: some View {
        let look = appearance.look
        let dark = scheme == .dark
        ZStack {
            Theme.canvas
            if look.backdrop != .plain {
                let degrees = TalkieBackdropGeometry.angle(base: look.angle, turn: turn ?? environmentTurn,
                                                           variesByPage: look.variesByPage)
                let points = TalkieBackdropGeometry.points(degrees: degrees)
                Rectangle()
                    .fill(.linearGradient(Gradient(colors: look.backdrop.colors).colorSpace(.perceptual),
                                          startPoint: points.start, endPoint: points.end))
                    .opacity(TalkieBackdropGeometry.opacity(intensity: look.intensity, dark: dark))
                // A soft lift from the gradient's start corner, so it reads as light
                // falling across the page rather than a flat wash.
                RadialGradient(colors: [(dark ? Color.white.opacity(0.07) : Color.white.opacity(0.55)), .clear],
                               center: points.start, startRadius: 0, endRadius: 700)
                    .blendMode(dark ? .plusLighter : .normal)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// MARK: - Glass surface

/// The card surface: Liquid Glass over the backdrop, or an opaque card when the
/// user chose Solid or the Mac has Reduce Transparency on.
struct TalkieGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.card

    @ObservedObject private var appearance = AppearanceStore.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || appearance.look.glass == .solid {
            // Shadows on the shape, not the composited card (see `talkieSurface`).
            content
                .clipShape(shape)
                .background(
                    shape.fill(Theme.surfaceSolid)
                        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
                        .shadow(color: .black.opacity(0.07), radius: 20, x: 0, y: 10)
                )
        } else {
            content
                .clipShape(shape)
                .glassEffect(appearance.look.glass == .clear ? .clear : .regular, in: shape)
        }
    }
}

// MARK: - Scroll edge effect

/// The system's own scroll edge effect (the soft blur content runs into under a
/// bar, as on iOS 26), for a scroll view that has no real bar. SwiftUI draws the
/// effect for content passing under a `safeAreaBar`; this adds an empty bar at the
/// top and the bottom and asks for the soft style. The bars take `top` / `bottom`
/// points of the scroll view's safe area: content rests below/above them and blurs
/// as it scrolls under them — so callers trim their own edge padding by as much.
///
/// The bar must hold real content: with a bare `Color.clear` the system draws no
/// effect (macOS 26.5), hence the blank text.
private struct TalkieScrollEdgeEffect: ViewModifier {
    let top: CGFloat
    let bottom: CGFloat

    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectStyle(.soft, for: .all)
            .safeAreaBar(edge: .top, spacing: 0) { bar(top) }
            .safeAreaBar(edge: .bottom, spacing: 0) { bar(bottom) }
    }

    private func bar(_ height: CGFloat) -> some View {
        Text(verbatim: " ")
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Gives a scroll view the system's soft scroll edge effect at its top and
    /// bottom (apply it to the `ScrollView` itself). `top` and `bottom` are the
    /// heights of the edge zones; they inset the content, see `TalkieScrollEdgeEffect`.
    func talkieScrollEdgeFades(top: CGFloat = Theme.Space.edgeBar, bottom: CGFloat = Theme.Space.edgeBar) -> some View {
        modifier(TalkieScrollEdgeEffect(top: top, bottom: bottom))
    }
}

// MARK: - Window drag area

/// A region that moves its window when dragged — and nothing else does. Windows
/// are not "movable by their background" (that steals drags from sliders and text
/// on glass); a window that wants more than its titlebar to grab puts this behind
/// its content. Controls and text in front of it keep their own drags.
struct TalkieWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override func accessibilityRole() -> NSAccessibility.Role? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}

// MARK: - Glass card (reusable frosted panel)

/// A frosted panel for content that floats over the backdrop — the onboarding
/// step card. The material truly samples the gradient behind it. Honors Reduce
/// Transparency (solid fill) and adapts its specular edge to the appearance.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 30
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(fill, in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(scheme == .dark ? 0.30 : 0.70),
                                 .white.opacity(0.05),
                                 .clear],
                        startPoint: .topLeading, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .clipShape(shape)
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.16), radius: 44, x: 0, y: 26)
    }

    private var fill: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(scheme == .dark ? Color(nsColor: NSColor(hex: 0x111114))
                                                 : Color(nsColor: NSColor(hex: 0xFFFFFF)))
        }
        return AnyShapeStyle(.regularMaterial)
    }
}
