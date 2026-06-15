import SwiftUI
import AppKit
import Combine

// MARK: - LiveBackground
//
// A calm, dark backdrop: a single-direction gradient wallpaper (generated art,
// bundled as Brand/Backdrop.png) with a *barely-there* drift — a very slow
// parallax + scale breath so it feels alive without ever being busy.
//
// • Dark mode only renders the wallpaper; Light mode falls back to the clean
//   canvas (the art is a dark gradient and would fight dark ink in Light).
// • Honors Reduce Motion (freezes to a still frame) and pauses when Talkie isn't
//   the active app, so an idle dashboard costs ~nothing.

struct LiveBackground: View {
    enum Mood {
        /// Behind the dashboard — a touch more scrim so the content cards lead.
        case ambient
        /// Full-screen onboarding — a hair less scrim so the glow reads.
        case hero
    }

    var mood: Mood = .ambient

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Pause the drift when Talkie isn't frontmost.
    @State private var active = true

    var body: some View {
        ZStack {
            if scheme == .dark {
                Color(nsColor: NSColor(hex: 0x030304))               // true-black floor
                Backdrop(animate: !reduceMotion && active)
                // A gentle, even scrim keeps the whole thing subtle and lifts
                // whatever floats on top.
                Color.black.opacity(mood == .ambient ? 0.16 : 0.06)
                    .allowsHitTesting(false)
                // A few slow, warm glows drifting low over the ember — the bit of
                // life, kept to the lower half so the dark top stays clean.
                DriftingGlow(animate: !reduceMotion && active)
            } else {
                Theme.canvas
            }
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
}

// MARK: - Backdrop (image + barely-there drift)

private struct Backdrop: View {
    /// When false (Reduce Motion, or app inactive) the image holds a still frame.
    let animate: Bool

    var body: some View {
        GeometryReader { geo in
            if let img = Brand.image("Backdrop") {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate)) { ctx in
                    let t = animate ? ctx.date.timeIntervalSinceReferenceDate : 0
                    picture(img, size: geo.size, t: t)
                }
            } else {
                // Un-assembled debug run (no bundle resources): an approximate
                // ember so the layout still reads.
                FallbackGradient()
            }
        }
    }

    private func picture(_ img: NSImage, size: CGSize, t: TimeInterval) -> some View {
        // Barely-there: ~±12px parallax over a ~100s cycle, plus a 1.5% scale
        // breath. Base overscale 1.10 keeps the drift from ever revealing an edge.
        let dx = CGFloat(sin(t * 0.060)) * 12
        let dy = CGFloat(cos(t * 0.045)) * 8
        let scale = 1.10 + 0.015 * CGFloat(sin(t * 0.030))
        return Image(nsImage: img)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale, anchor: .bottom)   // keep the ember anchored low
            .offset(x: dx, y: dy)
            .clipped()
    }
}

// MARK: - Drifting glow (the bit of life)

/// A few large, very soft warm glows that drift along slow Lissajous paths and
/// add light over the ember wallpaper. Deliberately restrained — warm tones only
/// (no rainbow), low opacity, parked in the lower half so the top stays calm.
/// Freezes to a still frame under Reduce Motion / when the app is inactive.
private struct DriftingGlow: View {
    let animate: Bool

    private struct Spec {
        let color: Color
        let cx: CGFloat, cy: CGFloat   // home (fraction of w/h)
        let ax: CGFloat, ay: CGFloat   // drift amplitude (fraction)
        let dia: CGFloat               // diameter (fraction of min(w,h))
        let f: Double, p: Double       // drift frequency + phase
        let opacity: Double
    }

    private let specs: [Spec] = [
        .init(color: Theme.featherCoral, cx: 0.30, cy: 0.86, ax: 0.07, ay: 0.04, dia: 1.05, f: 0.050, p: 0.0, opacity: 0.20),
        .init(color: Theme.featherGold,  cx: 0.74, cy: 0.92, ax: 0.06, ay: 0.04, dia: 0.95, f: 0.045, p: 2.2, opacity: 0.14),
        .init(color: Theme.featherCoral, cx: 0.55, cy: 0.78, ax: 0.05, ay: 0.05, dia: 0.80, f: 0.060, p: 4.0, opacity: 0.12),
    ]

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate)) { ctx in
                let t = animate ? ctx.date.timeIntervalSinceReferenceDate : 0
                let w = geo.size.width, h = geo.size.height
                let base = min(w, h)
                ZStack {
                    ForEach(Array(specs.enumerated()), id: \.offset) { _, s in
                        let d = base * s.dia
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [s.color.opacity(s.opacity), s.color.opacity(0)],
                                    center: .center, startRadius: 0, endRadius: d / 2
                                )
                            )
                            .frame(width: d, height: d)
                            .blur(radius: d * 0.16)
                            .position(
                                x: w * s.cx + w * s.ax * CGFloat(sin(t * s.f + s.p)),
                                y: h * s.cy + h * s.ay * CGFloat(cos(t * s.f * 1.1 + s.p))
                            )
                    }
                }
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
        }
    }
}

/// Procedural stand-in for the bundled wallpaper when it isn't on disk.
private struct FallbackGradient: View {
    var body: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [Color(nsColor: NSColor(hex: 0x3A1410)).opacity(0.9), .clear],
                center: UnitPoint(x: 0.5, y: 1.05),
                startRadius: 0, endRadius: 620
            )
        }
    }
}

// MARK: - Glass card (reusable frosted panel)

/// A frosted panel for content that floats over the backdrop — the onboarding
/// step card. The material truly samples the wallpaper behind it. Honors Reduce
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
