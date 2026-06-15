import AppKit

/// Shared mechanics for the family of floating, non-activating panels Talkie pins
/// just under the camera notch (top-center): the dictation HUD, the meeting consent
/// banner, and the live meeting pill. Centralizes the panel configuration and the
/// notch / menu-bar / multi-display positioning math so each surface doesn't
/// re-derive it (the dictation HUD predates this and keeps its own copy; the two
/// meeting surfaces share this one).
@MainActor
enum NotchPanel {
    /// A borderless, non-activating floating panel with a clear background, sized to
    /// `size`. `interactive` decides whether it claims mouse events — the banner has
    /// buttons (true); the pill must never block clicks to the call underneath it
    /// (false, so clicks pass straight through).
    static func make(size: NSSize, interactive: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false           // the SwiftUI content draws its own shadow
        panel.ignoresMouseEvents = !interactive
        // Sit above full-screen meeting windows and follow across Spaces, like the HUD.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    /// The screen the user is working on: prefer the one under the cursor (where the
    /// call and your attention are), then the main/key screen.
    static func preferredScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Pin `panel` horizontally centered and just below the notch / menu bar of the
    /// preferred screen. `extraTop` drops it further down so two stacked surfaces
    /// (e.g. a banner above the pill) don't collide.
    static func reposition(_ panel: NSPanel, extraTop: CGFloat = 0) {
        guard let screen = preferredScreen() else { return }
        let full = screen.frame
        let visible = screen.visibleFrame
        let size = panel.frame.size
        // The notch is centered on the display, so center the panel horizontally.
        let x = full.midX - size.width / 2
        // The menu bar (and, on notched Macs, the notch safe area) is the gap between
        // the full frame top and the visible frame top. When the menu bar is
        // auto-hidden or an app is full-screen that gap collapses to 0 — fall back to
        // the notch / status-bar height so the panel still clears the notch.
        let topChrome = full.maxY - visible.maxY
        let notch = screen.safeAreaInsets.top
        let effectiveChrome = topChrome > 0 ? topChrome : max(notch, NSStatusBar.system.thickness)
        let gap: CGFloat = 4
        let y = (full.maxY - effectiveChrome - gap - extraTop) - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
