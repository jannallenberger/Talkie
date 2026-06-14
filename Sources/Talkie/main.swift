import AppKit

// Talkie is a menu-bar-only (accessory) app: no Dock icon, no main menu bar.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
