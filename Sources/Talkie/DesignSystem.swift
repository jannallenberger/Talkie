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

extension View {
    /// Pins a ~52pt top-edge material band over scroll content so it fades
    /// into a blur as it passes under the top edge, rather than clipping hard.
    /// Honors Reduce Transparency: falls back to a solid `Theme.canvas` → clear
    /// gradient (no blur) so it never reads as an opaque haze — mirrors the
    /// reduce-transparency pattern in `GlassCard` (LiveBackground.swift ~239-266).
    func scrollTopBlur() -> some View {
        modifier(ScrollTopBlurModifier())
    }
}

private struct ScrollTopBlurModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let bandHeight: CGFloat = 52

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            Group {
                if reduceTransparency {
                    LinearGradient(
                        colors: [Theme.canvas, Theme.canvas.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                } else {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .mask(
                            LinearGradient(
                                colors: [.black, .black.opacity(0)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                }
            }
            .frame(height: bandHeight)
            .allowsHitTesting(false)
        }
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
