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
/// K4 — a brief, HONEST reaction the bird can play over its idle/active look. Each
/// maps to a real event (never decorative filler): a learned word, text left on the
/// clipboard because we couldn't paste, or a broken personal record. Reactions DROP
/// rather than queue (a backlog would read as fake), and collapse to a brightness
/// blip under Reduce Motion.
enum BirdMood: Equatable, Sendable {
    case gulp      // learned a new word/replacement — a satisfied swallow
    case glance    // text left on the clipboard — a glance at what it saved
    case preen     // a personal record broke — a proud little preen

    /// How long the reaction plays before the bird settles back.
    var duration: Double {
        switch self {
        case .gulp:   return 0.55
        case .glance: return 0.9
        case .preen:  return 1.2
        }
    }
}

@MainActor
final class BirdBuddyModel: ObservableObject {
    /// True while a dictation is live (arming/listening) — drives the bright,
    /// reactive look. False between dictations (calm, translucent, breathing).
    @Published var active = false
    /// Latest normalized mic level (0…1), only meaningful while `active`.
    @Published var level: CGFloat = 0
    /// A transient K4 reaction currently playing, or nil. Set via
    /// `BirdBuddyController.perform(_:)`; cleared automatically after its duration.
    @Published var mood: BirdMood?
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
    /// Pending "clear the current mood" task, so `hide()` can cancel it and a mood
    /// can't linger past its window.
    private var moodClearWorkItem: DispatchWorkItem?

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
        moodClearWorkItem?.cancel()
        model.mood = nil
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

    /// K4 — play a brief, honest reaction. DROPS if a reaction is already playing
    /// (never queues — a backlog of reactions would read as fake) and no-ops when the
    /// bird isn't on screen (setting off), so it only ever reacts where you can see it.
    func perform(_ mood: BirdMood) {
        guard panel?.isVisible == true else { return }
        guard model.mood == nil else { return }
        model.mood = mood
        let work = DispatchWorkItem { [weak self] in self?.model.mood = nil }
        moodClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + mood.duration, execute: work)
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
    /// Honor the system "Reduce Motion" setting — K4 moods collapse to a brightness
    /// blip instead of movement when it's on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Flips on every level update to drive the alternating wing-beat while talking.
    @State private var flapSign: CGFloat = 1
    /// 0…1 progress of the current K4 mood pose (springs up then back to 0).
    @State private var moodProgress: CGFloat = 0
    /// Brief brightness blip — the Reduce-Motion expression of a mood, plus a touch
    /// of sparkle on `.preen`.
    @State private var moodFlash: CGFloat = 0

    /// Warm macaw orange for the active glow — between the app's scarlet and gold,
    /// deliberately not the macaw blue.
    private static let glowOrange = Color(red: 0.95, green: 0.45, blue: 0.13)

    var body: some View {
        // A gentle "wing-beat": the silhouette squeezes horizontally and stretches
        // vertically in alternation, amplitude tied to your voice. On a single flat
        // image this reads as a light flap rather than a shake. (True per-wing
        // flapping would need a layered asset with the wings on their own element.)
        // Suppressed while a K4 mood plays so the two animations don't fight.
        let flap = (model.active && model.mood == nil) ? flapSign * model.level * 0.06 : 0
        let pulse = model.active ? 1.0 + model.level * 0.12 : 1.0
        // The K4 mood pose, interpolated by `moodProgress`. Reduce Motion zeroes the
        // geometry so the reaction is carried purely by the brightness blip below.
        let pose = Self.moodPose(model.mood, reduceMotion ? 0 : moodProgress)

        Image(nsImage: Brand.logo)
            .resizable()
            .scaledToFit()
            .frame(width: 84, height: 84)
            // Idle: fully desaturated to grayscale. Active: snaps to full color.
            .saturation(model.active ? 1 : 0)
            .grayscale(model.active ? 0 : 1)
            // ~10% more translucent overall than before, in both states.
            .opacity(model.active ? 0.9 : 0.5)
            // K4: a short brightness blip — the Reduce-Motion expression of any mood,
            // and a sparkle on `.preen`.
            .brightness(moodFlash * 0.32)
            // Voice-driven pulse + wing-beat, composed with the mood pose's squash/puff.
            .scaleEffect(CGSize(width: pulse * (1 - flap) * pose.sx,
                                height: pulse * (1 + flap) * pose.sy))
            .rotationEffect(.degrees(pose.rot))
            // Neutral drop shadow plus, while active, a *subtle* warm-orange glow
            // that swells gently with your voice — the "lights up" cue.
            .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 4)
            .shadow(color: Self.glowOrange.opacity(model.active ? 0.28 + model.level * 0.22 : 0),
                    radius: model.active ? 7 + model.level * 7 : 0)
            .animation(.easeOut(duration: 0.1), value: model.level)
            .animation(.easeInOut(duration: 0.35), value: model.active)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.level) {
                // Alternate the beat direction each frame for the flapping rhythm
                // (paused while a mood is playing so it doesn't cancel the pose).
                if model.mood == nil { flapSign *= -1 }
            }
            .onChange(of: model.mood) { _, newMood in
                playMood(newMood)
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

    /// Drive a mood's animation. Reduce Motion → a brightness blip only; otherwise a
    /// spring into the pose and back, with an extra sparkle on `.preen`.
    private func playMood(_ mood: BirdMood?) {
        guard let mood else { return }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.12)) { moodFlash = 1 }
            withAnimation(.easeIn(duration: 0.35).delay(0.12)) { moodFlash = 0 }
            return
        }
        withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { moodProgress = 1 }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.72).delay(0.18)) { moodProgress = 0 }
        if mood == .preen {
            withAnimation(.easeOut(duration: 0.15)) { moodFlash = 0.6 }
            withAnimation(.easeIn(duration: 0.55).delay(0.15)) { moodFlash = 0 }
        }
    }

    /// The geometric pose for each mood, scaled by progress `p` (0…1).
    private static func moodPose(_ mood: BirdMood?, _ p: CGFloat) -> (sx: CGFloat, sy: CGFloat, rot: Double) {
        guard let mood, p > 0 else { return (1, 1, 0) }
        switch mood {
        case .gulp:   return (1 + 0.10 * p, 1 - 0.16 * p, 0)             // squash down: a swallow
        case .glance: return (1, 1, -16 * Double(p))                     // tilt toward the clipboard
        case .preen:  return (1 + 0.13 * p, 1 + 0.13 * p, 7 * Double(p)) // proud puff + slight lean
        }
    }
}
