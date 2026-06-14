import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let dictionary = DictionaryStore()
    let permissions = PermissionsModel()
    let history = HistoryStore()

    private var engine: TranscriptionEngine!
    private let audio = AudioCapture()
    private let hud = HUDController()
    private var hotKey: HotKeyMonitor?

    private var statusItem: NSStatusItem?
    private var mainWindow: MainWindowController?

    private var isDictating = false
    /// Bumped on every begin; lets an in-flight async setup detect that the
    /// user already released the key (or started a newer session) and bail.
    private var sessionID = 0
    /// True only once audio is actually flowing into a live analyzer session.
    private var sessionLive = false

    // MARK: App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Talkie: applicationDidFinishLaunching")
        // Regular Dock app: shows in the Dock with a real window (not menu-bar-only).
        NSApp.setActivationPolicy(.regular)

        Feedback.enabled = settings.playSounds
        engine = TranscriptionEngine(localeIdentifier: settings.localeIdentifier)

        setupMainMenu()
        setupStatusItem()
        setupEngineHandler()
        setupHotKey()

        permissions.refresh()
        observeSettings()

        // Warm the model in the background so first dictation is instant.
        Task { try? await engine.warmUp() }

        // Open the main window on launch — Permissions first if not set up yet,
        // otherwise the History log.
        openSettings(tab: permissions.allGranted ? .history : .permissions)

        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    /// Clicking the Dock icon (with no window open) reopens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings(tab: .history) }
        return true
    }

    /// Closing the window keeps Talkie running in the background for dictation.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func appBecameActive() {
        permissions.refresh()
        // If Input Monitoring was just granted, the tap can now install.
        if hotKey?.start() == true { updateStatusUI() }
        updateStatusUI()
    }

    // MARK: Main menu

    /// A regular (Dock) app needs a main menu for ⌘Q and, importantly, an Edit
    /// menu so ⌘C/⌘V/⌘A work in the History list and text fields.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Talkie",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…",
                                           action: #selector(openSettingsMenu), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Talkie",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Talkie",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: Status bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Talkie") {
                image.isTemplate = true
                button.image = image
            }
            // Guarantee the item is visible even if the SF Symbol fails to load —
            // an image-less, title-less status item is zero-width (invisible).
            if button.image == nil {
                button.title = "Talkie"
            }
            button.toolTip = "Talkie — hold your key to dictate"
        }
        item.menu = buildMenu()
        statusItem = item
        NSLog("Talkie: status item created (hasButton=\(item.button != nil), hasImage=\(item.button?.image != nil))")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let hint = NSMenuItem(title: hintLine(), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Dictionary…", action: #selector(openDictionary), keyEquivalent: "d")
            .target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsMenu), keyEquivalent: ",")
            .target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Talkie", action: #selector(quit), keyEquivalent: "q")
            .target = self

        return menu
    }

    private func statusLine() -> String {
        if !TranscriptionEngine.isAvailable { return "Talkie — speech unavailable" }
        if !permissions.allGranted { return "Talkie — needs permissions" }
        return isDictating ? "Talkie — listening…" : "Talkie — ready"
    }

    private func hintLine() -> String {
        let mode = settings.activationMode == .holdToTalk ? "Hold" : "Tap"
        return "\(mode) \(settings.activationKey.displayName) to dictate"
    }

    private func updateStatusUI() {
        guard let menu = statusItem?.menu else { return }
        if menu.items.indices.contains(0) { menu.items[0].title = statusLine() }
        if menu.items.indices.contains(1) { menu.items[1].title = hintLine() }
        let symbol = isDictating ? "waveform" : "mic.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Talkie")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.contentTintColor = isDictating ? .systemRed : nil
    }

    // MARK: Engine ↔ HUD

    private func setupEngineHandler() {
        Task {
            await engine.setUpdateHandler { update in
                Task { @MainActor in
                    guard !update.isComplete else { return }
                    AppDelegate.sharedHUD?.updateTranscribing(update.combined)
                }
            }
        }
        AppDelegate.sharedHUD = hud
    }

    // The engine's @Sendable handler can't capture `self` cleanly across the
    // actor boundary; route HUD updates through a main-actor static.
    private static weak var sharedHUD: HUDController?

    // MARK: Hotkey

    private enum DictationEvent: Sendable { case begin, end }
    private var eventTask: Task<Void, Never>?

    private func setupHotKey() {
        // Funnel press/release edges through ONE ordered stream so a begin can
        // never be scheduled after its matching end (two independent Tasks have
        // no FIFO guarantee on the MainActor executor).
        let (stream, continuation) = AsyncStream<DictationEvent>.makeStream()
        eventTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .begin: self.beginDictation()
                case .end: self.endDictation()
                }
            }
        }

        let config = HotKeyMonitor.Config(key: settings.activationKey, mode: settings.activationMode)
        let monitor = HotKeyMonitor(
            config: config,
            onActivate: { continuation.yield(.begin) },
            onDeactivate: { continuation.yield(.end) }
        )
        _ = monitor.start()
        hotKey = monitor
    }

    private func observeSettings() {
        // Re-bind the hotkey + sound prefs when settings change.
        settingsObservation = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .talkieSettingsChanged) {
                guard let self else { return }
                Feedback.enabled = self.settings.playSounds
                self.hotKey?.update(config: .init(key: self.settings.activationKey, mode: self.settings.activationMode))
                self.updateStatusUI()
            }
        }
    }
    private var settingsObservation: Task<Void, Never>?

    // MARK: Dictation session

    func beginDictation() {
        guard !isDictating else { return }
        guard TranscriptionEngine.isAvailable else {
            hud.showError("On-device speech isn't available on this Mac.")
            return
        }
        isDictating = true
        sessionLive = false
        sessionID += 1
        let myID = sessionID
        updateStatusUI()
        Feedback.start()
        hud.showListening()

        let phrases = dictionary.contextualPhrasesSnapshot()

        Task {
            let micOK = await AudioCapture.requestMicrophoneAccess()
            // The user may have released the key (or started a new session)
            // while we awaited the mic. Bail without starting anything.
            guard self.isDictating, self.sessionID == myID else { return }
            guard micOK else {
                self.isDictating = false
                self.updateStatusUI()
                self.hud.showError("Microphone access is needed to dictate.")
                self.permissions.refresh()
                return
            }
            do {
                await engine.setContextualStrings(phrases)
                let session = try await engine.beginSession()
                // Re-check after the (async) model load / session setup.
                guard self.isDictating, self.sessionID == myID else {
                    await engine.cancelSession()
                    return
                }
                try audio.start(
                    targetFormat: session.format,
                    continuation: session.continuation,
                    onLevel: { level in
                        Task { @MainActor in AppDelegate.sharedHUD?.updateLevel(level) }
                    }
                )
                self.sessionLive = true
            } catch {
                self.isDictating = false
                self.updateStatusUI()
                self.hud.showError(error.localizedDescription)
                await engine.cancelSession()
            }
        }
    }

    func endDictation() {
        guard isDictating else { return }
        isDictating = false
        updateStatusUI()

        // If the session never actually went live (key released during async
        // setup), the begin task will see the generation change and abort — we
        // just reset the UI here.
        guard sessionLive else {
            hud.hide()
            return
        }
        sessionLive = false

        Feedback.stop()
        audio.stop()
        hud.showInserting()

        let replacements = dictionary.replacementsSnapshot()
        let autoCap = settings.autoCapitalize
        let removeFillers = settings.cleanupFillers
        let mode = settings.insertionMode

        Task {
            let raw = await engine.finishSession()
            let processed = TextProcessor.apply(
                replacements: replacements,
                removeFillers: removeFillers,
                autoCapitalize: autoCap,
                to: raw
            )

            guard !processed.isEmpty else {
                self.hud.hide()
                return
            }

            // Log it (copyable in the History tab) even if insertion fell back to clipboard.
            self.history.add(processed)

            let outcome = TextInjector.insert(processed, mode: mode)
            switch outcome {
            case .inserted:
                Feedback.done()
                self.hud.hide(after: 0.15)
            case .leftOnClipboard(let reason):
                Feedback.abort()
                self.hud.showError(reason)
            case .empty:
                self.hud.hide()
            }
        }
    }

    // MARK: Menu actions

    @objc private func openDictionary() { openSettings(tab: .dictionary) }
    @objc private func openSettingsMenu() { openSettings(tab: .general) }

    func openSettings(tab: SettingsTab) {
        permissions.refresh()
        if mainWindow == nil {
            mainWindow = MainWindowController(
                settings: settings,
                dictionary: dictionary,
                permissions: permissions,
                history: history,
                onRetryHotKey: { [weak self] in _ = self?.hotKey?.start() }
            )
        }
        mainWindow?.show(tab: tab)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Shared accessor for C-callback bridges

    static weak var shared: AppDelegate?
    override init() {
        super.init()
        AppDelegate.shared = self
    }
}

extension Notification.Name {
    static let talkieSettingsChanged = Notification.Name("talkieSettingsChanged")
}
