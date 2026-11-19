import SwiftUI
import AppKit
import QuartzCore

// MARK: - Skeleton loading (design system)
//
// Content placeholders for anything the user waits on: a page's first frame, a
// search, a scan, a summary being written. A skeleton is the shape of what is
// coming, drawn in `Theme.skeleton` (the sunken fill tracks and wells use), so the
// layout does not jump when the real content replaces it.
//
// Rules (docs/DESIGN_GUIDELINES.md §11):
//   • Skeletons stand in for CONTENT. A running action (Check now, Install) keeps
//     its spinner / `TalkieStatusLine(.progress)`.
//   • Compose them from the parts below; no page draws its own grey boxes.
//   • Parts sit inside a `TalkieSkeletonGroup`, placed INSIDE its card: the group
//     owns the shimmer (one highlight band masked to the parts, so card surfaces
//     stay still), freezes it under Reduce Motion, and reads to VoiceOver as one
//     "Loading…". Several skeleton cards together: `.talkieSkeletonRegion()` makes
//     them one VoiceOver element.
//   • A skeleton is transient: it leaves the hierarchy when content arrives, so its
//     animation stops with it. Never keep one mounted in a hidden window.

extension Theme {
    /// The placeholder fill: one step down from the surface it sits on.
    static var skeleton: Color { surfaceSunken }
    /// The soft highlight band the shimmer passes over the placeholders.
    static let skeletonHighlight = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.075)
            : NSColor(white: 1, alpha: 0.8)
    })
}

// MARK: Parts

/// One line of placeholder text: a sunken bar at text height. `width` nil fills
/// the available width; `fraction` takes that share of it instead.
struct TalkieSkeletonLine: View {
    var width: CGFloat? = nil
    var fraction: CGFloat? = nil
    /// The text size this line stands in for. The bar is ~0.8 of it (a cap height)
    /// inside a line box of ~1.35 — the space a real line of that size takes.
    var textSize: CGFloat = 13

    private var barHeight: CGFloat { max(6, (textSize * 0.8).rounded()) }
    private var lineHeight: CGFloat { (textSize * 1.35).rounded() }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous) }

    var body: some View {
        Group {
            if let width {
                SkeletonFill(shape: shape).frame(width: width, height: barHeight)
            } else if let fraction {
                GeometryReader { geo in
                    SkeletonFill(shape: shape)
                        .frame(width: geo.size.width * min(1, max(0, fraction)), height: barHeight)
                }
                .frame(height: barHeight)
            } else {
                SkeletonFill(shape: shape).frame(height: barHeight)
            }
        }
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .frame(height: lineHeight)
    }
}

/// A paragraph of placeholder lines; the last one is shorter, like real prose.
struct TalkieSkeletonText: View {
    var lines: Int = 3
    var textSize: CGFloat = 13
    var lastLineFraction: CGFloat = 0.6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<max(1, lines), id: \.self) { i in
                if i == lines - 1, lines > 1 {
                    TalkieSkeletonLine(fraction: lastLineFraction, textSize: textSize)
                } else {
                    TalkieSkeletonLine(textSize: textSize)
                }
            }
        }
    }
}

/// A solid placeholder block (a chart, an image, a big number), control radius.
struct TalkieSkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = Theme.Radius.control

    var body: some View {
        SkeletonFill(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// A placeholder chip (a vocabulary term, a tag), chip radius.
struct TalkieSkeletonChip: View {
    var width: CGFloat = 72

    var body: some View {
        SkeletonFill(shape: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .frame(width: width, height: 26)
    }
}

/// A placeholder avatar / app icon.
struct TalkieSkeletonCircle: View {
    var size: CGFloat = 24

    var body: some View {
        SkeletonFill(shape: Circle()).frame(width: size, height: size)
    }
}

// MARK: Group + shimmer

/// One loading region of placeholder PARTS (bars, chips, blocks — no card
/// surfaces: put the group inside the card). Owns the shimmer, the Reduce Motion
/// freeze, and the single VoiceOver element.
///
/// The shimmer is one soft highlight band masked to the parts. Its motion is a
/// Core Animation animation on a gradient layer (`SkeletonShimmerBand`), so it runs
/// in the render server: SwiftUI's view graph does no per-frame work at all. (A
/// SwiftUI-driven band — TimelineView, or a repeating offset animation — re-ran the
/// display list every frame and kept the main thread ~100 % busy.)
struct TalkieSkeletonGroup<Content: View>: View {
    var label: String = "Loading…"
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .overlay {
                if !reduceMotion {
                    SkeletonShimmerBand()
                        .mask { content }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label.loc))
            .allowsHitTesting(false)
    }
}

/// The shimmer's moving band: a horizontal clear → highlight → clear gradient layer
/// whose position is animated by Core Animation (repeat forever, linear). One pass
/// every 1.6 s; the band travels to 1.5 × the width, so about a third of each cycle
/// is a rest — calm enough to read as "on its way", never as an alarm.
private struct SkeletonShimmerBand: NSViewRepresentable {
    func makeNSView(context: Context) -> ShimmerBandView { ShimmerBandView() }
    func updateNSView(_ nsView: ShimmerBandView, context: Context) {}
}

final class ShimmerBandView: NSView {
    private let band = CAGradientLayer()
    private var animatedWidth: CGFloat = -1
    static let period: CFTimeInterval = 1.6
    /// Snapshot tests only: park the band at this phase (0…1) instead of animating,
    /// so a rendered image shows where it sweeps.
    nonisolated(unsafe) static var testPhase: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.locations = [0, 0.5, 1]
        layer?.addSublayer(band)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        var highlight = NSColor.white.withAlphaComponent(0.8).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight = NSColor(Theme.skeletonHighlight).cgColor
        }
        // The ends are the highlight at zero alpha, NOT `.clear`: `.clear` is
        // transparent BLACK, and Core Animation interpolating black → white draws
        // grey fringes on both sides of the band.
        let edge = highlight.copy(alpha: 0) ?? NSColor.white.withAlphaComponent(0).cgColor
        band.colors = [edge, highlight, edge]
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, width != animatedWidth else { return }
        animatedWidth = width
        let bandWidth = max(90, width * 0.35)
        let fromX = -bandWidth / 2, toX = width * 1.5 + bandWidth / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.bounds = CGRect(x: 0, y: 0, width: bandWidth, height: bounds.height)
        band.position = CGPoint(x: fromX + (Self.testPhase ?? 0) * (toX - fromX), y: bounds.midY)
        CATransaction.commit()
        guard Self.testPhase == nil else { return }
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = fromX
        move.toValue = toX
        move.duration = Self.period
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .linear)
        // Groups that appear together sweep together: phase-lock to the clock.
        move.beginTime = band.convertTime(CACurrentMediaTime(), from: nil)
            - CACurrentMediaTime().truncatingRemainder(dividingBy: Self.period)
        band.removeAnimation(forKey: "shimmer")
        band.add(move, forKey: "shimmer")
    }
}

extension View {
    /// Groups several skeleton cards (each with its own `TalkieSkeletonGroup`
    /// inside) into ONE VoiceOver element and keeps clicks from landing on them.
    func talkieSkeletonRegion(label: String = "Loading…") -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label.loc))
            .allowsHitTesting(false)
    }
}

/// The fill of every placeholder shape.
private struct SkeletonFill<S: Shape>: View {
    let shape: S

    var body: some View {
        shape.fill(Theme.skeleton)
    }
}

// MARK: - Common skeleton layouts

/// A card's worth of placeholder: an eyebrow-length bar, an optional metric, lines.
/// Carries its own shimmer group.
struct TalkieSkeletonCard: View {
    var lines: Int = 3
    var showsMetric: Bool = false
    var padding: CGFloat = Theme.Space.card
    var fill: Bool = false

    var body: some View {
        TalkieSkeletonGroup {
            VStack(alignment: .leading, spacing: 10) {
                TalkieSkeletonLine(width: 96, textSize: 11)
                if showsMetric {
                    TalkieSkeletonBlock(width: 120, height: 30, cornerRadius: Theme.Radius.chip)
                }
                TalkieSkeletonText(lines: lines)
            }
        }
        .talkieCard(padding: padding, fill: fill)
    }
}

/// A list row placeholder: optional leading circle, a title bar and a meta bar.
struct TalkieSkeletonRow: View {
    var leading: Bool = false
    var titleFraction: CGFloat = 0.55
    var showsMeta: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if leading { TalkieSkeletonCircle(size: 22) }
            VStack(alignment: .leading, spacing: 2) {
                TalkieSkeletonLine(fraction: titleFraction, textSize: 13)
                if showsMeta { TalkieSkeletonLine(width: 110, textSize: 11) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

/// A column of row placeholders on one surface, split by hairlines like real rows.
struct TalkieSkeletonList: View {
    var rows: Int = 5
    var leading: Bool = false
    /// Draws its own surface; pass false when the rows sit on a card already.
    var surface: Bool = true

    private static let titleFractions: [CGFloat] = [0.62, 0.45, 0.7, 0.52, 0.38, 0.66]

    var body: some View {
        let list = TalkieSkeletonGroup {
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { i in
                    if i > 0 { Divider().overlay(Theme.hairline) }
                    TalkieSkeletonRow(leading: leading,
                                      titleFraction: Self.titleFractions[i % Self.titleFractions.count])
                }
            }
        }
        if surface { list.talkieSurface() } else { list }
    }
}

/// A flow of chip placeholders (vocabulary, learned terms). Parts only: place it in
/// a `TalkieSkeletonGroup` with whatever else the card holds.
struct TalkieSkeletonChips: View {
    var count: Int = 8
    private static let widths: [CGFloat] = [64, 92, 56, 110, 74, 84, 60, 98, 70, 120]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                TalkieSkeletonChip(width: Self.widths[i % Self.widths.count])
            }
        }
    }
}
