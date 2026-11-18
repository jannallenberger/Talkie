import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` (macOS 13+) for "open at login". Only works for
/// a real signed .app bundle — a bare `swift run` binary will throw, which we
/// swallow so dev runs don't crash.
enum LaunchAtLogin {
    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Talkie: launch-at-login change failed: \(error.localizedDescription)")
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}

/// Whether a launch should put the main window on screen. A normal launch (Dock,
/// Finder, `open`, Spotlight) always shows it; the only quiet start is the
/// "Open at login" launch of an already-onboarded user, who lands in the menu bar.
enum LaunchPresentation {
    static func shouldShowWindow(hasOnboarded: Bool, launchedAsLoginItem: Bool) -> Bool {
        !(hasOnboarded && launchedAsLoginItem)
    }

    /// True when the OS started this process as a login item (the open-application
    /// Apple event carries `keyAELaunchedAsLogInItem`).
    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent) -> Bool {
        event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }
}
