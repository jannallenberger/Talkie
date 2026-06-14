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
