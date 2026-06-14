import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let dictionary = DictionaryStore()
    let permissions = PermissionsModel()
    let history = HistoryStore()
    let stats = StatsStore()
    let appUsage = AppUsageStore()
    let activity = ActivityStore()
    let projectIndex = ProjectIndexStore()
    let contextSummary = ContextSummaryStore()
    let meetingStore = MeetingStore()

    private var engine: TranscriptionEngine!
    private var meetingRecorder: MeetingRecorder!
    private let audio = AudioCapture()
    private let hud = HUDController()
    private let learning = LearningEngine()
    private let cleanup = CleanupEngine()
    private var hotKey: HotKeyMonitor?

    private var statusItem: NSStatusItem?
    private var mainWindow: MainWindowController?

    private var isDictating = false
    /// Bumped on every begin; lets an in-flight async setup detect that the
    /// user already released the key (or started a newer session) and bail.
    private var sessionID = 0
    /// True only once audio is actually flowing into a live analyzer session.
    private var sessionLive = false
    /// When the current recording actually started flowing (for WPM/duration).
    private var recordingStartedAt: Date?
    /// The language currently used for live transcription (sticky; switches when
    /// language auto-detect finds you spoke a different one of your languages).
    private var currentLocaleID: String = ""
    /// The app captured at the start of the current dictation (for usage stats).
    private var currentTarget: TargetApp = .unknown
    /// Cleans finalized segments incrementally and combines them on stop.
    private var currentAssembler: DictationAssembler?
    /// Cleanup config captured at the START of the session (so a mid-session
    /// settings toggle can't skew the end-of-session accounting).
    private var sessionCleanup: (appAdaptive: Bool, style: CleanupStyle, level: CleanupLevel)?
    /// The project file index snapshot to apply to the current dictation (vibe coding).
    private var currentVibeSnapshot: ProjectIndexSnapshot = .empty

    // MARK: App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Talkie: applicationDidFinishLaunching")
        // Regular Dock app: shows in the Dock with a real window (not menu-bar-only).
        NSApp.setActivationPolicy(.regular)

        Feedback.enabled = settings.playSounds
        currentLocaleID = settings.spokenLanguages.first ?? settings.localeIdentifier
        engine = TranscriptionEngine(localeIdentifier: currentLocaleID)
        meetingRecorder = MeetingRecorder(engine: engine, store: meetingStore)
        meetingRecorder.isDictating = { [weak self] in self?.isDictating == true }
        meetingRecorder.recoverPartialIfNeeded()

        setupMainMenu()
        setupStatusItem()
        setupEngineHandler()
        setupHotKey()

        permissions.refresh()
        observeSettings()

        // Warm each spoken language's model in the background so the first
        // dictation — and any language switch — is instant (no inline download).
        for lang in settings.spokenLanguages {
            Task { try? await engine.warmUp(localeIdentifier: lang) }
        }

        // Open the main window on launch — Permissions first if not set up yet,
        // otherwise the History log.
        openSettings(tab: permissions.allGranted ? .dashboard : .permissions)

        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    /// Clicking the Dock icon (with no window open) reopens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings(tab: .dashboard) }
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

                // Pre-warm every spoken language so a switch never downloads inline.
                for lang in self.settings.spokenLanguages {
                    Task { try? await self.engine.warmUp(localeIdentifier: lang) }
                }
                // If the primary language changed, switch the live engine to it.
                let primary = self.settings.spokenLanguages.first ?? self.settings.localeIdentifier
                if primary != self.currentLocaleID {
                    self.currentLocaleID = primary
                    await self.engine.setLocaleIdentifier(primary)
                }
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
        // The meeting recorder shares the transcription engine — don't dictate
        // over an active recording.
        guard meetingRecorder?.isRecording != true else {
            hud.showError("Stop the meeting recording first.")
            return
        }

        // Recursive self-improvement: learn from any edits the user made to the
        // previous dictation before starting this one.
        if settings.learnFromEdits {
            for correction in learning.collectCorrections() {
                dictionary.addLearnedReplacement(from: correction.from, to: correction.to)
            }
        }

        isDictating = true
        sessionLive = false
        sessionID += 1
        let myID = sessionID
        updateStatusUI()
        Feedback.start()
        hud.showListening()

        // Context awareness: capture who you're dictating into (always, for the
        // usage dashboard) and — when enabled — mine names worth spelling right.
        let captured = ContextCapture.capture(
            selfBundleID: AppPaths.bundleIdentifier,
            minePhrases: settings.contextAwareness
        )
        currentTarget = captured.target
        currentVibeSnapshot = settings.vibeCoding ? projectIndex.snapshot : .empty

        // Bias the recognizer with the union of: custom vocabulary, on-screen
        // names from the target app, and (in vibe mode) your project's filenames.
        var bias = dictionary.contextualPhrasesSnapshot()
        bias.append(contentsOf: captured.phrases)
        if settings.vibeCoding { bias.append(contentsOf: currentVibeSnapshot.biasPhrases) }
        let phrases = Array(Set(bias)).prefix(180).map { $0 }
        let multiLang = settings.spokenLanguages.count > 1

        // Batched cleanup: each finalized segment is cleaned as it arrives and the
        // results are combined on stop. Skipped for multi-language (the language
        // isn't known until the end), where cleanup runs once on stop instead.
        let cleanupEngine = self.cleanup
        let appAdaptive = settings.appAdaptiveCleanup
        let adaptiveStyle = settings.cleanupStyle(for: captured.target.category)
        let cleanupLevel = settings.cleanupLevel
        let cleanFn: @Sendable (String) async -> String? = { segment in
            guard !multiLang else { return nil }
            if appAdaptive {
                return adaptiveStyle == .off ? nil : await cleanupEngine.clean(segment, style: adaptiveStyle)
            }
            return cleanupLevel == .none ? nil : await cleanupEngine.clean(segment, level: cleanupLevel)
        }
        let assembler = DictationAssembler(clean: cleanFn)
        currentAssembler = assembler
        sessionCleanup = (appAdaptive: appAdaptive, style: adaptiveStyle, level: cleanupLevel)

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
                let session = try await engine.beginSession(segmentHandler: { segment in assembler.add(segment) })
                // Re-check after the (async) model load / session setup.
                guard self.isDictating, self.sessionID == myID else {
                    await engine.cancelSession()
                    return
                }
                try audio.start(
                    targetFormat: session.format,
                    continuation: session.continuation,
                    bufferAudio: multiLang,
                    onLevel: { level in
                        Task { @MainActor in AppDelegate.sharedHUD?.updateLevel(level) }
                    }
                )
                self.sessionLive = true
                self.recordingStartedAt = Date()
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
            currentAssembler = nil
            hud.hide()
            return
        }
        sessionLive = false
        let duration = Date().timeIntervalSince(recordingStartedAt ?? Date())
        recordingStartedAt = nil

        Feedback.stop()
        audio.stop()
        hud.showProcessing()

        let replacements = dictionary.replacementsSnapshot()
        let autoCap = settings.autoCapitalize
        let removeFillers = settings.cleanupFillers
        let mode = settings.insertionMode
        let spokenLanguages = settings.spokenLanguages
        let vibeOn = settings.vibeCoding
        let vibeSnapshot = currentVibeSnapshot
        let target = currentTarget
        let selfBundle = AppPaths.bundleIdentifier
        // Reuse the cleanup config captured at session start, so a mid-session
        // toggle can't make the stats/filler accounting disagree with what the
        // assembler actually cleaned.
        let sessionCfg = sessionCleanup
        sessionCleanup = nil
        let appAdaptive = sessionCfg?.appAdaptive ?? settings.appAdaptiveCleanup
        let adaptiveStyle = sessionCfg?.style ?? settings.cleanupStyle(for: target.category)
        let cleanupLevel = sessionCfg?.level ?? settings.cleanupLevel

        Task {
            let raw = await engine.finishSession()

            // Language auto-detect: if the transcript looks like a different one
            // of your languages, re-transcribe the captured audio in that language.
            var finalRaw = raw
            if spokenLanguages.count > 1, !raw.isEmpty,
               let detected = LanguageDetector.detect(raw, among: spokenLanguages),
               detected != self.currentLocaleID {
                let buffers = self.audio.bufferedAudio()
                if let reText = await self.engine.transcribeBuffered(buffers, localeIdentifier: detected) {
                    finalRaw = reText
                    self.currentLocaleID = detected
                    await self.engine.setLocaleIdentifier(detected) // stick to it next time
                }
            }

            // Cleanup. Non-multi-language sessions were cleaned incrementally,
            // segment by segment, as you spoke (the assembler) — so a long
            // dictation never hits the model as one huge transcript. Multi-language
            // is cleaned here, once, on the (possibly re-transcribed) full text.
            let multiLang = spokenLanguages.count > 1
            let cleanupEnabled = appAdaptive ? (adaptiveStyle != .off) : (cleanupLevel != .none)
            var cleaned: String
            if !multiLang, let assembler = self.currentAssembler {
                cleaned = await assembler.cleaned()
                if cleaned.isEmpty { cleaned = finalRaw }
            } else if cleanupEnabled, !finalRaw.isEmpty {
                let polished = appAdaptive
                    ? await self.cleanup.clean(finalRaw, style: adaptiveStyle)
                    : await self.cleanup.clean(finalRaw, level: cleanupLevel)
                cleaned = polished ?? finalRaw
            } else {
                cleaned = finalRaw
            }
            self.currentAssembler = nil
            let aiHandledFillers = cleanupEnabled && CleanupEngine.isAvailable && cleaned != finalRaw
            let aiWordsChanged = aiHandledFillers ? Self.wordEditCount(from: finalRaw, to: cleaned) : 0

            // Apply the dictionary AFTER the LLM so your exact spellings always win.
            let processed = TextProcessor.apply(
                replacements: replacements,
                removeFillers: aiHandledFillers ? false : removeFillers,
                autoCapitalize: autoCap,
                to: cleaned
            )
            var finalText = processed.text

            // Vibe coding: snap spoken filenames to the real files in your project
            // ("exercise library dot tsx" → "ExerciseLibrary.tsx").
            var fileFixes = 0
            if vibeOn, !vibeSnapshot.isEmpty {
                let (vibed, hits) = SpokenFileMatcher.format(finalText, snapshot: vibeSnapshot)
                finalText = vibed
                fileFixes = hits
            }

            guard !finalText.isEmpty else {
                self.hud.hide()
                return
            }

            // Log it (copyable in the History tab) + lifetime stats + fix tally,
            // even if insertion fell back to the clipboard.
            let words = WordCounter.count(finalText)
            self.history.add(
                finalText, wordCount: words, durationSec: duration,
                appName: target.name, appCategory: target.category.rawValue
            )
            self.stats.record(words: words, durationSec: duration)
            self.stats.recordFixes(
                dictionary: processed.replacementHits + fileFixes,
                fillers: processed.fillersRemoved,
                aiWords: aiWordsChanged
            )
            // Per-day activity (streak + heatmap) and where your words went.
            self.activity.record(words: words)
            if target.bundleID != selfBundle {
                self.appUsage.record(target: target, words: words)
            }

            let outcome = TextInjector.insert(finalText, mode: mode)
            switch outcome {
            case .inserted:
                Feedback.done()
                self.hud.showInserting()
                self.hud.hide(after: 0.4)
                // Snapshot the field after the paste lands, so we can learn from
                // any edits the user makes before the next dictation.
                if self.settings.learnFromEdits {
                    let learnedText = finalText
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        self.learning.recordInsertion(learnedText)
                    }
                }
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
                stats: stats,
                appUsage: appUsage,
                activity: activity,
                projectIndex: projectIndex,
                contextSummary: contextSummary,
                meetingRecorder: meetingRecorder,
                meetingStore: meetingStore,
                onRetryHotKey: { [weak self] in _ = self?.hotKey?.start() }
            )
        }
        mainWindow?.show(tab: tab)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Rough count of word-level edits the AI cleanup made (insertions + removals).
    private static func wordEditCount(from a: String, to b: String) -> Int {
        let beforeTokens = a.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let afterTokens = b.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return afterTokens.difference(from: beforeTokens).count
    }

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
