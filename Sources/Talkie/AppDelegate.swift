import AppKit
import Combine
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
    // Integration spine: the cores' stores, wired into the live app
    // (features 05 graph, 08/11 commands+macros, 13 per-app profiles, 19 search).
    let contextGraph = ContextGraphStore()
    let macros = MacroStore()
    let profiles = AppProfileStore()
    let searchEngine = SearchEngine()
    private lazy var commandRouter = CommandRouter(macros: macros)

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
    /// True from key-release until the transcript has been polished + inserted.
    /// Blocks a new session from overlapping the in-flight one (which shares the
    /// engine + audio); a re-press during this window just nudges the pill.
    private var isProcessing = false
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
    /// Cleanup config captured at the START of the session (so a mid-session
    /// settings toggle can't skew the end-of-session accounting).
    private var sessionCleanup: (appAdaptive: Bool, style: CleanupStyle, level: CleanupLevel)?
    /// Cleans transcript segments live while you speak, so most of the cleanup
    /// is done by the time you release the key. Built per session when cleanup
    /// is enabled; consumed (or discarded) in `endDictation`.
    private var currentStreaming: StreamingCleanup?
    /// The project file index snapshot to apply to the current dictation (vibe coding).
    private var currentVibeSnapshot: ProjectIndexSnapshot = .empty

    // MARK: Meeting auto-detect + live pill

    /// Polls Core Audio for a mic-hot meeting app and offers to record (never silent).
    private var meetingDetector: ActiveMeetingDetector!
    /// The "record this meeting?" offer banner shown under the notch.
    private let consentBanner = MeetingConsentBannerController()
    /// The live meeting pill under the notch (shown for the duration of a recording).
    private let meetingPill = MeetingPillController()
    /// The on-device live-subtopic detector + the value the pill observes.
    private let subtopicModel = MeetingSubtopicModel()
    private var subtopicEngine: MeetingSubtopicEngine!
    /// Drives the pill + subtopic engine off the recorder's `isRecording`, so both
    /// auto- and manually-started recordings get the pill.
    private var recordingObservation: AnyCancellable?

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
        meetingRecorder.primaryLocale = { [weak self] in
            self?.settings.spokenLanguages.first ?? self?.settings.localeIdentifier ?? "en-US"
        }
        meetingRecorder.spokenLanguages = { [weak self] in self?.settings.spokenLanguages ?? [] }
        meetingRecorder.contextGraph = contextGraph
        meetingRecorder.meetingLanguageMode = { [weak self] in self?.settings.meetingLanguageMode ?? "auto" }
        meetingRecorder.recoverPartialIfNeeded()

        setupMeetingDetection()

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

        // Warm the on-device cleanup model once at launch too (best-effort, like
        // the Speech warmUp above) so the VERY first dictation's polish pays no
        // cold-start either. With adaptive cleanup we don't yet know the target
        // app, so warm the generic style; beginDictation re-warms with the real
        // app's style once it's known.
        prewarmCleanup(style: settings.cleanupStyle(for: .other),
                       level: settings.cleanupLevel,
                       appAdaptive: settings.appAdaptiveCleanup)

        // The Brief renders as a projection of the context graph.
        contextSummary.graphProvider = { [weak self] in self?.contextGraph.snapshot() ?? .empty }

        // HUD cleanup-style switcher (feature 14): show + cycle the active level in-pill.
        hud.bindCleanupSwitcher(
            label: { [weak self] in self?.settings.cleanupLevel.displayName },
            cycle: { [weak self] in
                guard let self else { return }
                let all = CleanupLevel.allCases
                if let i = all.firstIndex(of: self.settings.cleanupLevel) {
                    self.settings.cleanupLevel = all[(i + 1) % all.count]
                }
            }
        )

        // Seed the context graph + search index from existing dictations + meetings
        // so recall, search, and the brief are useful immediately.
        Task { @MainActor in
            contextGraph.backfill(dictations: history.entries, meetings: meetingStore.meetings)
            searchEngine.rebuild(dictations: history.entries,
                                 meetings: meetingStore.meetings,
                                 graph: contextGraph.snapshot())
        }

        // Open the main window on launch — onboarding/permissions are handled
        // inside the window now; just land on the Dashboard.
        openSettings(tab: .dashboard)

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
            onDeactivate: { continuation.yield(.end) },
            onPasteLast: { [weak self] in
                Task { @MainActor in self?.pasteLastTranscript() }
            }
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

                // Re-bind meeting detection (toggle / allowlist / mute) live.
                let config = self.makeDetectorConfig()
                if let detector = self.meetingDetector {
                    await detector.updateConfig(config)
                }
                // React to the pill toggle for an in-flight recording.
                if self.meetingRecorder.isRecording {
                    if self.settings.showMeetingPill { self.meetingPill.show() }
                    else { self.meetingPill.hide() }
                }
            }
        }
    }
    private var settingsObservation: Task<Void, Never>?

    // MARK: Meeting detection wiring

    /// Build the subtopic engine + pill, wire the live-segment feed, observe the
    /// recorder's recording state (so manual *and* auto recordings get the pill), and
    /// start the detector poll loop. Detection itself is a passive Core Audio
    /// metadata read — no TCC prompt — so it can run from launch.
    private func setupMeetingDetection() {
        subtopicEngine = MeetingSubtopicEngine(model: subtopicModel)
        meetingPill.attach(recorder: meetingRecorder, subtopic: subtopicModel)

        // Feed finalized transcript segments to the subtopic engine (gated by setting).
        meetingRecorder.onLiveSegment = { [weak self] _, text in
            Task { @MainActor in
                guard let self, self.settings.meetingLiveTopic else { return }
                await self.subtopicEngine.ingest(text)
            }
        }

        // Show the pill + run the subtopic engine for ANY recording (auto or manual),
        // and hide/reset on stop. `$isRecording` emits its current value on subscribe.
        recordingObservation = meetingRecorder.$isRecording
            .removeDuplicates()
            .sink { [weak self] recording in
                Task { @MainActor in
                    guard let self else { return }
                    if recording { self.onRecordingStarted() } else { self.onRecordingStopped() }
                }
            }

        let detector = ActiveMeetingDetector(config: makeDetectorConfig())
        meetingDetector = detector
        Task {
            await detector.start(
                onDetect: { [weak self] signal in
                    Task { @MainActor in self?.handleMeetingDetected(signal) }
                },
                onMute: { [weak self] bundleID in
                    Task { @MainActor in self?.muteMeetingApp(bundleID) }
                }
            )
        }
    }

    private func makeDetectorConfig() -> ActiveMeetingDetector.Config {
        ActiveMeetingDetector.Config(
            enabled: settings.autoDetectMeetings,
            allowlist: settings.meetingAllowlist,
            offerForAnyMicApp: settings.offerMeetingForAnyMicApp,
            muted: Set(settings.mutedMeetingApps)
        )
    }

    /// A meeting crossed the detection threshold. Apply the suppression the detector
    /// can't see (live dictation / an in-flight or active recording — they share the
    /// engine), then show the consent banner. Talkie never records without this tap.
    private func handleMeetingDetected(_ signal: MeetingSignal) {
        guard settings.autoDetectMeetings else { return }
        guard !isDictating, !isProcessing else { return }
        guard meetingRecorder?.isRecording != true, meetingRecorder?.isFinishing != true else { return }

        consentBanner.show(
            appName: signal.appName,
            isBrowser: signal.tier == .browser,
            onRecord: { [weak self] in
                Task { @MainActor in await self?.meetingRecorder.start() }
            },
            onDismiss: { [weak self] explicit in
                Task { await self?.meetingDetector?.markSessionDismissed(signal.appBundleID, mute: explicit) }
            }
        )
    }

    private func onRecordingStarted() {
        consentBanner.hide()   // banner handoff — the pill takes over
        guard settings.showMeetingPill else { return }
        meetingPill.show()
        if settings.meetingLiveTopic {
            Task { await subtopicEngine.start() }
        }
    }

    private func onRecordingStopped() {
        meetingPill.hide()
        Task { await subtopicEngine.stop() }
    }

    private func muteMeetingApp(_ bundleID: String) {
        if !settings.mutedMeetingApps.contains(bundleID) {
            settings.mutedMeetingApps.append(bundleID)
        }
    }

    // MARK: Dictation session

    /// Kick off a best-effort background warm-up of the on-device cleanup model,
    /// matching the Speech `warmUp` pattern. Skips entirely when the model isn't
    /// available or cleanup is disabled for the given config, so a cold first
    /// dictation never pays the model load inline.
    private func prewarmCleanup(style: CleanupStyle, level: CleanupLevel, appAdaptive: Bool) {
        guard CleanupEngine.isAvailable else { return }
        let cleanupEnabled = appAdaptive ? (style != .off) : (level != .none)
        guard cleanupEnabled else { return }
        Task {
            if appAdaptive {
                await cleanup.prewarm(style: style)
            } else {
                await cleanup.prewarm(level: level)
            }
        }
    }

    func beginDictation() {
        guard !isDictating else { return }
        // A previous dictation is still being polished/inserted. Starting now
        // would overlap two sessions on the shared engine + audio, so just flash
        // the pill to acknowledge the press and bail.
        guard !isProcessing else {
            hud.nudgeBusy()
            return
        }
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
        // Acknowledge the press immediately — but the dot stays GRAY (arming) until
        // audio is genuinely flowing; only then does it turn red (recording).
        hud.showArming()

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
        // Context graph: bias toward the people/projects/terms you actually use.
        bias.append(contentsOf: contextGraph.snapshot().biasPhrases())
        let phrases = Array(Set(bias)).prefix(180).map { $0 }
        let multiLang = settings.spokenLanguages.count > 1

        // Capture the cleanup config at the start so a mid-session settings toggle
        // can't skew the end-of-session accounting. Cleanup runs ONCE on the WHOLE
        // transcript at stop — so spoken self-corrections that span a pause
        // ("Thursday, no Friday") are resolved with full context — and is chunked
        // only when the transcript is genuinely long.
        let appAdaptive = settings.appAdaptiveCleanup
        let adaptiveStyle = settings.cleanupStyle(for: captured.target.category)
        let cleanupLevel = settings.cleanupLevel
        sessionCleanup = (appAdaptive: appAdaptive, style: adaptiveStyle, level: cleanupLevel)

        // Warm the on-device cleanup model the moment recording starts, in
        // parallel with everything else, so the first cleanup at stop-time
        // doesn't pay a cold model load. Mirrors `engine.warmUp` for Speech.
        let cleanupEngine = self.cleanup
        let cleanupEnabled = appAdaptive ? (adaptiveStyle != .off) : (cleanupLevel != .none)
        if cleanupEnabled {
            Task {
                if appAdaptive { await cleanupEngine.prewarm(style: adaptiveStyle) }
                else { await cleanupEngine.prewarm(level: cleanupLevel) }
            }
        }

        // Stream cleanup of each finalized segment *while you speak*, so the
        // stop-time pass only has to finish the last segment instead of the
        // whole transcript. Built only when cleanup is on and the model is
        // usable; otherwise the raw path is unchanged. `endDictation` consumes
        // (or, on the language-switch fallback, discards) this buffer.
        let cleanupLocaleID = currentLocaleID
        let cleanOne: @Sendable (String) async -> String? = { text in
            appAdaptive
                ? await cleanupEngine.clean(text, style: adaptiveStyle, localeID: cleanupLocaleID)
                : await cleanupEngine.clean(text, level: cleanupLevel, localeID: cleanupLocaleID)
        }
        let streaming = (cleanupEnabled && CleanupEngine.isAvailable)
            ? StreamingCleanup(enabled: true, cleanOne: cleanOne)
            : nil
        currentStreaming = streaming
        let segmentHandler: (@Sendable (String) -> Void)?
        if let streaming {
            segmentHandler = { segment in streaming.ingest(segment) }
        } else {
            segmentHandler = nil
        }

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
                // Re-pin the engine to our baseline locale. The shared engine may
                // have been left on another language by a meeting recording (which
                // pins it to the primary) or a prior dictation's language switch,
                // and `currentLocaleID` is the self-consistency baseline below — so
                // they must agree at the start of every session.
                await engine.setLocaleIdentifier(self.currentLocaleID)
                await engine.setContextualStrings(phrases)
                let session = try await engine.beginSession(segmentHandler: segmentHandler)
                // Re-check after the (async) model load / session setup.
                guard self.isDictating, self.sessionID == myID else {
                    streaming?.cancel()
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
                // Audio is live now — flip the pill to the red "recording" state.
                self.hud.showListening()
            } catch {
                // The user may have released the key (or started a newer session)
                // before this error surfaced — tear down silently rather than
                // flashing an error pill for a session they already abandoned.
                guard self.isDictating, self.sessionID == myID else {
                    streaming?.cancel()
                    await engine.cancelSession()
                    return
                }
                self.isDictating = false
                self.updateStatusUI()
                self.hud.showError(error.localizedDescription)
                streaming?.cancel()
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
            currentStreaming?.cancel()
            currentStreaming = nil
            hud.hide()
            return
        }
        sessionLive = false
        let duration = Date().timeIntervalSince(recordingStartedAt ?? Date())
        recordingStartedAt = nil

        Feedback.stop()
        audio.stop()
        isProcessing = true
        hud.showProcessing()

        let replacements = dictionary.replacementsSnapshot()
        let autoCap = settings.autoCapitalize
        let removeFillers = settings.cleanupFillers
        let mode = settings.insertionMode
        let optimisticEnabled = settings.optimisticInsertion
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
        // The live per-segment cleanup that ran while you spoke (nil when cleanup
        // is off). Consumed below, or discarded if a language switch re-wrote the
        // whole transcript.
        let streaming = currentStreaming
        currentStreaming = nil

        Task {
            // Always release the processing latch when this task finishes — even
            // on an early or unexpected exit — so a stalled/abandoned pipeline can
            // never permanently block the next dictation.
            defer { self.isProcessing = false }
            var trace = ProcessingTrace()
            let (raw, segments) = await engine.finishSessionDetailed()
            trace.stage("finalize")

            var finalRaw = raw
            var languageSwitched = false
            // Language auto-detect (multilingual only). macOS decodes the whole
            // utterance with ONE language model, so secondary-language speech comes
            // out as gibberish. Decide the real language by ACOUSTIC CONFIDENCE: at
            // stop, re-transcribe the captured audio in every spoken language and
            // keep the one whose model fit the audio best (highest mean per-word
            // recognition confidence). This beats language-ID of the text, which
            // leaks because wrong-model gibberish still contains real words of the
            // wrong (current) language. Short utterances are skipped — nothing to gain.
            if spokenLanguages.count > 1, !raw.isEmpty, LanguageDetector.canScore(raw) {
                talkieDebugLog("--- dictation: raw(\(self.currentLocaleID))='\(raw)'")
                let buffers = self.audio.bufferedAudio()
                let currentCode = LanguageDetector.languageCode(of: self.currentLocaleID)
                // Re-transcribe in every spoken language (one per language code,
                // incl. the current one so its confidence is the comparison baseline).
                let langs = LanguageDetector.distinctByCode(spokenLanguages)
                let scored = await self.engine.transcribeCandidates(
                    buffers, localeIdentifiers: langs, installIfNeeded: true)
                let currentConf = scored.first {
                    LanguageDetector.languageCode(of: $0.localeID) == currentCode
                }?.confidence ?? 0
                let best = scored.max { $0.confidence < $1.confidence }
                talkieDebugLog("decide: current=\(self.currentLocaleID)(\(String(format: "%.2f", currentConf))) scored=[\(scored.map { "\($0.localeID):\(String(format: "%.2f", $0.confidence))" }.joined(separator: ", "))]")
                if let best,
                   LanguageDetector.languageCode(of: best.localeID) != currentCode,
                   best.confidence >= currentConf + LanguageDetector.switchConfidenceMargin,
                   !best.text.isEmpty {
                    finalRaw = best.text
                    languageSwitched = true
                    self.currentLocaleID = best.localeID
                    await self.engine.setLocaleIdentifier(best.localeID) // stick to it next time
                    talkieDebugLog("switched → \(best.localeID)")
                }
            }
            trace.stage("reTx")

            // Cleanup. The fast path joins the segments that were already cleaned
            // live while you spoke — so we only wait on the last in-flight one.
            // We fall back to a fresh whole/batched pass only when streaming
            // wasn't running, or when a language switch re-wrote the transcript
            // (making the streamed work, which was for the original language,
            // stale). The whole pass also resolves self-corrections that span a
            // pause with full context; long transcripts split into sentence
            // batches (each within the model's context window).
            let cleanupEngine = self.cleanup
            let cleanupEnabled = appAdaptive ? (adaptiveStyle != .off) : (cleanupLevel != .none)

            // Optimistic insertion (experimental, off by default): drop the raw
            // transcript in immediately so there's no visible wait, then swap in
            // the cleaned text once the model finishes. Gated tightly — only when
            // the model will actually run (else nothing to swap to), in paste
            // mode, for non-command dictation of modest length, and never on the
            // language-switch path (finalRaw only settles after re-transcribe).
            var optimistic: (count: Int, text: String)?
            if optimisticEnabled, mode == .paste, cleanupEnabled, !languageSwitched,
               !finalRaw.isEmpty, CleanupEngine.isAvailable {
                let interimProcessed = TextProcessor.apply(
                    replacements: replacements, removeFillers: removeFillers,
                    autoCapitalize: autoCap, to: finalRaw
                )
                var interim = interimProcessed.text
                if vibeOn, !vibeSnapshot.isEmpty {
                    interim = SpokenFileMatcher.format(interim, snapshot: vibeSnapshot).0
                }
                if !interim.isEmpty, interim.count <= Self.optimisticMaxChars,
                   self.commandRouter.intent(for: interim) == nil,
                   case .inserted = TextInjector.insert(interim, mode: mode) {
                    optimistic = (interim.count, interim)
                    self.hud.showInserting(replacedWords: [])
                }
            }

            // De-seam: rejoin the finalized segments into one continuous stream with
            // the pause-induced periods removed, so a thinking pause never forces a
            // sentence break — the cleanup model (or the deterministic floor) decides
            // boundaries by grammar instead. On a language switch the segments belong
            // to the old language, so fall back to the re-transcribed string.
            let deseamed = (!languageSwitched && segments.count > 1)
                ? SentenceFlow.stripSeams(segments)
                : finalRaw
            var cleaned = finalRaw
            var usedStreaming = false
            if cleanupEnabled, !finalRaw.isEmpty, CleanupEngine.isAvailable {
                // Single-segment (no pause): the streamed result equals a whole
                // pass, so use it — it's already done. Multi-segment (you paused):
                // fall through to the whole-transcript pass so the model punctuates
                // with full context and a pause doesn't force a sentence break.
                if let streaming, !languageSwitched, streaming.segmentCount <= 1 {
                    cleaned = await streaming.finishCleaned()
                    usedStreaming = true
                    // Never insert empty when we actually have a transcript (e.g.
                    // a degenerate session that emitted no usable segments).
                    if cleaned.isEmpty { cleaned = finalRaw }
                } else {
                    streaming?.cancel()
                    // Use the *final* dictation locale (post language-switch) so the
                    // cleanup model rewrites in the language actually spoken.
                    let cleanupLocaleID = self.currentLocaleID
                    let cleanOne: @Sendable (String) async -> String? = { text in
                        appAdaptive
                            ? await cleanupEngine.clean(text, style: adaptiveStyle, localeID: cleanupLocaleID)
                            : await cleanupEngine.clean(text, level: cleanupLevel, localeID: cleanupLocaleID)
                    }
                    if deseamed.count <= Self.wholeCleanupCharLimit {
                        cleaned = (await cleanOne(deseamed)) ?? deseamed
                    } else {
                        cleaned = await Self.cleanInBatches(deseamed, cleanOne)
                    }
                }
            } else {
                streaming?.cancel()
                // No AI pass (cleanup off / model unavailable) — still neutralize the
                // pause-seams deterministically so we stop over-punctuating.
                if !languageSwitched, segments.count > 1 {
                    cleaned = SentenceFlow.mergeContinuations(segments)
                }
            }
            trace.stage("cleanup")
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

            // Voice command mode (the on-device copilot): a leading-imperative over
            // a selection ("make this a list", "translate to German") or a
            // whole-utterance macro runs the command INSTEAD of inserting as
            // dictation. Conservative — CommandRouter only matches imperatives /
            // macros, and rewrites require an actual AX selection — so normal
            // speech falls straight through to the dictation path below.
            if optimistic == nil, let intent = self.commandRouter.intent(for: finalText) {
                let selection = intent.needsSelection ? AXSelection.selectedText() : nil
                if !intent.needsSelection || (selection?.isEmpty == false) {
                    let ctx = CommandContext(
                        spokenCommand: finalText, selection: selection, target: target,
                        graph: self.contextGraph.snapshot(), summarizer: OnDeviceLLM()
                    )
                    if let result = await intent.run(ctx) {
                        self.isProcessing = false
                        if result.preview {
                            // Nothing is inserted until the user confirms in the pill.
                            self.hud.showCommandPreview(
                                result.replacement,
                                onConfirm: { _ = TextInjector.insert(result.replacement, mode: mode) },
                                onUndo: { [weak self] in self?.hud.hide() }
                            )
                        } else {
                            _ = TextInjector.insert(result.replacement, mode: mode)
                            self.hud.hide()
                        }
                        return
                    }
                }
            }

            // Which replacements to surface (HUD pings + fix tally). The recognizer
            // is biased toward replacement *targets*, so a respelling like
            // "correlate"→"coralate" often arrives already corrected in the raw
            // transcript — the literal find-and-replace then has nothing to match
            // and the fix would go unreported. Recover those by comparing the raw
            // transcript with what we actually inserted, and count them as
            // dictionary fixes too so the tally and the HUD agree.
            var replacedWords = processed.replacedWords
            let biasApplied = TextProcessor.biasAppliedTargets(
                rules: replacements, raw: finalRaw, output: finalText
            )
            for word in biasApplied where !replacedWords.contains(word) {
                replacedWords.append(word)
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
                dictionary: processed.replacementHits + biasApplied.count + fileFixes,
                fillers: processed.fillersRemoved,
                aiWords: aiWordsChanged
            )
            // Per-day activity (streak + heatmap) and where your words went.
            self.activity.record(words: words)
            if target.bundleID != selfBundle {
                self.appUsage.record(target: target, words: words)
            }
            // Feed the on-device context graph from what was just dictated.
            self.contextGraph.ingest(
                ContextGraphExtractor.candidates(from: finalText),
                provenance: Provenance(source: .dictation, sourceID: nil,
                                       dateUnix: Date().timeIntervalSince1970,
                                       snippet: String(finalText.prefix(120)))
            )

            let outcome: TextInjector.Outcome
            if let opt = optimistic {
                // The interim raw text is already on screen — swap it for the
                // cleaned final, unless cleanup changed nothing (already correct).
                outcome = finalText == opt.text
                    ? .inserted
                    : TextInjector.replaceBackward(graphemeCount: opt.count, with: finalText, mode: mode)
            } else {
                outcome = TextInjector.insert(finalText, mode: mode)
            }
            trace.stage("insert")
            trace.finish(chars: finalText.count, streamed: usedStreaming)
            switch outcome {
            case .inserted:
                Feedback.done()
                self.hud.showInserting(replacedWords: replacedWords)
                self.hud.hide(after: replacedWords.isEmpty ? 0.4 : 1.4)
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
                Feedback.notPasted()
                // Couldn't paste — the text is on the clipboard; offer a tap to
                // (re)copy it, plus the ⌥⌘V re-paste shortcut once a field is focused.
                self.hud.showCopyPrompt(
                    text: finalText, message: reason,
                    shortcut: self.settings.pasteLastShortcutEnabled ? self.pasteLastShortcutDisplay : nil
                )
            case .empty:
                self.hud.hide()
            }
        }
    }

    // MARK: Paste last transcript (⌥⌘V)

    /// The re-paste shortcut label for the current activation key (e.g. "⌃⌘V"),
    /// surfaced in the copy-prompt pill. Dynamic so it never names the combo that
    /// would also arm dictation.
    private var pasteLastShortcutDisplay: String { settings.activationKey.pasteShortcut.display }

    /// Re-insert the most recent transcript into whatever's focused now — the recovery
    /// path when a dictation couldn't find a field (focus one, press ⌥⌘V), and a
    /// general "paste my last words again" shortcut. No-op while a dictation is in
    /// flight (shared insertion path) or when the feature is disabled.
    private func pasteLastTranscript() {
        guard settings.pasteLastShortcutEnabled else { return }
        guard !isDictating, !isProcessing else { return }
        guard let text = history.entries.first?.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hud.showError("No transcript to paste yet.")
            return
        }
        switch TextInjector.insert(text, mode: settings.insertionMode) {
        case .inserted:
            Feedback.done()
            hud.showInserting(replacedWords: [])
            hud.hide(after: 0.4)
        case .leftOnClipboard(let reason):
            Feedback.notPasted()
            hud.showCopyPrompt(text: text, message: reason, shortcut: pasteLastShortcutDisplay)
        case .empty:
            hud.hide()
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
                contextGraph: contextGraph,
                macros: macros,
                profiles: profiles,
                searchEngine: searchEngine,
                onRetryHotKey: { [weak self] in _ = self?.hotKey?.start() }
            )
        }
        mainWindow?.show(tab: tab)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Below this many characters the whole transcript is cleaned in ONE pass (so
    /// self-corrections across pauses resolve); above it, we chunk by sentence.
    private static let wholeCleanupCharLimit = 2200

    /// Optimistic insertion only fires for transcripts at or below this length —
    /// the in-place swap selects backward one keystroke per character, so a very
    /// long transcript would mean a long, janky (and riskier) ⇧← run. 800 covers
    /// the typical multi-sentence dictation while keeping the swap snappy.
    private static let optimisticMaxChars = 800

    /// Clean a long transcript in sentence-grouped batches (each within the
    /// model's context window), joining the cleaned results in spoken order.
    /// Batches are cleaned with bounded concurrency rather than strictly one at a
    /// time, so a long fallback pass overlaps inference instead of summing it.
    private static func cleanInBatches(
        _ text: String,
        _ cleanOne: @escaping @Sendable (String) async -> String?
    ) async -> String {
        let batches = splitIntoBatches(text, maxChars: 2000)
        guard batches.count > 1 else {
            let only = batches.first ?? text
            return ((await cleanOne(only)) ?? only).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The on-device model is a shared resource, so cap the in-flight count to
        // avoid thrashing it; a small window overlaps latency without
        // oversubscribing. Order is preserved by writing results back by index.
        let maxConcurrent = min(3, batches.count)
        var results = [String?](repeating: nil, count: batches.count)
        await withTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func submit(_ i: Int) {
                let batch = batches[i]
                group.addTask { (i, (await cleanOne(batch)) ?? batch) }
            }
            while next < maxConcurrent { submit(next); next += 1 }
            for await (i, cleaned) in group {
                results[i] = cleaned
                if next < batches.count { submit(next); next += 1 }
            }
        }
        return results.compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitIntoBatches(_ text: String, maxChars: Int) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sub, _, _, _ in
            if let sub { sentences.append(sub) }
        }
        if sentences.isEmpty { sentences = [text] }
        var batches: [String] = []
        var current = ""
        for sentence in sentences {
            if !current.isEmpty, current.count + sentence.count > maxChars {
                batches.append(current)
                current = ""
            }
            current += sentence
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

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
