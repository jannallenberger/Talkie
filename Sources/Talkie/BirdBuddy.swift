import AppKit
import SwiftUI

/// UserDefaults key holding the bird's saved bottom-left origin as "x,y". A
/// file-level constant (not actor-isolated) so the window-move observer closure
/// can read it without a concurrency warning.
private let birdBuddyOriginKey = "birdBuddyOrigin"

/// The always-on "Bird Buddy" — a small, semi-transparent Talkie macaw that floats
/// above every app for the whole time Talkie is running, so you always know it's
/// alive and ready. It is deliberately *separate* from the transient capture pill
/// (`HUD.swift`), which only appears during a dictation:
///
///   • idle      — the app is open but you're not dictating. The bird sits calm and
///                 translucent, with a slow "breathing" scale. "I'm ready."
///   • active    — you're holding the dictation key and audio is flowing. The bird
///                 brightens and pulses/wobbles in time with your voice level (fed
///                 from the same mic meter that drives the pill's waveform).
///                 "I hear you, I'm capturing."
///
/// The window is freely draggable (drag the bird anywhere) and remembers its
/// position across launches. The mic only ever runs *while you dictate*, so the
/// bird can only react to your voice during the active phase — by design.
@MainActor
final class BirdBuddyModel: ObservableObject {
    /// True while a dictation is live (arming/listening) — drives the bright,
    /// reactive look. False between dictations (calm, translucent, breathing).
    @Published var active = false
    /// Latest normalized mic level (0…1), only meaningful while `active`.
    @Published var level: CGFloat = 0
}

/// Owns the floating bird panel and the handful of state transitions the dictation
/// pipeline drives (`setActive`, `updateLevel`). Mirrors `HUDController`'s shape so
/// it's familiar, but this panel is persistent and user-movable rather than pinned.
@MainActor
final class BirdBuddyController {
    private let model = BirdBuddyModel()
    private var panel: NSPanel?
    /// Persists the bird's position whenever the user drags it (retained here).
    private let moveDelegate = BirdMoveDelegate()

    /// The bird canvas. A touch larger than the artwork so the pulse/wobble and the
    /// soft shadow have room to grow without being clipped at the window edge.
    private static let panelSize = NSSize(width: 132, height: 132)

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: BirdBuddyView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // Drag the bird from anywhere on its canvas to reposition it.
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false           // the SwiftUI bird draws its own shadow
        panel.ignoresMouseEvents = false  // must accept drags
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        // The delegate persists the bird's position whenever the user drags it.
        panel.delegate = moveDelegate

        self.panel = panel
        return panel
    }

    /// Place the bird at its saved spot, or bottom-center on first run.
    private func positionInitially(_ panel: NSPanel) {
        if let saved = UserDefaults.standard.string(forKey: birdBuddyOriginKey) {
            let parts = saved.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2, screenContains(NSPoint(x: parts[0], y: parts[1])) {
                panel.setFrameOrigin(NSPoint(x: parts[0], y: parts[1]))
                return
            }
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Guard against a saved position that's off-screen now (e.g. a display was
    /// unplugged) — fall back to the default placement if so.
    private func screenContains(_ origin: NSPoint) -> Bool {
        let probe = NSRect(origin: origin, size: Self.panelSize).insetBy(dx: 20, dy: 20)
        return NSScreen.screens.contains { $0.frame.intersects(probe) }
    }

    /// Show the bird (called at launch when enabled, or when the setting is turned on).
    func show() {
        let panel = ensurePanel()
        positionInitially(panel)
        panel.orderFrontRegardless()
    }

    /// Hide the bird (setting turned off / app teardown).
    func hide() {
        panel?.orderOut(nil)
    }

    /// Flip between the calm idle look and the bright reactive one.
    func setActive(_ active: Bool) {
        model.active = active
        if !active { model.level = 0 }
    }

    /// Feed the live mic level (ignored while idle — the mic isn't running then).
    func updateLevel(_ level: Float) {
        guard model.active else { return }
        model.level = CGFloat(max(0, min(1, level)))
    }
}

/// Saves the bird window's bottom-left origin to UserDefaults each time the user
/// drags it. `NSWindowDelegate` callbacks are main-actor isolated, so reading the
/// window frame here is concurrency-clean (unlike a Sendable notification closure).
@MainActor
private final class BirdMoveDelegate: NSObject, NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        let o = win.frame.origin
        UserDefaults.standard.set("\(o.x),\(o.y)", forKey: birdBuddyOriginKey)
    }
}

// MARK: - SwiftUI bird content

private struct BirdBuddyView: View {
    @ObservedObject var model: BirdBuddyModel
    /// Flips on every level update to drive the alternating wing-beat while talking.
    @State private var flapSign: CGFloat = 1

    /// Warm macaw orange for the active glow — between the app's scarlet and gold,
    /// deliberately not the macaw blue.
    private static let glowOrange = Color(red: 0.95, green: 0.45, blue: 0.13)

    var body: some View {
        // A gentle "wing-beat": the silhouette squeezes horizontally and stretches
        // vertically in alternation, amplitude tied to your voice. On a single flat
        // image this reads as a light flap rather than a shake. (True per-wing
        // flapping would need a layered asset with the wings on their own element.)
        let flap = model.active ? flapSign * model.level * 0.06 : 0
        let pulse = model.active ? 1.0 + model.level * 0.12 : 1.0

        Image(nsImage: Brand.logo)
            .resizable()
            .scaledToFit()
            .frame(width: 84, height: 84)
            // Idle: fully desaturated to grayscale. Active: snaps to full color.
            .saturation(model.active ? 1 : 0)
            .grayscale(model.active ? 0 : 1)
            // ~10% more translucent overall than before, in both states.
            .opacity(model.active ? 0.9 : 0.5)
            // Voice-driven pulse + the horizontal/vertical wing-beat. No positional
            // shake — the bird stays put and only its wings "breathe".
            .scaleEffect(CGSize(width: pulse * (1 - flap), height: pulse * (1 + flap)))
            // Neutral drop shadow plus, while active, a *subtle* warm-orange glow
            // that swells gently with your voice — the "lights up" cue.
            .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 4)
            .shadow(color: Self.glowOrange.opacity(model.active ? 0.28 + model.level * 0.22 : 0),
                    radius: model.active ? 7 + model.level * 7 : 0)
            .animation(.easeOut(duration: 0.1), value: model.level)
            .animation(.easeInOut(duration: 0.35), value: model.active)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.level) {
                // Alternate the beat direction each frame for the flapping rhythm.
                flapSign *= -1
            }
            .help(String(format: "%@ — hold your dictation key and speak".loc, Brand.displayName))
            // The macaw's color/grayscale state is the whole signal, invisible to a
            // VoiceOver user — so name it, and state whether it's currently
            // listening, rather than exposing a bare, unlabeled image.
            .accessibilityElement()
            .accessibilityLabel(model.active
                ? String(format: "%@ is listening.".loc, Brand.displayName)
                : String(format: "%@ dictation indicator. Hold your dictation key and speak.".loc, Brand.displayName))
    }
}
