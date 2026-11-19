import SwiftUI
import AppKit
import QuartzCore
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
// • The drift is Core Animation (see `DriftLayerView`): no per-frame SwiftUI work.

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
    /// Pause the drift when Talkie isn't frontmost. Seeded from the app's real state:
    /// a fixed `true` meant a window that appeared while Talkie was in the background
    /// (launch at login, the relaunch after an update) drifted on — at ~6 % CPU —
    /// until the first activate/resign round trip.
    @State private var active = NSApplication.shared.isActive
    /// Pause the drift when the hosting window is occluded (covered by another
    /// window, minimized, or on another Space) — catches the case app-active/
    /// inactive alone misses: Talkie can stay the frontmost app while this
    /// particular window sits hidden behind something else.
    @State private var occluded = false
    /// The hosting `NSWindow`, captured by the probe below, so the occlusion
    /// notification can recompute `occluded` from its live `occlusionState`.
    @State private var hostWindow: NSWindow?

    /// Whichever of the two "not worth animating" conditions applies, freeze to
    /// a still frame — Reduce Motion, app inactive, or window occluded.
    private var animating: Bool { !reduceMotion && active && !occluded }

    var body: some View {
        ZStack {
            if scheme == .dark {
                Color(nsColor: NSColor(hex: 0x030304))               // true-black floor
                Backdrop(animate: animating)
                // A gentle, even scrim keeps the whole thing subtle and lifts
                // whatever floats on top.
                Color.black.opacity(mood == .ambient ? 0.16 : 0.06)
                    .allowsHitTesting(false)
                // A few slow, warm glows drifting low over the ember — the bit of
                // life, kept to the lower half so the dark top stays clean.
                DriftingGlow(animate: animating)
            } else {
                Theme.canvas
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .background(WindowOcclusionReader { window in
            hostWindow = window
            occluded = !(window?.occlusionState.contains(.visible) ?? true)
        })
        // The occlusion notification fires on the main run loop; `.onReceive`'s
        // closure is main-actor, so reading `occlusionState` here is safe (no
        // manual observer capturing a non-Sendable window in a @Sendable block).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            occluded = !(hostWindow?.occlusionState.contains(.visible) ?? true)
        }
        .onAppear { active = NSApplication.shared.isActive }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            active = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            active = true
        }
    }
}

// MARK: - Window occlusion reader

/// An otherwise-inert `NSView` whose only job is reporting when AppKit attaches
/// or detaches it from a real `NSWindow` — `viewDidMoveToWindow` is the correct
/// AppKit hook for this (fires on insertion AND any later reparenting), unlike
/// reading `.window` once at construction time (still nil then: the view isn't
/// in the hierarchy yet).
private final class OcclusionProbeView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

/// Bridges to the hosting `NSWindow` so `LiveBackground` can pause its drift when
/// that window isn't actually visible on screen. There's no SwiftUI-native way to
/// read occlusion state, so this is the standard trick: an invisible probe view
/// hands its `.window` up to the SwiftUI layer, which watches
/// `NSWindow.didChangeOcclusionStateNotification` via `.onReceive`. Zero footprint —
/// it draws nothing and doesn't affect layout (used via `.background(...)`).
private struct WindowOcclusionReader: NSViewRepresentable {
    /// Called (on the main thread, from `viewDidMoveToWindow`) whenever the probe
    /// is attached to or moved between windows.
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> OcclusionProbeView {
        let view = OcclusionProbeView(frame: .zero)
        view.onWindowChange = onWindow
        return view
    }

    func updateNSView(_ nsView: OcclusionProbeView, context: Context) {
        nsView.onWindowChange = onWindow
    }
}

// MARK: - Backdrop (image + barely-there drift)
//
// Perf: the drift (image parallax + scale breath, and the three glows) runs on Core
// Animation layers — sampled sine keyframes, repeating — so it costs the main thread
// nothing per frame. It used to be two `TimelineView`s at 12 fps, and every tick made
// SwiftUI lay out and re-diff the WHOLE dashboard under it: ~14 % CPU whenever the
// dashboard was frontmost, competing with every scroll and hover. The motion
// functions are unchanged (same amplitudes, frequencies, phases).

private struct Backdrop: View {
    /// When false (Reduce Motion, app inactive, window occluded) the drift holds still.
    let animate: Bool

    var body: some View {
        if let img = Brand.image("Backdrop") {
            BackdropDrift(image: img, animate: animate)
        } else {
            // Un-assembled debug run (no bundle resources): an approximate
            // ember so the layout still reads.
            FallbackGradient()
        }
    }
}

private struct BackdropDrift: NSViewRepresentable {
    let image: NSImage
    let animate: Bool

    func makeNSView(context: Context) -> BackdropDriftView { BackdropDriftView(image: image) }
    func updateNSView(_ view: BackdropDriftView, context: Context) { view.setAnimating(animate) }
}

/// A layer-hosting view whose drift is a set of Core Animation animations on one
/// container layer; pausing freezes that container's clock (no jump on resume).
class DriftLayerView: NSView {
    let container = CALayer()
    private var paused = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        // Native Core Animation coordinates (y grows UP); the SwiftUI motion
        // functions below are converted (y → height − y) where they are built.
        layer?.addSublayer(container)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    private var builtSize: CGSize = .zero
    private func rebuild() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        if bounds.size != builtSize {
            builtSize = bounds.size
            build(in: bounds.size, scale: window?.backingScaleFactor ?? 2)
        }
        CATransaction.commit()
    }

    /// Lay out sublayers for `size` and (re)add their animations.
    func build(in size: CGSize, scale: CGFloat) {}

    /// Freeze or resume the whole drift where it is.
    func setAnimating(_ on: Bool) {
        if on, paused {
            let pausedAt = container.timeOffset
            container.speed = 1
            container.timeOffset = 0
            container.beginTime = 0
            container.beginTime = container.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
            paused = false
        } else if !on, !paused {
            let now = container.convertTime(CACurrentMediaTime(), from: nil)
            container.speed = 0
            container.timeOffset = now
            paused = true
        }
    }

    /// `base + amp·sin(freq·t + phase)` (or cos) as a repeating keyframe animation,
    /// sampled finely enough that the linear pieces are invisible. Begins at layer
    /// time ~0, so a rebuild (resize) continues the same phase instead of jumping.
    static func wave(_ keyPath: String, base: CGFloat, amp: CGFloat, freq: Double,
                     phase: Double = 0, cosine: Bool = false) -> CAKeyframeAnimation {
        let period = 2 * Double.pi / freq
        let steps = 180
        let anim = CAKeyframeAnimation(keyPath: keyPath)
        anim.values = (0...steps).map { i -> CGFloat in
            let a = freq * (Double(i) / Double(steps) * period) + phase
            return base + amp * CGFloat(cosine ? cos(a) : sin(a))
        }
        anim.calculationMode = .linear
        anim.duration = period
        anim.repeatCount = .infinity
        anim.beginTime = 1e-6
        anim.isRemovedOnCompletion = false
        return anim
    }
}

final class BackdropDriftView: DriftLayerView {
    private let imageLayer = CALayer()

    init(image: NSImage) {
        super.init(frame: .zero)
        imageLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        imageLayer.contentsGravity = .resizeAspectFill
        // Scale about the bottom edge — the ember stays anchored low (y-up: 0).
        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        container.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func build(in size: CGSize, scale: CGFloat) {
        imageLayer.contentsScale = scale
        imageLayer.bounds = CGRect(origin: .zero, size: size)
        let x = size.width / 2
        // Barely-there: ~±12 pt parallax over a ~100 s cycle, plus a 1.5 % scale
        // breath. Base overscale 1.10 keeps the drift from ever revealing an edge.
        // SwiftUI's downward offset `8·cos` is −8·cos in y-up coordinates.
        imageLayer.position = CGPoint(x: x, y: -8)
        imageLayer.setValue(1.10, forKeyPath: "transform.scale")
        imageLayer.removeAllAnimations()
        imageLayer.add(Self.wave("position.x", base: x, amp: 12, freq: 0.060), forKey: "dx")
        imageLayer.add(Self.wave("position.y", base: 0, amp: -8, freq: 0.045, cosine: true), forKey: "dy")
        imageLayer.add(Self.wave("transform.scale", base: 1.10, amp: 0.015, freq: 0.030), forKey: "breath")
    }
}

// MARK: - Drifting glow (the bit of life)

/// A few large, very soft warm glows that drift along slow Lissajous paths and
/// add light over the ember wallpaper. Deliberately restrained — warm tones only
/// (no rainbow), low opacity, parked in the lower half so the top stays calm.
/// Freezes under Reduce Motion / when the app is inactive.
private struct DriftingGlow: NSViewRepresentable {
    let animate: Bool

    func makeNSView(context: Context) -> GlowDriftView { GlowDriftView() }
    func updateNSView(_ view: GlowDriftView, context: Context) { view.setAnimating(animate) }
}

final class GlowDriftView: DriftLayerView {
    struct Spec {
        let color: Color
        let cx: CGFloat, cy: CGFloat   // home (fraction of w/h)
        let ax: CGFloat, ay: CGFloat   // drift amplitude (fraction)
        let dia: CGFloat               // diameter (fraction of min(w,h))
        let f: Double, p: Double       // drift frequency + phase
        let opacity: Double
    }

    static let specs: [Spec] = [
        .init(color: Theme.featherCoral, cx: 0.30, cy: 0.86, ax: 0.07, ay: 0.04, dia: 1.05, f: 0.050, p: 0.0, opacity: 0.20),
        .init(color: Theme.featherGold,  cx: 0.74, cy: 0.92, ax: 0.06, ay: 0.04, dia: 0.95, f: 0.045, p: 2.2, opacity: 0.14),
        .init(color: Theme.featherCoral, cx: 0.55, cy: 0.78, ax: 0.05, ay: 0.05, dia: 0.80, f: 0.060, p: 4.0, opacity: 0.12),
    ]

    /// How far past the original circle's edge the (formerly blurred) glow reaches,
    /// as a multiple of its radius.
    static let glowReach: CGFloat = 1.45

    /// The glow's radial alpha profile, as (radius ÷ circle radius, alpha ÷ opacity).
    /// It is the old linear fade + `blur(0.16·d)` measured off SwiftUI's own render
    /// (max error 0.012 before the ≤ 0.20 opacity — under one 8-bit step): the blur
    /// itself, ~110 pt over three ~700 pt circles, cost ~35 ms per frame.
    static let glowProfile: [(r: CGFloat, a: Double)] = [
        (0, 0.627), (0.2, 0.592), (0.4, 0.482), (0.6, 0.337),
        (0.8, 0.200), (1.0, 0.094), (1.2, 0.031), (1.45, 0),
    ]

    private var glows: [CAGradientLayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Light is ADDED over the ember (SwiftUI's `.plusLighter`).
        container.compositingFilter = "plusL"
        for _ in Self.specs {
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.locations = Self.glowProfile.map { NSNumber(value: Double($0.r / Self.glowReach)) }
            container.addSublayer(glow)
            glows.append(glow)
        }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (glow, spec) in zip(glows, Self.specs) {
                let base = NSColor(spec.color).cgColor
                glow.colors = Self.glowProfile.map { base.copy(alpha: CGFloat(spec.opacity * $0.a)) ?? base }
            }
        }
    }

    override func build(in size: CGSize, scale: CGFloat) {
        let w = size.width, h = size.height, base = min(w, h)
        for (glow, s) in zip(glows, Self.specs) {
            let d = base * s.dia * Self.glowReach
            glow.contentsScale = scale
            glow.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            // SwiftUI's y = h·cy + h·ay·cos(…) measured from the top is
            // h·(1 − cy) − h·ay·cos(…) from the bottom.
            glow.position = CGPoint(x: w * s.cx + w * s.ax * CGFloat(sin(s.p)),
                                    y: h * (1 - s.cy) - h * s.ay * CGFloat(cos(s.p)))
            glow.removeAllAnimations()
            glow.add(Self.wave("position.x", base: w * s.cx, amp: w * s.ax, freq: s.f, phase: s.p), forKey: "x")
            glow.add(Self.wave("position.y", base: h * (1 - s.cy), amp: -h * s.ay, freq: s.f * 1.1,
                               phase: s.p, cosine: true), forKey: "y")
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
