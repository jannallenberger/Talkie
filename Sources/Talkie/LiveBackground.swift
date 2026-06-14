import SwiftUI
import AppKit
import Combine

// MARK: - LiveBackground
//
// A living "aurora glass" backdrop — a slowly flowing mesh of the macaw feather
// hues bloomed over true black, with frosted-glass shapes drifting above it.
//
// Why procedural (no bitmap): it scales to any window size, adapts to light/dark
// for free, and ships nothing to decode. It is deliberately a *dark* wallpaper —
// the blooms stay low in luminance so dashboard cards and onboarding text always
// read on top. A soft light variant keeps it usable in Light mode too.
//
// Good citizen: honors Reduce Motion (renders a single still frame), and pauses
// itself when the app isn't frontmost, so an idle dashboard costs ~nothing.

struct LiveBackground: View {
    enum Mood {
        /// Calm ambient wash behind the dashboard — a heavier vignette so the
        /// content cards stay the hero.
        case ambient
        /// A touch more open + vivid for the full-screen onboarding.
        case hero
    }

    var mood: Mood = .ambient

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Reduce Transparency drops the frosted-glass materials for solid fills —
    /// the system signal from users who find translucency hard to parse.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Pause the animation when Talkie isn't the active app — a still dashboard
    /// in the background shouldn't spin the GPU.
    @State private var active = true

    /// Frame budget: the motion is slow, so 30 fps is buttery and halves the
    /// compositing cost versus running at the display's full refresh.
    private var minInterval: Double { mood == .hero ? 1.0 / 60.0 : 1.0 / 30.0 }

    var body: some View {
        ZStack {
            baseFill
            if reduceMotion {
                // A single, pleasant still frame — no timeline, no motion.
                layers(at: 12.0)
            } else {
                TimelineView(.animation(minimumInterval: minInterval, paused: !active)) { ctx in
                    layers(at: ctx.date.timeIntervalSinceReferenceDate)
                }
            }
            FilmGrain(scheme: scheme)
            Vignette(scheme: scheme, mood: mood)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            active = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            active = true
        }
    }

    /// The opaque floor: true black in dark, near-white in light, so whatever the
    /// blooms don't reach is never transparent.
    private var baseFill: Color {
        scheme == .dark ? Color(nsColor: NSColor(hex: 0x040406))
                        : Color(nsColor: NSColor(hex: 0xFBFBFD))
    }

    @ViewBuilder
    private func layers(at time: TimeInterval) -> some View {
        AuroraMesh(time: time, scheme: scheme)
        ColorBlooms(time: time, scheme: scheme)
        GlassDrift(time: time, scheme: scheme, solid: reduceTransparency)
    }
}

// MARK: - Aurora mesh

/// The flowing gradient floor: a 3×3 `MeshGradient` whose interior control points
/// wobble on slow sinusoids while the bloom hues drift across the feather palette.
/// Corners are pinned so the mesh always fills to the edges (no transparent gaps).
private struct AuroraMesh: View {
    let time: TimeInterval
    let scheme: ColorScheme

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: points(time),
            colors: colors(time),
            smoothsColors: true
        )
        // A whisper of blur melts any residual facet edges into pure gradient.
        .blur(radius: 0.5)
    }

    private func points(_ t0: TimeInterval) -> [SIMD2<Float>] {
        let t = Float(t0)
        func wob(_ x: Float, _ y: Float, _ ax: Float, _ ay: Float, _ f: Float, _ p: Float) -> SIMD2<Float> {
            SIMD2(x + ax * sin(t * f + p), y + ay * cos(t * f * 0.9 + p))
        }
        return [
            SIMD2(0, 0),
            wob(0.5, 0.0, 0.10, 0.06, 0.27, 1.3),
            SIMD2(1, 0),
            wob(0.0, 0.5, 0.06, 0.10, 0.23, 2.1),
            wob(0.5, 0.5, 0.15, 0.13, 0.31, 0.0),
            wob(1.0, 0.5, 0.06, 0.10, 0.25, 4.2),
            SIMD2(0, 1),
            wob(0.5, 1.0, 0.10, 0.06, 0.29, 3.1),
            SIMD2(1, 1),
        ]
    }

    private func colors(_ t: TimeInterval) -> [Color] {
        if scheme == .dark {
            return [
                ink(0.62, 0.50, 0.05),                    // cool near-black
                bloom(t, hue: 0.58, phase: 0.0),          // top — blue
                ink(0.74, 0.45, 0.06),                    // plum near-black
                bloom(t, hue: 0.74, phase: 1.7),          // left — plum
                bloom(t, hue: nil,  phase: 0.0),          // center — drifts green↔blue↔plum
                bloom(t, hue: 0.40, phase: 3.0),          // right — green
                ink(0.99, 0.50, 0.06),                    // red near-black
                bloom(t, hue: 0.07, phase: 4.5),          // bottom — gold
                ink(0.55, 0.40, 0.05),                    // cool near-black
            ]
        } else {
            // Light: a barely-there pastel wash on near-white.
            return [
                ink(0.62, 0.06, 0.99),
                wash(t, hue: 0.58, phase: 0.0),
                ink(0.74, 0.05, 0.99),
                wash(t, hue: 0.74, phase: 1.7),
                wash(t, hue: nil,  phase: 0.0),
                wash(t, hue: 0.40, phase: 3.0),
                ink(0.99, 0.06, 0.99),
                wash(t, hue: 0.07, phase: 4.5),
                ink(0.55, 0.05, 0.99),
            ]
        }
    }

    private func ink(_ h: Double, _ s: Double, _ b: Double) -> Color {
        Color(hue: h, saturation: s, brightness: b)
    }

    /// A deep, breathing feather bloom for Dark mode.
    private func bloom(_ t: TimeInterval, hue: Double?, phase: Double) -> Color {
        // A nil hue drifts slowly across the cool half of the macaw spread
        // (green → blue → plum); the warm reds/golds live in the fixed corners.
        let h = hue ?? (0.55 + 0.22 * sin(t * 0.045 + phase))
        let b = 0.17 + 0.06 * sin(t * 0.11 + phase * 1.3)
        return Color(hue: wrap(h), saturation: 0.72, brightness: b)
    }

    /// A pale feather tint for Light mode — high brightness, low saturation.
    private func wash(_ t: TimeInterval, hue: Double?, phase: Double) -> Color {
        let h = hue ?? (0.55 + 0.22 * sin(t * 0.045 + phase))
        let b = 0.965 + 0.02 * sin(t * 0.11 + phase)
        return Color(hue: wrap(h), saturation: 0.15, brightness: min(1, b))
    }

    private func wrap(_ h: Double) -> Double { h - floor(h) }
}

// MARK: - Color blooms (soft drifting glows)

/// A handful of big, soft radial glows that drift along slow Lissajous paths and
/// add light over the mesh — the "gradient blobs" that give the wall its depth.
private struct ColorBlooms: View {
    let time: TimeInterval
    let scheme: ColorScheme

    private struct Spec {
        let color: Color
        let cx: CGFloat, cy: CGFloat   // home position (fraction of w/h)
        let ax: CGFloat, ay: CGFloat   // drift amplitude (fraction)
        let dia: CGFloat               // diameter (fraction of min(w,h))
        let f: Double, p: Double       // drift frequency + phase
    }

    private let specs: [Spec] = [
        .init(color: Theme.featherBlue,  cx: 0.22, cy: 0.30, ax: 0.06, ay: 0.05, dia: 1.05, f: 0.16, p: 0.0),
        .init(color: Theme.featherPlum,  cx: 0.82, cy: 0.20, ax: 0.05, ay: 0.07, dia: 0.95, f: 0.13, p: 2.0),
        .init(color: Theme.featherCoral, cx: 0.74, cy: 0.84, ax: 0.06, ay: 0.05, dia: 0.85, f: 0.15, p: 4.0),
        .init(color: Theme.featherGreen, cx: 0.16, cy: 0.88, ax: 0.05, ay: 0.05, dia: 0.85, f: 0.12, p: 5.5),
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let base = min(w, h)
            ZStack {
                ForEach(Array(specs.enumerated()), id: \.offset) { _, s in
                    let t = time
                    let d = base * s.dia
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [s.color.opacity(scheme == .dark ? 0.55 : 0.20),
                                         s.color.opacity(0)],
                                center: .center, startRadius: 0, endRadius: d / 2
                            )
                        )
                        .frame(width: d, height: d)
                        .blur(radius: d * 0.10)
                        .position(
                            x: w * s.cx + w * s.ax * CGFloat(sin(t * s.f + s.p)),
                            y: h * s.cy + h * s.ay * CGFloat(cos(t * s.f * 1.1 + s.p))
                        )
                }
            }
            // Add light on dark (aurora glow); gently tint on white.
            .blendMode(scheme == .dark ? .plusLighter : .normal)
        }
    }
}

// MARK: - Glass drift (the frosted shapes)

/// The literal "glass shapes": a few large frosted panels that drift and rotate
/// almost imperceptibly above the aurora, parked toward the edges so the centre
/// stays calm for content. `.ultraThinMaterial` truly samples the mesh behind
/// them, so they frost the colour rather than faking it.
private struct GlassDrift: View {
    let time: TimeInterval
    let scheme: ColorScheme
    /// When Reduce Transparency is on, panes fill solid instead of frosting.
    var solid: Bool = false

    private struct Pane {
        let w: CGFloat, h: CGFloat, corner: CGFloat
        let cx: CGFloat, cy: CGFloat
        let drift: CGFloat, rot: Double
        let f: Double, p: Double
        let tint: Color
    }

    private var panes: [Pane] {
        [
            .init(w: 260, h: 320, corner: 64, cx: 0.88, cy: 0.26, drift: 26, rot: 14, f: 0.05, p: 0.0, tint: Theme.featherBlue),
            .init(w: 200, h: 200, corner: 92, cx: 0.12, cy: 0.70, drift: 22, rot: -20, f: 0.045, p: 2.4, tint: Theme.featherPlum),
            .init(w: 150, h: 190, corner: 48, cx: 0.30, cy: 0.16, drift: 18, rot: 24, f: 0.06, p: 4.1, tint: Theme.featherGold),
        ]
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                ForEach(Array(panes.enumerated()), id: \.offset) { _, pane in
                    let t = time
                    GlassShape(width: pane.w, height: pane.h, corner: pane.corner,
                               tint: pane.tint, scheme: scheme, solid: solid)
                        .rotationEffect(.degrees(pane.rot * sin(t * pane.f + pane.p)))
                        .position(
                            x: w * pane.cx + pane.drift * CGFloat(sin(t * pane.f + pane.p)),
                            y: h * pane.cy + pane.drift * CGFloat(cos(t * pane.f * 0.8 + pane.p))
                        )
                }
            }
        }
    }
}

/// One smoky-glass panel: a frosted material fill, a faint feather tint, a bright
/// top-left specular edge, and a soft drop shadow — the recipe that reads as
/// glass rather than a flat card.
private struct GlassShape: View {
    let width: CGFloat
    let height: CGFloat
    let corner: CGFloat
    var tint: Color = .white
    let scheme: ColorScheme
    var solid: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        shape
            .fill(glassFill)
            .overlay(shape.fill(tint.opacity(scheme == .dark ? 0.10 : 0.06)))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(scheme == .dark ? 0.38 : 0.55),
                                 .white.opacity(0.04),
                                 .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.10), radius: 30, x: 0, y: 18)
    }

    /// Frosted material, or a near-opaque solid when Reduce Transparency is set.
    private var glassFill: AnyShapeStyle {
        if solid {
            return AnyShapeStyle(
                (scheme == .dark ? Color(nsColor: NSColor(hex: 0x141418))
                                 : Color(nsColor: NSColor(hex: 0xF1F2F6))).opacity(0.94)
            )
        }
        return AnyShapeStyle(.ultraThinMaterial)
    }
}

// MARK: - Film grain (static, anti-banding)

/// A faint, fixed stipple of light specks. Near-black gradients band badly on
/// most displays; a touch of grain dithers them smooth and adds a filmic depth.
/// Drawn once (no time input) so it never flickers and costs nothing per frame.
private struct FilmGrain: View {
    let scheme: ColorScheme

    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRNG(seed: 0x5EED_1234)
            let count = Int(size.width * size.height / 1100)
            var bright = Path(), dim = Path()
            for i in 0..<count {
                let x = CGFloat(rng.nextUnit()) * size.width
                let y = CGFloat(rng.nextUnit()) * size.height
                let r = CGRect(x: x, y: y, width: 1, height: 1)
                if i & 3 == 0 { bright.addRect(r) } else { dim.addRect(r) }
            }
            ctx.fill(bright, with: .color(.white.opacity(0.05)))
            ctx.fill(dim, with: .color(.white.opacity(0.025)))
        }
        .blendMode(.overlay)
        .opacity(scheme == .dark ? 0.7 : 0.35)
        .allowsHitTesting(false)
    }
}

// MARK: - Vignette

/// A soft radial darkening toward the corners that focuses the eye on the centre
/// and lifts whatever floats on top. Sized to the view so it covers any window.
private struct Vignette: View {
    let scheme: ColorScheme
    let mood: LiveBackground.Mood

    var body: some View {
        GeometryReader { geo in
            let reach = max(geo.size.width, geo.size.height) * 0.78
            let edge: Color = scheme == .dark
                ? .black.opacity(mood == .ambient ? 0.55 : 0.42)
                : Color(nsColor: NSColor(hex: 0x0B1A2E)).opacity(0.05)
            RadialGradient(
                colors: [.clear, edge],
                center: .center,
                startRadius: reach * 0.18,
                endRadius: reach
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Glass card (reusable frosted panel)

/// A frosted panel for content that floats over the live background — the
/// onboarding step card, say. The material truly samples the aurora behind it.
/// Honors Reduce Transparency (solid fill) and adapts its specular edge to the
/// appearance.
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

// MARK: - Seeded RNG (deterministic grain)

/// A tiny xorshift so the grain is identical every render (no per-frame churn).
private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed != 0 ? seed : 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
}
