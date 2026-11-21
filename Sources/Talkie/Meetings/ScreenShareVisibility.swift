import AppKit

/// Keeps the meeting surfaces (the pill and banner under the notch, the notes
/// window) out of screen sharing and screen recordings while they stay visible to
/// the user. A window marked `sharingType = .none` is left out of the captured
/// picture (checked on macOS 26 with a ScreenCaptureKit display capture, which is
/// what Zoom, Teams and Meet use).
@MainActor
enum ScreenShareVisibility {
    nonisolated static let defaultsKey = "hideMeetingWindowsFromScreenSharing"

    private static let windows = NSHashTable<NSWindow>.weakObjects()

    /// On unless the user turned it off (also before the defaults are registered).
    static var hidesFromSharing: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The capture behaviour for a meeting surface under the current setting.
    nonisolated static func sharingType(hidden: Bool) -> NSWindow.SharingType {
        hidden ? .none : .readOnly
    }

    /// Apply the setting to `window` now and whenever it changes.
    static func register(_ window: NSWindow) {
        windows.add(window)
        window.sharingType = sharingType(hidden: hidesFromSharing)
    }

    /// Re-apply after the setting changed.
    nonisolated static func refresh() {
        Task { @MainActor in
            let type = sharingType(hidden: hidesFromSharing)
            for window in windows.allObjects { window.sharingType = type }
        }
    }
}
