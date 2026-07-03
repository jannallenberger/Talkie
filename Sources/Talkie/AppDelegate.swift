import AppKit
import Combine
import SwiftUI

#if TALKIE_DEV_TOOLS
import TalkieUpdater
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let dictionary = DictionaryStore()
    let permissions = PermissionsModel()
    let history = HistoryStore()
    let stats = StatsStore()
    let appUsage = AppUsageStore()
    let activity = ActivityStore()
    /// L4: running word/phrase frequency, accumulated at record time (transcripts
    /// are pruned after 7 days, so "most used" can't be recomputed from history).
    let wordFreq = WordFrequencyStore()
    /// L3a: rolling per-dictation software-latency record (last 50, numeric only —
    /// no transcript text). Populated from the post-release `ProcessingTrace`; the
    /// UI is L3b, so nothing consumes it in a view yet — it just accumulates.
    let latency = LatencyStore()
    /// L2-a: the dashboard Scratchpad (notes + tasks). Also the rescue sink for
    /// transcripts that couldn't be pasted — see the `.leftOnClipboard` branch, where
    /// a NON-secure-input failure appends the transcript here instead of leaving it
    /// only on the clipboard to be lost on the next copy.
    let scratchpad = ScratchpadStore()
    let projectIndex = ProjectIndexStore()
    let contextSummary = ContextSummaryStore()
    let meetingStore = MeetingStore()
    // Integration spine: the cores' stores, wired into the live app
    // (features 05 graph, 08/11 commands+macros, 13 per-app profiles, 19 search).
    let contextGraph = ContextGraphStore()
    let macros = MacroStore()
    let profiles = AppProfileStore()
    let searchEngine = SearchEngine(sidecarDirectory: AppPaths.supportDirectory()) // L13-a: persist sentence vectors in <support>/search/
    /// The confidence-based niche vocabulary store: jargon Talkie learns silently
    /// from what you dictate and confirm, graduating into the post-hoc
    /// `NicheCorrector` without a hand-curated Dictionary entry. `@MainActor`;
    /// every write stays on the main actor.
    let nicheVocab = NicheVocabStore()
    /// Not `private` — the Commands tab's sandbox exercises this exact live
    /// instance (and `hud` below) rather than a parallel throwaway router, so
    /// "try a command" tests the real thing.
    lazy var commandRouter = CommandRouter(macros: macros)
    let hud = HUDController()

    private var engine: TranscriptionEngine!
    private var meetingRecorder: MeetingRecorder!
    /// Imports dropped audio/video files into Meetings (transcript + summary + graph),
    /// off the main actor, one at a time, deferring while a dictation/recording is live.
    /// Built in `applicationDidFinishLaunching` so it can capture the same session probes
    /// as `meetingRecorder`. Not `private` so `MeetingsView` observes its progress.
    private(set) var fileImporter: FileImportCoordinator!
    private let audio = AudioCapture()
    /// The always-on floating macaw (separate from the transient capture pill).
    private let birdBuddy = BirdBuddyController()
    private let learning = LearningEngine()
    /// Learns corrections from Claude Code prompts on the AX-blind coding/terminal
    /// surface where `learning` (the field watcher) is blind. Lazy so its consent
    /// closures can read/write `settings`, which is a stored property. Reads/writes
    /// the tri-state `claudeTranscriptLearning` default (no settings row by design).
    private lazy var claudeLearner = ClaudeTranscriptLearner(
        readConsent: { [settings] in
            ClaudeTranscriptLearner.Consent(rawValue: settings.claudeTranscriptLearning) ?? .unset
        },
        writeConsent: { [settings] consent in
            settings.claudeTranscriptLearning = consent.rawValue
        }
    )
    /// Pauses now-playing media for the duration of a dictation and resumes it after.
    private let musicController = MusicController()
    private let cleanup = CleanupEngine()
    private var hotKey: HotKeyMonitor?
    /// Watches the MCP inbox for dictionary suggestions a Claude session queued (via
    /// the bundled `talkie-mcp`) and applies each one *with the same HUD-Undo pill*
    /// the LearningEngine uses — so a prompt-injected session can never silently
    /// pollute recognition (A5). Built in `applicationDidFinishLaunching`.
    private var dictionaryInbox: DictionaryInbox?

    private var statusItem: NSStatusItem?
    private var mainWindow: MainWindowController?
    /// Backs the two macOS Services ("Transcribe with Talkie", "Clean up with
    /// Talkie"). `NSApp.servicesProvider` holds this only *weakly*, so we retain it
    /// here for the app's lifetime — otherwise the provider would deallocate and the
    /// services would silently stop responding. Registered in
    /// `applicationDidFinishLaunching` (see `setupServices`).
    private var servicesProvider: ServicesProvider?

    private var isDictating = false
    /// True while the current session is locked hands-free (a tap-tap put it in
    /// locked mode). Purely presentational on the app side — the gesture machine in
    /// HotKeyMonitor owns the real lock state; this mirrors it so begin/end can
    /// reset the pill's lock glyph. Reset on every begin and end.
    private var handsFreeLocked = false
    /// True from key-release until the transcript has been polished + inserted.
    /// Blocks a new session from overlapping the in-flight one (which shares the
    /// engine + audio); a re-press during this window just nudges the pill.
    private var isProcessing = false
    /// L3a: flips true after the first dictation latency is recorded this launch,
    /// so exactly one record per app run is tagged `coldStart` (first-dictation
    /// warm-up costs, e.g. model spin-up, look different from steady-state).
    private var didRecordLatencyThisLaunch = false
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
    /// Cleanup style captured at the START of the session (so a mid-session
    /// settings change can't skew the end-of-session accounting). `nil` until a
    /// session begins; `.off` means "insert verbatim". This is the whole cleanup
    /// config now — style is Talkie's only cleanup model.
    private var sessionCleanup: CleanupStyle?
    /// The per-app rules resolved for the target app at the START of the session
    /// (global → per-category → per-app merge). Snapshotted once so a mid-session
    /// profile edit can't skew the in-flight session; `Sendable`, so it can ride
    /// into the `endDictation` processing Task. `nil` between sessions.
    private var sessionProfile: ResolvedProfile?
    /// Cleans transcript segments live while you speak, so most of the cleanup
    /// is done by the time you release the key. Built per session when cleanup
    /// is enabled; consumed (or discarded) in `endDictation`.
    private var currentStreaming: StreamingCleanup?
    /// The project file index snapshot to apply to the current dictation (vibe coding).
    private var currentVibeSnapshot: ProjectIndexSnapshot = .empty
    /// A discoverable project root behind the editor/terminal being dictated into,
    /// stashed at session start when vibe coding is OFF and the root is offer-worthy
    /// (A9). Consumed once, after a successful insertion, to show the one-tap "Index
    /// 〈Repo〉 filenames?" offer. `nil` when there's nothing to offer.
    private var pendingVibeOfferRoot: URL?
    /// A11 — identifiers mined from the source file you're LOOKING AT this session
    /// (resolved from the editor's window title against the project index, read + mined
    /// off-main at `beginDictation`). Unioned into the niche corrector's term set at
    /// `endDictation`, ranked above repo terms so the file on screen wins the budget.
    /// Empty when vibe coding is off, the title had no indexed filename, or the mine
    /// didn't finish before the key was released — a silent degrade to A3 behavior.
    /// Guarded by the `activeFileTermsGeneration` token so a slow mine from a previous
    /// session can never land its terms into a later one.
    private var sessionActiveFileTerms: [String] = []
    /// Bumped every `beginDictation`; the off-main mine captures its value and only
    /// publishes its result if the token still matches — otherwise the session it was
    /// mining for is already over, so the terms are dropped.
    private var activeFileTermsGeneration = 0
    /// Retained so a new session can cancel a still-running mine from the previous one
    /// (utility-QoS, off-main). Cancelling stops it churning after it's been superseded.
    private var activeFileMineTask: Task<Void, Never>?

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
    /// Keeps the search index reactive: rebuilds (debounced, off-main) whenever the
    /// history, meetings, or context graph change — so entries added after launch are
    /// searchable without a relaunch.
    private var searchIndexObservation: Set<AnyCancellable> = []
    /// Mirrors the user's history-retention choice into `HistoryStore` so shrinking
    /// the window re-prunes live (no relaunch). The store already read the persisted
    /// value at init, so this only handles later changes.
    private var retentionObservation: AnyCancellable?

    // MARK: App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Talkie: applicationDidFinishLaunching")
        // Regular Dock app: shows in the Dock with a real window (not menu-bar-only).
        NSApp.setActivationPolicy(.regular)

        Feedback.enabled = settings.playSounds
        currentLocaleID = settings.spokenLanguages.first ?? settings.localeIdentifier
        engine = PrivacyWall.assertLocal(TranscriptionEngine(localeIdentifier: currentLocaleID))
        meetingRecorder = MeetingRecorder(engine: engine, store: meetingStore)
        meetingRecorder.isDictating = { [weak self] in self?.isDictating == true }
        meetingRecorder.isProcessingDictation = { [weak self] in self?.isProcessing == true }
        meetingRecorder.primaryLocale = { [weak self] in
            self?.settings.spokenLanguages.first ?? self?.settings.localeIdentifier ?? "en-US"
        }
        meetingRecorder.spokenLanguages = { [weak self] in self?.settings.spokenLanguages ?? [] }
        meetingRecorder.contextGraph = contextGraph
        meetingRecorder.meetingLanguageMode = { [weak self] in self?.settings.meetingLanguageMode ?? "auto" }
        meetingRecorder.recoverPartialIfNeeded()

        // Drop-to-transcribe: imported files become Meetings. Injected with the same
        // meeting store + context graph the recorder uses, and the SAME live-session
        // probes (`isDictating`/`isProcessing`/`isRecording`) so an import never spins up
        // its extra analyzers over a live dictation or recording.
        fileImporter = FileImportCoordinator(
            meetingStore: meetingStore,
            contextGraph: contextGraph,
            primaryLocale: { [weak self] in
                self?.settings.spokenLanguages.first ?? self?.settings.localeIdentifier ?? "en-US"
            },
            spokenLanguages: { [weak self] in self?.settings.spokenLanguages ?? [] },
            isDictating: { [weak self] in self?.isDictating == true },
            isProcessing: { [weak self] in self?.isProcessing == true },
            isRecording: { [weak self] in self?.meetingRecorder?.isRecording == true }
        )

        setupMeetingDetection()

        setupMainMenu()
        setupStatusItem()
        setupEngineHandler()
        setupHotKey()
        setupServices()

        // Watch the MCP inbox for Claude-queued dictionary suggestions and surface
        // each with an Undo pill. Started here so a suggestion written while the app
        // was closed is scanned and pinged at launch — never applied silently.
        let inbox = DictionaryInbox(dictionary: dictionary, nicheVocab: nicheVocab, hud: hud)
        inbox.start()
        dictionaryInbox = inbox

        permissions.refresh()
        observeSettings()

        // The always-on floating bird, if the user keeps it on.
        if settings.showBirdBuddy { birdBuddy.show() }

        // Warm each spoken language's model in the background so the first
        // dictation — and any language switch — is instant (no inline download).
        for lang in settings.spokenLanguages {
            Task { try? await engine.warmUp(localeIdentifier: lang) }
        }

        // Warm the on-device cleanup model once at launch too (best-effort, like
        // the Speech warmUp above) so the VERY first dictation's polish pays no
        // cold-start either. We don't yet know the target app, so warm the generic
        // ("other") category style; beginDictation re-warms with the real app's
        // resolved style once it's known.
        prewarmCleanup(style: settings.cleanupStyle(for: .other))

        // The Brief renders as a projection of the context graph.
        contextSummary.graphProvider = { [weak self] in self?.contextGraph.snapshot() ?? .empty }

        // HUD cleanup-style switcher (feature 14): show + cycle the active *style*
        // in-pill. The label reflects the style actually resolved for the in-flight
        // session (per-app override or category style), so it matches what gets used
        // at stop. Cycling advances the session category's style through every case
        // and persists it (session-scoped switching is H3). When no session is live
        // (rare — the switcher is a capture-phase control) fall back to the "other"
        // category so the label is never empty.
        hud.bindCleanupSwitcher(
            label: { [weak self] in
                guard let self else { return nil }
                return self.activeCleanupStyle.displayName
            },
            cycle: { [weak self] in
                guard let self else { return }
                let category = self.sessionProfile?.category ?? .other
                let current = self.settings.cleanupStyle(for: category)
                let all = CleanupStyle.allCases
                if let i = all.firstIndex(of: current) {
                    self.settings.appCleanupStyles[category.rawValue] = all[(i + 1) % all.count].rawValue
                }
            }
        )

        // Seed the context graph + search index from existing dictations + meetings
        // so recall, search, and the brief are useful immediately.
        Task { @MainActor in
            // Backfill BEFORE wiring the search subscription, so the first `$entities`
            // emission already reflects it (the debounce coalesces the backfill and the
            // initial store snapshots into a single rebuild).
            contextGraph.backfill(dictations: history.entries, meetings: meetingStore.meetings)
            // Reactive, debounced, off-main rebuild: `@Published` emits its current
            // value on subscribe, so this also performs the initial seed (replacing the
            // old one-shot `rebuild`), and re-indexes any entry added after launch.
            Publishers.MergeMany(
                history.$entries.map { _ in () }.eraseToAnyPublisher(),
                meetingStore.$meetings.map { _ in () }.eraseToAnyPublisher(),
                contextGraph.$entities.map { _ in () }.eraseToAnyPublisher()
            )
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.searchEngine.scheduleRebuild(dictations: self.history.entries,
                                                  meetings: self.meetingStore.meetings,
                                                  graph: self.contextGraph.snapshot())
            }
            .store(in: &searchIndexObservation)
        }

        // Mirror later history-retention changes into the store so shrinking the
        // window re-prunes without a relaunch. `.dropFirst()` skips the value
        // Combine replays on subscribe — the store already applied the persisted
        // retention at init, so reapplying it here would be a redundant prune+save.
        retentionObservation = settings.$historyRetentionDays
            .dropFirst()
            .sink { [weak self] days in self?.history.updateRetention(days: days) }

        // Open the main window on launch — onboarding/permissions are handled
        // inside the window now; just land on the Dashboard.
        openSettings(tab: .dashboard)

        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )

        #if TALKIE_DEV_TOOLS
        scheduleLaunchUpdateCheck()
        #endif
    }

    #if TALKIE_DEV_TOOLS
    /// Dev-tools flavor: a few seconds after launch, quietly check the GitHub dev
    /// channel and — if a newer build is published — offer to install it. Keeps a
    /// collaborator on the latest without ever opening Settings. Off the default
    /// public build entirely (the updater module isn't even linked there).
    private func scheduleLaunchUpdateCheck() {
        guard AppUpdater.shared.autoCheckOnLaunch else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await AppUpdater.shared.check(announce: true)
        }
    }
    #endif

    /// Clicking the Dock icon (with no window open) reopens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings(tab: .dashboard) }
        return true
    }

    /// Closing the window keeps Talkie running in the background for dictation.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Double-clicking a `.talkiepack` in Finder (or `open`-ing one) routes here.
    /// We open the Dictionary tab and hand each pack URL to the pane, which stages the
    /// same import preview the in-app Import button shows — a confirmed, non-destructive
    /// merge. Purely local: this reads a file the user chose; no network.
    func application(_ application: NSApplication, open urls: [URL]) {
        let packs = urls.filter { $0.pathExtension.lowercased() == TalkiePack.fileExtension }
        guard !packs.isEmpty else { return }
        openSettings(tab: .dictionary)
        for url in packs {
            NotificationCenter.default.post(name: .talkieOpenDictionaryPack, object: url)
        }
    }

    @objc private func appBecameActive() {
        permissions.refresh()
        // If Input Monitoring was just granted, the tap can now install. When the
        // grant is present but start() still fails (the TCC quirk where an existing
        // process can't create the tap until it relaunches), flag that so the UI can
        // offer a one-click relaunch instead of leaving a silent granted-but-dead state.
        let started = hotKey?.start() ?? false
        if started { updateStatusUI() }
        if permissions.inputMonitoring && !started {
            permissions.hotKeyNeedsRelaunch = true
        } else if started {
            permissions.hotKeyNeedsRelaunch = false
        }
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
        // One gesture for everyone: hold to talk, tap twice to lock hands-free.
        return String(format: "Hold %@ to talk · tap twice to lock".loc, settings.activationKey.displayName)
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

    private enum DictationEvent: Sendable { case begin, end, lock }
    private var eventTask: Task<Void, Never>?

    private func setupHotKey() {
        // Funnel press/release/lock edges through ONE ordered stream so a begin can
        // never be scheduled after its matching end (two independent Tasks have
        // no FIFO guarantee on the MainActor executor). The gesture machine lives in
        // HotKeyMonitor on the tap thread; it hands us already-decided begin/end/lock.
        let (stream, continuation) = AsyncStream<DictationEvent>.makeStream()
        eventTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .begin: self.beginDictation()
                case .end: self.endDictation()
                case .lock: self.lockDictation()
                }
            }
        }

        let config = HotKeyMonitor.Config(key: settings.activationKey)
        let monitor = HotKeyMonitor(
            config: config,
            onActivate: { continuation.yield(.begin) },
            onDeactivate: { continuation.yield(.end) },
            onLock: { continuation.yield(.lock) },
            onPasteLast: { [weak self] in
                Task { @MainActor in self?.pasteLastTranscript() }
            }
        )
        _ = monitor.start()
        hotKey = monitor
    }

    /// Register Talkie's two macOS Services ("Transcribe with Talkie", "Clean up
    /// with Talkie"). `NSApp.servicesProvider` is a WEAK reference, so we hold the
    /// provider in a stored property (`servicesProvider`) for the app's lifetime;
    /// without that it would deallocate and the services would silently stop
    /// responding. `NSUpdateDynamicServices()` prompts the Services system to
    /// re-read this process's registration now — the `NSServices` array in
    /// Info.plist is what actually advertises the items to other apps' menus (that
    /// requires LaunchServices to have re-registered the bundle, which
    /// `scripts/run.sh`'s `lsregister -f` handles on install).
    private func setupServices() {
        let provider = ServicesProvider()
        NSApp.servicesProvider = provider
        servicesProvider = provider
        NSUpdateDynamicServices()
    }

    /// A tap-tap locked recording hands-free. Recording is already running (it
    /// began on the first tap's key-down), so this only flips the presentation to
    /// the hands-free/locked look: a lock glyph in the pill, a lock earcon, and the
    /// bird's locked state. Guarded so a stray lock without a live session is inert.
    private func lockDictation() {
        guard isDictating, sessionLive else { return }
        handsFreeLocked = true
        hud.setHandsFreeLocked(true)
        Feedback.locked()
    }

    private func observeSettings() {
        // Re-bind the hotkey + sound prefs when settings change.
        settingsObservation = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .talkieSettingsChanged) {
                guard let self else { return }
                Feedback.enabled = self.settings.playSounds
                self.hotKey?.update(config: .init(key: self.settings.activationKey))
                self.updateStatusUI()

                // Show/hide the floating bird live when its toggle flips.
                if self.settings.showBirdBuddy { self.birdBuddy.show() }
                else { self.birdBuddy.hide() }

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

    /// The cleanup style the HUD switcher shows/cycles: the in-flight session's
    /// resolved style when a session is live (so the pill matches what gets used at
    /// stop), else the generic "other" category style.
    private var activeCleanupStyle: CleanupStyle {
        sessionProfile?.cleanupStyle ?? settings.cleanupStyle(for: .other)
    }

    /// Kick off a best-effort background warm-up of the on-device cleanup model,
    /// matching the Speech `warmUp` pattern. Skips entirely when the model isn't
    /// available or the style skips the model (`.off`), so a cold first dictation
    /// never pays the model load inline.
    private func prewarmCleanup(style: CleanupStyle) {
        guard CleanupEngine.isAvailable, style != .off else { return }
        Task { await cleanup.prewarm(style: style) }
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
        // over an active recording, nor while one is still finalizing (the
        // finalize pass is still using the shared engine/audio).
        guard meetingRecorder?.isRecording != true, meetingRecorder?.isFinishing != true else {
            hud.showError("Stop the meeting recording first.")
            return
        }

        // Stop watching the previous insertion for edits — this dictation is
        // taking over. (Learning now happens live, the instant you fix a word; see
        // `beginWatching` at insertion time, below.)
        learning.stopWatching()

        isDictating = true
        handsFreeLocked = false
        sessionLive = false
        sessionID += 1
        let myID = sessionID
        updateStatusUI()
        Feedback.start()
        // Acknowledge the press immediately — but the dot stays GRAY (arming) until
        // audio is genuinely flowing; only then does it turn red (recording).
        hud.showArming()
        birdBuddy.setActive(true)

        // Context awareness: capture who you're dictating into (always, for the
        // usage dashboard) and — when enabled — mine names worth spelling right.
        let captured = ContextCapture.capture(
            selfBundleID: AppPaths.bundleIdentifier,
            minePhrases: settings.contextAwareness
        )
        currentTarget = captured.target

        // A10 — scope filename snapping + repo terms to the checkout the terminal is
        // actually in. Resolve the project root behind the target: window-title path
        // first, then (for terminals whose title carries no path) the child shell's cwd
        // via `proc_pidinfo`. Prefer THAT root's scoped snapshot over the merged global
        // one. When the root is unknown or ambiguous, or it isn't indexed yet,
        // `snapshot(for:)` returns nil and we fall back to the merged snapshot — never a
        // wrong-repo scope. Only resolved when vibe coding is on and the target is an
        // editor/terminal; otherwise there's nothing to scope.
        var resolvedVibeRoot: URL?
        if settings.vibeCoding,
           captured.target.category == .coding || captured.target.category == .terminal {
            resolvedVibeRoot = ProjectRootDetector.resolveRoot(
                bundleID: captured.target.bundleID,
                windowTitle: captured.windowTitle,
                processID: captured.processID)
        }
        if settings.vibeCoding {
            if let root = resolvedVibeRoot, let scoped = projectIndex.snapshot(for: root) {
                currentVibeSnapshot = scoped
            } else {
                currentVibeSnapshot = projectIndex.snapshot
                // A10 index-on-first-sight: a resolved root we haven't indexed yet (e.g. a
                // worktree Jann just spun up) gets a background scan so a LATER dictation
                // scopes to it — this session safely uses the merged snapshot meanwhile.
                // Auto-scanned roots are session-visible but NOT persisted as pinned
                // folders (LRU-capped), so project_index.json doesn't accumulate every
                // directory visited. No-op if the root is already indexed or scanning.
                if let root = resolvedVibeRoot { projectIndex.indexRootOnFirstSight(root) }
            }
        } else {
            currentVibeSnapshot = .empty
        }

        // A9 — Vibe Coding turns itself on. When the feature is OFF and you're
        // dictating into an editor/terminal, try to discover the real git repo behind
        // the window title (or the shell's cwd for a bare terminal); if we find one that's
        // offer-worthy (never declined, not already offered today), stash it so a
        // successful insertion can surface the one-tap "Index 〈Repo〉 filenames?" offer.
        // The detector prefers a false negative over a false positive — a wrong-repo offer
        // would burn trust.
        pendingVibeOfferRoot = nil
        if !settings.vibeCoding,
           captured.target.category == .coding || captured.target.category == .terminal,
           let root = ProjectRootDetector.resolveRoot(
               bundleID: captured.target.bundleID, windowTitle: captured.windowTitle,
               processID: captured.processID),
           settings.mayOfferVibeIndexing(forRoot: root.path) {
            pendingVibeOfferRoot = root
        }

        // A11 — mine the identifiers of the file you're LOOKING AT. When vibe coding is
        // on and the editor's window title resolves to a file we've indexed, read that
        // file and pull its guard-safe identifiers so the corrector can rescue a spoken
        // symbol this session ("exercise filter" → `exerciseFilter`). The resolution (a
        // lookup in the already-consented project index) happens here on the main actor;
        // the READ + parse happen off-main at utility QoS so they can't delay arming. If
        // the mine isn't done by the time you release the key, `endDictation` simply skips
        // it — arming latency is never on the critical path. Privacy: `resolveIndexedFilePath`
        // only ever returns a file inside a folder the user picked for Vibe Coding.
        activeFileTermsGeneration += 1
        let mineGeneration = activeFileTermsGeneration
        sessionActiveFileTerms = []
        activeFileMineTask?.cancel()
        activeFileMineTask = nil
        if settings.vibeCoding,
           let filePath = projectIndex.resolveIndexedFilePath(forWindowTitle: captured.windowTitle,
                                                              root: resolvedVibeRoot) {
            activeFileMineTask = Task.detached(priority: .utility) { [weak self] in
                let terms = await FileIdentifierCache.shared.terms(forPath: filePath)
                if Task.isCancelled || terms.isEmpty { return }
                await MainActor.run {
                    guard let self, self.activeFileTermsGeneration == mineGeneration else { return }
                    self.sessionActiveFileTerms = terms
                }
            }
        }

        // Resolve the per-app rules for this app once, here on the main actor
        // (global → per-category → per-app merge, falling back to `settings.*`
        // for every unset field). Snapshotted so a mid-session profile edit
        // can't skew the in-flight session; carried into `endDictation` below.
        var profile = profiles.resolve(for: captured.target, settings: settings)

        // G9 — Prompt cleanup with agent-terminal auto-detection. When you're
        // dictating into a terminal that is running a coding agent (Claude Code,
        // Codex, aider — detected from the window title) and you have NOT set an
        // explicit per-app style for that terminal, reshape the ramble into a
        // prompt instead of inserting it faithfully. Zero settings: a per-app
        // override always wins (checked here), the category default is untouched
        // for every other terminal, and `.prompt` is also manually pickable.
        // We mutate the LOCAL `profile` BEFORE it is snapshotted into
        // `sessionProfile`/`sessionCleanup` and before prewarm, so the whole
        // session (prewarm, streaming cleanup, stop-time pass, accounting) sees
        // the promoted style. `windowTitle` is nil when context awareness is off
        // or the target is Talkie itself, so this silently no-ops to the resolved
        // style in those cases (acceptable; logged).
        let hasExplicitStyleOverride = captured.target.bundleID
            .flatMap { profiles.profile(for: $0)?.cleanupStyle } != nil
        if captured.target.category == .terminal,
           !hasExplicitStyleOverride,
           AgentTerminalDetector.isAgentSession(windowTitle: captured.windowTitle) {
            profile.cleanupStyle = .prompt
            talkieDebugLog("cleanup: agent terminal detected (title=\(captured.windowTitle ?? "nil")) → .prompt")
        }

        sessionProfile = profile

        // Bias the recognizer with the union of: custom vocabulary (narrowed by
        // this app's vocabulary filter, if any), on-screen names from the target
        // app, and (in vibe mode) your project's filenames.
        var bias = profiles.biasVocabulary(for: captured.target, dictionary: dictionary)
        bias.append(contentsOf: captured.phrases)
        if settings.vibeCoding { bias.append(contentsOf: currentVibeSnapshot.biasPhrases) }
        // Context graph: bias toward the people/projects/terms you actually use.
        bias.append(contentsOf: contextGraph.snapshot().biasPhrases())
        let phrases = Array(Set(bias)).prefix(180).map { $0 }
        let multiLang = settings.spokenLanguages.count > 1

        // Capture the cleanup style at the start so a mid-session settings change
        // can't skew the end-of-session accounting. Cleanup runs ONCE on the WHOLE
        // transcript at stop — so spoken self-corrections that span a pause
        // ("Thursday, no Friday") are resolved with full context — and is chunked
        // only when the transcript is genuinely long. Style is the whole cleanup
        // config now; `.off` means insert verbatim.
        let style = profile.cleanupStyle
        sessionCleanup = style

        // Warm the on-device cleanup model the moment recording starts, in
        // parallel with everything else, so the first cleanup at stop-time
        // doesn't pay a cold model load. Mirrors `engine.warmUp` for Speech.
        let cleanupEngine = self.cleanup
        let cleanupEnabled = style != .off
        if cleanupEnabled {
            Task { await cleanupEngine.prewarm(style: style) }
        }

        // Stream cleanup of each finalized segment *while you speak*, so the
        // stop-time pass only has to finish the last segment instead of the
        // whole transcript. Built only when cleanup is on and the model is
        // usable; otherwise the raw path is unchanged. `endDictation` consumes
        // (or, on the language-switch fallback, discards) this buffer.
        // Pin streamed cleanup to the session's baseline language (the streamed
        // path only survives when no language switch happens, so the baseline is
        // the right language for it) so the model can't translate it.
        let beginLangCode = LanguageDetector.languageCode(of: currentLocaleID)
        let cleanOne: @Sendable (String) async -> String? = { text in
            await cleanupEngine.clean(text, style: style, languageCode: beginLangCode)
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
                self.birdBuddy.setActive(false)
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
                    preferredDeviceUID: self.settings.preferredInputDeviceUID,
                    bufferAudio: multiLang,
                    onLevel: { [weak self] level in
                        Task { @MainActor in
                            AppDelegate.sharedHUD?.updateLevel(level)
                            self?.birdBuddy.updateLevel(level)
                        }
                    },
                    onCaptureFailed: { error in
                        // The active mic vanished mid-session and none remains. Route
                        // to the same error/HUD path as a start-time failure, ending
                        // the dictation cleanly instead of capturing silence.
                        Task { @MainActor [weak self] in
                            self?.handleCaptureFailure(error, sessionID: myID)
                        }
                    }
                )
                self.sessionLive = true
                self.recordingStartedAt = Date()
                // Capture is live — duck any playing music so it doesn't bleed into
                // the mic, then flip the pill to the red "recording" state. Resumed
                // on every teardown path in `endDictation`.
                if self.settings.pauseMusicWhileDictating {
                    self.musicController.pauseForDictation(
                        allowMediaKeyFallback: self.settings.pauseMusicMediaKeyFallback)
                }
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
                self.birdBuddy.setActive(false)
                self.hud.showError(error.localizedDescription)
                streaming?.cancel()
                await engine.cancelSession()
            }
        }
    }

    /// A live dictation's mic capture failed mid-session (the active input device
    /// changed and no usable mic remained). Tear the session down and surface the
    /// error on the same HUD path as a start-time failure. Ignored if the session
    /// has already moved on (`sessionID` advanced) or dictation already ended.
    func handleCaptureFailure(_ error: Error, sessionID: Int) {
        guard isDictating, self.sessionID == sessionID else { return }
        isDictating = false
        handsFreeLocked = false
        hud.setHandsFreeLocked(false)
        sessionLive = false
        recordingStartedAt = nil
        Feedback.stop()
        audio.stop()
        musicController.resumeAfterDictation()
        currentStreaming?.cancel()
        currentStreaming = nil
        Task { await engine.cancelSession() }
        isProcessing = false
        updateStatusUI()
        birdBuddy.setActive(false)
        hud.showError(error.localizedDescription)
    }

    func endDictation() {
        guard isDictating else { return }
        isDictating = false
        // The session is ending — clear the hands-free lock so the next pill doesn't
        // inherit a stale lock glyph (the pill moves to processing/insert below).
        let wasHandsFreeLocked = handsFreeLocked
        handsFreeLocked = false
        hud.setHandsFreeLocked(false)
        updateStatusUI()
        // Key released — mic stops, so the bird drops back to its calm idle look.
        birdBuddy.setActive(false)

        // If the session never actually went live (key released during async
        // setup), the begin task will see the generation change and abort — we
        // just reset the UI here.
        guard sessionLive else {
            currentStreaming?.cancel()
            currentStreaming = nil
            // No-op unless a race left music paused; keeps the invariant that music
            // is never left ducked when a session ends.
            musicController.resumeAfterDictation()
            hud.hide()
            return
        }
        sessionLive = false
        let duration = Date().timeIntervalSince(recordingStartedAt ?? Date())
        recordingStartedAt = nil
        // A "lone quick tap" is a session that was never locked hands-free and whose
        // live capture was shorter than the tap threshold — i.e. the user tapped once
        // (maybe not realizing it's hold-to-talk) rather than holding or tap-tapping.
        // Used only to decide whether to surface the one-time gesture hint when such a
        // tap yields nothing. Threshold matches the gesture machine's tap window.
        let wasLoneShortTap = !wasHandsFreeLocked && duration < ActivationGesture.tapThreshold

        Feedback.stop()
        audio.stop()
        // Recording's done (you've stopped talking) — bring the music back, even
        // though the transcript is still being polished/inserted below.
        musicController.resumeAfterDictation()
        isProcessing = true
        hud.showProcessing()

        let replacements = dictionary.replacementsSnapshot()
        // The jargon fed to the post-hoc niche corrector below: the hand-curated
        // Dictionary vocabulary UNIONED with the self-learned niche terms that have
        // graduated (confidence-boosted AND guard-safe). Snapshotted here on the main
        // actor — the corrector runs inside the endDictation Task off-main, and the
        // snapshot is Sendable. Deduped case-insensitively with the curated terms
        // winning (their exact spelling is authoritative). The self-learned union is
        // why coverage compounds silently: terms you actually say and confirm start
        // getting rescued without ever touching the Dictionary. The old
        // `contextualStrings` bias slot stays untouched — a proven no-op on this
        // stack, so post-hoc proofreading is the path that actually fires.
        var nicheTerms = dictionary.vocabulary
        do {
            var seen = Set(dictionary.vocabulary.map { $0.lowercased() })
            for term in nicheVocab.snapshot().correctorTerms(forNiche: NicheID.default.key, limit: 300)
            where seen.insert(term.lowercased()).inserted {
                nicheTerms.append(term)
            }
        }
        // The per-app rules resolved at session start (falls back to a fresh
        // resolve if a session somehow ends without a begin-side snapshot). For a
        // user with no per-app rules, `resolve` yields the category style + paste,
        // so this matches what the pipeline read before.
        let resolved = sessionProfile ?? profiles.resolve(for: currentTarget, settings: settings)
        sessionProfile = nil
        // Capitalization is a smart always-on default derived from the resolved
        // style/category (terminal/coding + faithful ⇒ no leading capital, so a
        // dictated shell command keeps its lowercase). Fillers are always stripped
        // deterministically UNLESS the AI already rewrote the text (handled at the
        // final `TextProcessor.apply` via `!aiHandledFillers`).
        let autoCap = resolved.autoCapitalize
        let removeFillers = true
        let mode = resolved.insertionMode
        let optimisticEnabled = settings.optimisticInsertion
        let spokenLanguages = settings.spokenLanguages
        let vibeOn = settings.vibeCoding
        let vibeSnapshot = currentVibeSnapshot
        // A11: identifiers of the file you're looking at, mined off-main since begin.
        // Snapshotted here on the main actor (a plain `[String]`, Sendable) so it can
        // ride into the processing Task. Empty when the mine didn't resolve/finish.
        let activeFileTerms = sessionActiveFileTerms
        // A11: when vibe coding is on, fold in the identifiers of the FILE ON SCREEN
        // ahead of the repo-wide terms — the symbol you're staring at is the one you're
        // most likely to speak, so it earns higher priority under the shared cap. Each
        // term already cleared A11's safety gates (4-letter floor, false-boost guard,
        // phonetic-common guard, and the leading-common-word gate) plus the ≤2-spoken-word
        // rescue window, so it can only rescue a close-sounding miss, never rewrite clean
        // prose (proven by the A11 false-positive corpus gate). Provenance order
        // end-to-end: dictionary > graduated niche > active-file > repo.
        if vibeOn {
            var seen = Set(nicheTerms.map { $0.lowercased() })
            for term in activeFileTerms where nicheTerms.count < 300 {
                if seen.insert(term.lowercased()).inserted { nicheTerms.append(term) }
            }
        }
        // A3: when vibe coding is on, also let THIS project's mined jargon (its
        // CLAUDE.md / README / docs + git branch & commit words) be rescued by the
        // niche corrector. Appended LAST — after the curated Dictionary, the
        // self-learned niche terms, and the active-file identifiers — so the provenance
        // order is authoritative-first (dictionary), proven-usage-second (niche),
        // active-file-third (A11), repo-context-last; and it shares A1's global 300-term
        // corrector cap so one repo's docs can't crowd out the terms you've actually
        // confirmed. Each repo term already cleared the false-boost guard + 4-letter
        // floor when the snapshot was built.
        if vibeOn {
            var seen = Set(nicheTerms.map { $0.lowercased() })
            for term in vibeSnapshot.correctorTerms where nicheTerms.count < 300 {
                if seen.insert(term.lowercased()).inserted { nicheTerms.append(term) }
            }
        }
        let target = currentTarget
        let selfBundle = AppPaths.bundleIdentifier
        // Reuse the cleanup style captured at session start, so a mid-session
        // change can't make the stats/filler accounting disagree with what the
        // assembler actually cleaned.
        let style = sessionCleanup ?? resolved.cleanupStyle
        sessionCleanup = nil
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
            // Dictation inserts text; it never builds a Meeting, so the per-segment
            // audio-clock timings (used by meetings/imports) are intentionally dropped.
            // `wordConfidences` (A12) rides back on the same finalize with no extra
            // pass — the low-confidence review chip below reads it; everything else
            // ignores it, so it costs the latency path nothing.
            let (raw, segments, _, wordConfidences) = await engine.finishSessionDetailed()
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
                let candidates = scored.map {
                    LanguageDetector.LanguageCandidate(localeID: $0.localeID, text: $0.text, confidence: $0.confidence)
                }
                let currentConf = candidates.first {
                    LanguageDetector.languageCode(of: $0.localeID) == currentCode
                }?.confidence ?? 0
                talkieDebugLog("decide: current=\(self.currentLocaleID)(\(String(format: "%.2f", currentConf))) scored=[\(scored.map { "\($0.localeID):\(String(format: "%.2f", $0.confidence))" }.joined(separator: ", "))]")
                // The switch decision — including the no-baseline absolute floor when
                // the current locale produced no scored entry — lives in a pure helper.
                if let best = LanguageDetector.switchTarget(among: candidates, currentCode: currentCode) {
                    finalRaw = best.text
                    languageSwitched = true
                    self.currentLocaleID = best.localeID
                    await self.engine.setLocaleIdentifier(best.localeID) // stick to it next time
                    talkieDebugLog("switched → \(best.localeID)")
                }
            }
            trace.stage("reTx")
            // Tell the cleanup model the (possibly switched) language so the
            // English-primary on-device model can't translate non-English speech.
            let cleanupLangCode = LanguageDetector.languageCode(of: self.currentLocaleID)

            // Cleanup. The fast path joins the segments that were already cleaned
            // live while you spoke — so we only wait on the last in-flight one.
            // We fall back to a fresh whole/batched pass only when streaming
            // wasn't running, or when a language switch re-wrote the transcript
            // (making the streamed work, which was for the original language,
            // stale). The whole pass also resolves self-corrections that span a
            // pause with full context; long transcripts split into sentence
            // batches (each within the model's context window).
            let cleanupEngine = self.cleanup
            let cleanupEnabled = style != .off

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
                   self.commandRouter.intent(for: interim,
                                              meetings: MeetingSnapshot(meetings: self.meetingStore.meetings),
                                              crossSurfaceEnabled: self.settings.crossSurfaceCommandsEnabled) == nil,
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
                    let cleanOne: @Sendable (String) async -> String? = { text in
                        await cleanupEngine.clean(text, style: style, languageCode: cleanupLangCode)
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

            // Post-hoc niche correction (the lever that replaced the no-op
            // `contextualStrings` biasing): proofread the cleaned transcript and swap
            // close-sounding misrecognitions of the user's saved vocabulary back to the
            // canonical spelling ("Higgs field" → "Higgsfield", "correlate" → "Coralate").
            // Recognizer-agnostic and deterministic; runs before the dictionary's exact
            // find-and-replace so those literal spellings still win on top.
            var nicheFixes: [String] = []
            // The canonical spellings the corrector swapped IN this session. Threaded
            // into the learn-from-edits watcher below so that if the user then corrects
            // one of them away, we record a rejection against the niche term — the
            // corrector fixed the wrong thing, and that term should demote.
            var nicheFixTargets: [String] = []
            if !nicheTerms.isEmpty {
                let corrected = NicheCorrector.correct(cleaned, terms: nicheTerms)
                cleaned = corrected.text
                nicheFixes = corrected.fixes.map(\.to)
                nicheFixTargets = nicheFixes
            }

            // Spoken numbers → digits (deterministic, runs in every cleanup mode):
            // version/decimal patterns always ("Seedance two point zero" → "Seedance
            // 2.0", "two point zero point one" → "2.0.1"); standalone cardinals only
            // when > 9 ("twenty four" → "24", "five" stays "five").
            cleaned = NumberNormalizer.normalize(cleaned)

            // Apply the dictionary AFTER the LLM so your exact spellings always win.
            // Strip fillers deterministically unless the AI already rewrote the text
            // (it removes fillers itself as part of the rewrite; double-stripping
            // would risk clipping a word the model reflowed).
            let processed = TextProcessor.apply(
                replacements: replacements,
                removeFillers: !aiHandledFillers,
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
                // A lone quick tap that captured nothing usually means the user tapped
                // instead of holding (or didn't know tap-tap locks). The first few
                // times that happens, teach the gesture in the pill instead of just
                // vanishing; after that, stay quiet (the counter caps it).
                if wasLoneShortTap, GestureHint.shouldShowEmptyTapHint() {
                    self.hud.showGestureHint()
                } else {
                    self.hud.hide()
                }
                return
            }

            // "Note this …" — file this dictation as a durable Markdown note in the
            // export destination instead of typing it into the frontmost app (D4).
            // Anchored to the utterance START (`triggerMatch` only fires on a
            // leading "note this"/"note that"), and gated on `optimistic == nil`
            // EXACTLY like the command branch below: with optimistic insertion on,
            // the interim text is already pasted into the target before we get here,
            // so intercepting would strand it — let those degrade to normal
            // dictation. The common (non-matching) path pays only one lowercased
            // `hasPrefix` check and adds no awaits, so normal stop-to-paste latency
            // is unchanged. A bare "note this" files the PREVIOUS dictation:
            // `history.add` for THIS utterance runs further below, so
            // `history.entries.first` here is still the prior entry.
            if optimistic == nil, let match = NoteComposers.triggerMatch(for: finalText) {
                let noteBody: String?
                switch match {
                case .body(let body):
                    noteBody = body
                case .previous:
                    // Bare trigger — export the previous dictation's text, if any.
                    noteBody = self.history.entries.first?.text
                }
                self.isProcessing = false
                guard let body = noteBody,
                      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    // Bare "note this" with no prior dictation to file — tell the
                    // user rather than silently typing "note this" into their doc.
                    self.hud.showError("Nothing to note yet — dictate something first.")
                    return
                }
                // Build the neutral note (pure) and resolve the destination on the
                // main actor (reads @Published prefs), then hand the blocking disk
                // write to a detached task with the same never-throw fallback the
                // meeting writer uses (Meeting.swift): the resolved destination,
                // then a second write to the default Talkie folder if it throws —
                // a note is never lost. Nothing is EVER injected into the target
                // app for this utterance.
                let note = NoteComposers.dictationNote(
                    text: body, target: target, date: Date(),
                    graph: self.contextGraph.snapshot()
                )
                let destination = ExportPreferences.shared.resolvedDestination()
                let savedMessage = String(format: "Saved to %@".loc, destination.displayName)
                Task.detached {
                    do {
                        _ = try await destination.write(note)
                    } catch {
                        do {
                            _ = try await TalkieFolderDestination().write(note)
                        } catch {
                            await MainActor.run { self.hud.showError("Couldn't save that note.") }
                            return
                        }
                    }
                    await MainActor.run { self.hud.showSaved(savedMessage) }
                }
                return
            }

            // Voice command mode (the on-device copilot): a leading-imperative over
            // a selection ("make this a list", "translate to German"), a
            // whole-utterance macro, or — behind `crossSurfaceCommandsEnabled`,
            // off by default — a cross-surface request over your meetings, runs
            // the command INSTEAD of inserting as dictation. Conservative: normal
            // speech falls straight through to the dictation path below.
            if optimistic == nil, let intent = self.commandRouter.intent(
                for: finalText,
                meetings: MeetingSnapshot(meetings: self.meetingStore.meetings),
                crossSurfaceEnabled: self.settings.crossSurfaceCommandsEnabled
            ) {
                var selection = intent.needsSelection ? AXSelection.selectedText() : nil
                // No live AX selection — the common case, since the natural voice
                // workflow is "dictate, pause, say a follow-up command" and nothing
                // is ever manually selected in that flow. Fall back to the most
                // recent dictation if it's still eligible (same app, recent) rather
                // than silently typing the command out literally.
                var usedImplicitFallback = false
                if intent.needsSelection, selection?.isEmpty != false, self.settings.implicitCommandTarget,
                   let fallback = ImplicitSelectionGate.eligible(
                       lastEntry: self.history.entries.first, now: Date(), currentTarget: target
                   ) {
                    selection = fallback.text
                    usedImplicitFallback = true
                }
                if !intent.needsSelection || (selection?.isEmpty == false) {
                    let ctx = CommandContext(
                        spokenCommand: finalText, selection: selection, target: target,
                        graph: self.contextGraph.snapshot(), summarizer: OnDeviceLLM()
                    )
                    if let result = await intent.run(ctx) {
                        self.isProcessing = false
                        if result.preview {
                            // Nothing is inserted until the user confirms in the pill.
                            let fallbackSource = selection
                            self.hud.showCommandPreview(
                                result.replacement,
                                replacing: usedImplicitFallback ? fallbackSource : nil,
                                onConfirm: {
                                    if usedImplicitFallback, let fallbackSource {
                                        // Actually replace the original dictated text —
                                        // reuses the exact same backward-select-and-paste
                                        // primitive optimistic-insertion already ships with.
                                        // Inserting fresh at the cursor instead would leave
                                        // the original prose in place AND append a redundant
                                        // rewrite elsewhere — not the feature working, a
                                        // different, confusing one.
                                        _ = TextInjector.replaceBackward(
                                            graphemeCount: fallbackSource.count,
                                            with: result.replacement, mode: mode
                                        )
                                    } else {
                                        _ = TextInjector.insert(result.replacement, mode: mode)
                                    }
                                },
                                onUndo: { [weak self] in self?.hud.hide() }
                            )
                        } else {
                            _ = TextInjector.insert(result.replacement, mode: mode)
                            self.hud.hide()
                        }
                        return
                    } else {
                        // The command matched but the on-device model produced nothing
                        // (unavailable, or it refused). Surface it and STOP — never fall
                        // through to the dictation path below, which would type the literal
                        // spoken command ("translate to German") into the document.
                        self.isProcessing = false
                        self.hud.showError("Couldn't run that command — the on-device model may be unavailable.")
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
            // Niche corrections are dictionary fixes too — surface them in the HUD.
            for word in nicheFixes where !replacedWords.contains(word) {
                replacedWords.append(word)
            }

            // Log it (copyable in the History tab) + lifetime stats + fix tally,
            // even if insertion fell back to the clipboard. Share ONE id with the
            // context-graph provenance below so the two stores agree on "which
            // dictation was this" — the graph's dedup-by-(source, sourceID) can
            // only work if live ingestion gives it a real, stable id instead of a
            // universal `nil` that made every live-dictation mention on a given
            // entity look like a re-run of the exact same source forever after
            // the first, and (separately, from the same root cause) let stale
            // pre-fix data accumulate literal duplicate provenance entries.
            let dictationID = UUID()
            let words = WordCounter.count(finalText)
            self.history.add(
                finalText, wordCount: words, durationSec: duration,
                appName: target.name, appCategory: target.category.rawValue,
                bundleID: target.bundleID,
                id: dictationID
            )
            self.stats.record(words: words, durationSec: duration)
            self.stats.recordFixes(
                dictionary: processed.replacementHits + biasApplied.count + nicheFixes.count + fileFixes,
                fillers: processed.fillersRemoved,
                aiWords: aiWordsChanged
            )
            // Per-day activity (streak + heatmap) and where your words went.
            self.activity.record(words: words)
            // L4: fold this dictation into the lifetime word/phrase frequency store.
            self.wordFreq.record(text: finalText)
            if target.bundleID != selfBundle {
                self.appUsage.record(target: target, words: words)
            }
            // Feed the on-device context graph from what was just dictated.
            let nowUnix = Date().timeIntervalSince1970
            self.contextGraph.ingest(
                ContextGraphExtractor.candidates(from: finalText),
                provenance: Provenance(source: .dictation, sourceID: dictationID.uuidString,
                                       dateUnix: nowUnix,
                                       snippet: String(finalText.prefix(120)))
            )
            // Harvest niche-vocabulary candidates from the same transcript — proper
            // nouns, identifiers, filenames — as a frequency signal (batched once per
            // session, per the store's contract). These start as tracked candidates
            // and only graduate into the corrector after enough repetition; nothing
            // here injects on a single sighting. Shares the dictation id so provenance
            // ("why is this term here?") points back to the exact entry.
            let harvested = PhraseMiner.mine(from: [finalText])
            if !harvested.isEmpty {
                self.nicheVocab.ingest(
                    harvested,
                    provenance: Provenance(source: .dictation, sourceID: dictationID.uuidString,
                                           dateUnix: nowUnix,
                                           snippet: String(finalText.prefix(120)))
                )
            }

            // A12 — low-confidence review gate (pure). Decide, from the per-word
            // confidences the recognizer already produced, whether it was visibly
            // unsure about a small number of jargon-like words. Suppress any word the
            // niche corrector already fixed this session (`nicheFixTargets`) — the
            // correction path already did its job. This is a pure array read; the
            // chip itself is only surfaced on the `.inserted` path below, queued
            // behind any learned/copy pill. Nothing here changes the transcript or
            // the insertion, so stop-to-paste latency is untouched.
            let reviewFlagged = ConfidenceGate.evaluate(
                wordConfidences: wordConfidences,
                alreadyFixed: nicheFixTargets
            ).flaggedWords

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
            // L3a: persist this dictation's software latency (numeric only — no
            // transcript text). Reads the trace's already-accumulated stages; adds
            // no work to the recognition/cleanup path. Skipped for the `.empty`
            // outcome (nothing landed); `finalText` is non-empty here (guarded
            // above), so `chars` > 0. Exactly one record per launch is `coldStart`.
            if case .empty = outcome {
                // nothing inserted — don't record a latency sample
            } else {
                let report = trace.report
                func stageMs(_ name: String) -> Double {
                    report.stages.first { $0.name == name }?.ms ?? 0
                }
                let outcomeLabel: String
                switch outcome {
                case .inserted: outcomeLabel = "inserted"
                case .leftOnClipboard: outcomeLabel = "leftOnClipboard"
                case .empty: outcomeLabel = "empty"
                }
                let isColdStart = !self.didRecordLatencyThisLaunch
                self.didRecordLatencyThisLaunch = true
                self.latency.record(
                    totalMs: report.totalMs,
                    finalizeMs: stageMs("finalize"),
                    reTxMs: stageMs("reTx"),
                    cleanupMs: stageMs("cleanup"),
                    insertMs: stageMs("insert"),
                    chars: finalText.count,
                    streamed: usedStreaming,
                    optimistic: optimistic != nil,
                    coldStart: isColdStart,
                    mode: mode.rawValue,
                    outcome: outcomeLabel
                )
            }
            switch outcome {
            case .inserted:
                Feedback.done()
                self.hud.showInserting(replacedWords: replacedWords)
                self.hud.hide(after: replacedWords.isEmpty ? 0.4 : 1.4)
                // Self-healing insertion (B2): a paste that returned `.inserted` did so
                // optimistically — the ⌘V may never have landed (some apps swallow it).
                // When the resolved mode was paste, ask the verifier whether our text
                // actually made it into the focused field; if it verifiably did NOT,
                // silently re-insert by typing and remember `.type` for this app so it
                // fails at most once. The HUD stays on `.inserting` throughout — the
                // healing is invisible. Guard rails (never fire when the caret is no
                // longer trustworthy or a retry can't help): only for a plain paste
                // (`mode == .paste`, so `.type` sessions are out), never after the
                // optimistic replace-backward swap, and only when we know which app to
                // remember the fix for (`target.bundleID != nil`). One retry max — this
                // is a straight-line path, no loop. `.leftOnClipboard`/`.empty` never
                // reach here. Verification runs to completion BEFORE the learn-watcher
                // below starts, so the two never poll Accessibility concurrently.
                if mode == .paste, optimistic == nil, let healBundleID = target.bundleID {
                    // Privacy: the verifier reads the focused field's value via
                    // Accessibility ONLY to check whether the exact text Talkie just
                    // inserted is present. It compares against our own `finalText` and
                    // never stores or forwards what it read.
                    let verdict = await InsertionVerifier.verify(inserted: finalText)
                    if verdict == .notLanded {
                        talkieDebugLog("heal: paste did not land in \(target.name) — retrying by typing, learning .type")
                        // Fire-and-forget type retry (its per-character loop runs off
                        // the main actor inside TextInjector); verifying the retry is
                        // out of scope — the goal is to get the text in, then remember.
                        _ = TextInjector.insert(finalText, mode: .type)
                        // Persist the learned winner: read-modify-write the app's
                        // existing sheet so unrelated overrides (cleanup, vocabulary…)
                        // are preserved; refresh the display name while we're here.
                        var learned = self.profiles.profile(for: healBundleID)
                            ?? AppProfile(bundleID: healBundleID, displayName: target.name)
                        learned.displayName = target.name
                        learned.insertionMode = .type
                        self.profiles.upsert(learned)
                    }
                }
                // Watch the field for the next few seconds: the instant the user
                // fixes a word Talkie misrecognized, add it to the dictionary and
                // ping them with an Undo (WhisperFlow-style live learning).
                if self.settings.learnFromEdits {
                    let fixTargets = nicheFixTargets
                    // Shared per-insertion latch: the AX watcher and the Claude Code
                    // scan run side by side (the scan only matters where the watcher
                    // is blind), so whichever learns first flips this and the other
                    // stands down — no double rule, no double ping.
                    let learnedOnce = LearnOnceFlag()
                    self.learning.beginWatching(inserted: finalText) { [weak self] from, to in
                        guard let self else { return }
                        if self.applyLearnedCorrection(
                            from: from, to: to, dictationID: dictationID,
                            snippet: String(finalText.prefix(120)), fixTargets: fixTargets
                        ) {
                            learnedOnce.value = true
                        }
                    }
                    // Cure the AX-blind spot: when we dictated into a coding/terminal
                    // surface (Claude Code in Terminal/iTerm/Warp or a VS Code/Cursor
                    // integrated terminal), the field watcher above learns nothing —
                    // schedule the opportunistic transcript scan instead. Gated behind
                    // the same `learnFromEdits` toggle AND its own one-time consent.
                    if target.category == .terminal || target.category == .coding {
                        self.claudeLearner.scheduleScan(
                            inserted: finalText,
                            insertionUnix: Date().timeIntervalSince1970,
                            alreadyLearned: { learnedOnce.value },
                            offerConsent: { [weak self] in self?.offerClaudeTranscriptConsent() },
                            onLearned: { [weak self] from, to in
                                guard let self else { return }
                                _ = self.applyLearnedCorrection(
                                    from: from, to: to, dictationID: dictationID,
                                    snippet: String(finalText.prefix(120)), fixTargets: fixTargets,
                                    source: .claudeCode
                                )
                            }
                        )
                    }
                }
                // A9 — offer to turn on Vibe Coding for the repo we discovered at
                // session start (if any). Queued behind the insertion/learning pills
                // so it never collides with them; a no-op when there's nothing to
                // offer or the throttle/decline gates say no.
                self.maybeOfferVibeIndexing()
                // A12 — if the recognizer was visibly unsure about a word or two,
                // offer the tap-to-fix review chip. Queued behind everything else on
                // the single-phase HUD: it waits out the brief insert/learn pings,
                // then shows ONLY if nothing interactive is on screen (a learned pill,
                // copy prompt, command preview, or the Vibe offer above all suppress
                // it) — a nagging chip is worse than none. Works with no AX at all:
                // it's driven purely by the confidence numbers, so it fires the same
                // when dictating into Claude/Electron where the edit-watcher is blind.
                self.maybeOfferLowConfidenceReview(reviewFlagged)
            case .leftOnClipboard(let reason):
                Feedback.notPasted()
                // Couldn't paste — the text is on the clipboard; offer a tap to
                // (re)copy it, plus the ⌥⌘V re-paste shortcut once a field is focused.
                //
                // L2-a rescue: a transcript left on the clipboard is one keystroke away
                // from being lost (the next copy overwrites it). So ALSO drop it into
                // the Scratchpad, tagged with this dictation's id so a later history
                // delete purges it too, and tell the user via a suffix on the pill.
                // STRICT exclusion: if secure input is on, this was a password field —
                // never persist it anywhere; leave it clipboard-only as before.
                var message = reason
                if !TextInjector.isSecureInputActive {
                    self.scratchpad.addLine(finalText, sourceDictationID: dictationID.uuidString)
                    message = reason + " · saved to your Scratchpad".loc
                }
                self.hud.showCopyPrompt(
                    text: finalText, message: message,
                    shortcut: self.settings.pasteLastShortcutEnabled ? self.pasteLastShortcutDisplay : nil
                )
            case .empty:
                self.hud.hide()
            }
        }
    }

    // MARK: Learn-from-edits (shared by the AX watcher and the Claude Code scan)

    /// Where a learned correction came from — only affects the HUD wording, so the
    /// user knows we read their Claude Code prompt (vs. watched the field).
    enum LearnSource { case fieldEdit, claudeCode }

    /// Apply one from→to correction the SAME way regardless of how it was detected:
    /// record any niche rejection, add the dictionary rule, log the confirm signal,
    /// and ping with an Undo that reverses all of it. Returns whether a new rule was
    /// actually added (false if it was already known) so the caller can latch "learned"
    /// and stop a second path from re-learning the identical fix.
    @discardableResult
    private func applyLearnedCorrection(
        from: String, to: String, dictationID: UUID, snippet: String,
        fixTargets: [String], source: LearnSource = .fieldEdit
    ) -> Bool {
        // Reject signal: the user corrected AWAY from a spelling the niche corrector
        // swapped in this session — it fixed the wrong thing, so demote that term.
        // Checked before the dictionary guard so a rejection lands even with no new
        // rule to add.
        if let rejected = fixTargets.first(where: { $0.lowercased() == from.lowercased() }) {
            self.nicheVocab.recordRejection(rejected)
        }
        guard self.dictionary.addLearnedReplacement(from: from, to: to) else { return false }
        // Confirm signal: the user explicitly typed `to` over Talkie's output — the
        // strongest evidence this spelling is real jargon. Graduates the niche term.
        self.nicheVocab.recordUserConfirmed(
            to,
            provenance: Provenance(source: .dictation, sourceID: dictationID.uuidString,
                                   dateUnix: Date().timeIntervalSince1970, snippet: snippet)
        )
        let message: String
        switch source {
        case .fieldEdit:
            message = "Added “\(to)” to dictionary"
        case .claudeCode:
            message = String(format: "Added “%@” — from your Claude Code prompt".loc, to)
        }
        self.hud.showLearned(message) { [weak self] in
            guard let self else { return }
            self.dictionary.removeLearnedReplacement(from: from, to: to)
            // Undoing the learn demotes the term too: the user rejected the whole
            // learn, not just the dictionary rule.
            self.nicheVocab.recordRejection(to)
            self.hud.showReverted()
        }
        return true
    }

    /// The one-time offer to learn from Claude Code prompts. Reuses the command-preview
    /// pill (a genuine two-choice decision, no auto-dismiss): "Insert" accepts, "Undo"
    /// declines — and the choice sticks forever. No scan runs on this insertion; the
    /// offer IS the interaction, and future eligible insertions scan once granted.
    private func offerClaudeTranscriptConsent() {
        hud.showCommandPreview(
            "Learn corrections from your Claude Code prompts? They’re local files; nothing leaves your Mac.".loc,
            onConfirm: { [weak self] in self?.claudeLearner.resolveConsent(granted: true) },
            onUndo: { [weak self] in
                self?.claudeLearner.resolveConsent(granted: false)
                self?.hud.hide()
            }
        )
    }

    // MARK: Vibe Coding in-context offer (A9)

    /// After a successful dictation into an editor/terminal, surface the one-tap
    /// "Index 〈Repo〉 filenames?" offer for the repo discovered at session start —
    /// so the flagship dev feature stops being invisible. Consumes the stashed root
    /// once. Re-checks the gates (state may have changed between begin and now), holds
    /// back while another pill is up, and lets the brief insert/learn pills settle
    /// before appearing (queue phases). Accept turns Vibe Coding on and indexes the
    /// repo; decline remembers this root so it's never offered again.
    private func maybeOfferVibeIndexing() {
        guard let root = pendingVibeOfferRoot else { return }
        pendingVibeOfferRoot = nil
        let rootPath = root.path
        // Re-check the throttle/decline/enabled gates on the freshest state.
        guard settings.mayOfferVibeIndexing(forRoot: rootPath) else { return }
        // The repo name shown in the pill (the folder's own name, e.g. "Talkie").
        let repo = root.lastPathComponent
        guard !repo.isEmpty else { return }

        // Let the insertion pill (and any just-fired learned ping) breathe first, then
        // offer — but only if nothing interactive is on screen and vibe coding is
        // still off. If a learned ping is up, we simply don't nag this time (we've not
        // burned the once-a-day budget, so a later dictation can still offer).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !self.settings.vibeCoding,
                  !self.isDictating, !self.isProcessing,
                  !self.hud.isPresentingInteractivePill,
                  self.settings.mayOfferVibeIndexing(forRoot: rootPath) else { return }
            self.settings.noteVibeOfferShown()
            self.hud.showVibeOffer(
                repo: repo,
                onAccept: { [weak self] in
                    guard let self else { return }
                    self.settings.vibeCoding = true
                    self.projectIndex.addFolders([root])
                    self.hud.showSaved(String(format: "Indexing %@ — spoken filenames will snap to real files".loc, repo))
                },
                onDecline: { [weak self] in
                    guard let self else { return }
                    // Sticky per root: never offer this repo again.
                    self.settings.declineVibeRoot(rootPath)
                    self.hud.hide()
                }
            )
        }
    }

    // MARK: A12 — low-confidence review chip (learning inside Talkie's own UI)

    /// Offer the tap-to-fix review chip for the words the recognizer was visibly
    /// unsure about (`flagged`, already gated + capped by `ConfidenceGate`). This is
    /// the in-app learning path that works with NO Accessibility dependence: it's
    /// driven purely by the confidence numbers, so it fires identically when
    /// dictating into Claude/Electron where the edit-watcher is blind.
    ///
    /// Single-phase HUD queue: like the A9 Vibe offer, let the brief insert/learn
    /// pings settle first, then show ONLY if nothing interactive is on the notch
    /// (a learned pill, copy prompt, command preview, or a Vibe offer all suppress
    /// it) and no new capture has started. A nagging chip is worse than none, so
    /// every gate here fails safe toward NOT showing it. Ignoring the chip records
    /// nothing; tapping Fix opens the correction popover.
    private func maybeOfferLowConfidenceReview(_ flagged: [String]) {
        guard !flagged.isEmpty else { return }
        Task { @MainActor in
            // Let the insert/learn pings breathe (the learned pill fires from the
            // edit-watcher up to a few seconds out) before claiming the notch.
            try? await Task.sleep(for: .seconds(1.8))
            guard !self.isDictating, !self.isProcessing,
                  !self.hud.isPresentingInteractivePill else { return }
            self.hud.showReviewChip(words: flagged) { [weak self] heardWord in
                guard let self else { return }
                // Tapping Fix opens the correction popover prefilled with the heard
                // word. On commit we teach the dictionary (so a close-miss is fixed
                // next time) AND record the confirmation against the niche store —
                // the same pair the edit-watcher's `applyLearnedCorrection` records,
                // reused here so the two learning paths stay consistent.
                self.hud.presentCorrectionPopover(heardWord: heardWord) { [weak self] fixed in
                    guard let self else { return }
                    self.learnFromReviewChip(heardWord: heardWord, fixed: fixed)
                }
            }
        }
    }

    /// Commit one review-chip correction: add the learned dictionary rule
    /// (`heardWord` → `fixed`) and, when a new rule was actually added, record the
    /// niche confirmation for `fixed` — mirroring `applyLearnedCorrection` (which
    /// the AX/Claude paths use) so all three in-app learning routes agree. Pings a
    /// brief confirmation. NEVER edits the text already inserted — this is purely
    /// "learned for next time." Records nothing on an empty/no-op fix (the popover
    /// already guards that).
    private func learnFromReviewChip(heardWord: String, fixed: String) {
        guard self.dictionary.addLearnedReplacement(from: heardWord, to: fixed) else {
            // Already known (or a no-op) — still confirm to the user without a
            // duplicate rule or a second niche signal.
            self.hud.showLearned(String(format: "Already learning \u{201c}%@\u{201d}".loc, fixed)) { [weak self] in
                self?.hud.hide()
            }
            return
        }
        // The user explicitly typed `fixed` over what Talkie heard — the strongest
        // evidence it's real jargon. Graduate the niche term (live post-A1).
        self.nicheVocab.recordUserConfirmed(
            fixed,
            provenance: Provenance(source: .dictation, sourceID: nil,
                                   dateUnix: Date().timeIntervalSince1970,
                                   snippet: nil)
        )
        // Ping with an Undo that reverses both the rule and the niche signal —
        // same undo contract as the edit-watcher's learned ping.
        self.hud.showLearned(String(format: "Added \u{201c}%@\u{201d} to dictionary".loc, fixed)) { [weak self] in
            guard let self else { return }
            self.dictionary.removeLearnedReplacement(from: heardWord, to: fixed)
            self.nicheVocab.recordRejection(fixed)
            self.hud.showReverted()
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
        // Resolve the FRONTMOST app's insertion mode (the global picker is gone as of
        // B2). `minePhrases: false` — we only need the target's bundle id/category to
        // honor a learned/user-set per-app rule, not the costlier context mining.
        let target = ContextCapture.capture(selfBundleID: AppPaths.bundleIdentifier, minePhrases: false).target
        let mode = profiles.resolve(for: target, settings: settings).insertionMode
        switch TextInjector.insert(text, mode: mode) {
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
                wordFreq: wordFreq,
                scratchpad: scratchpad,
                projectIndex: projectIndex,
                contextSummary: contextSummary,
                meetingRecorder: meetingRecorder,
                meetingStore: meetingStore,
                contextGraph: contextGraph,
                macros: macros,
                profiles: profiles,
                searchEngine: searchEngine,
                nicheVocab: nicheVocab,
                commandRouter: commandRouter,
                hud: hud,
                onRetryHotKey: { [weak self] in self?.hotKey?.start() ?? false }
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

    // MARK: App Intents accessor

    /// Toggle dictation from an App Intent (Shortcuts / Spotlight / Raycast).
    /// `isDictating` is `private`, so a new `Intents/` file can't read it to
    /// decide begin-vs-end; this one internal method keeps that decision here,
    /// where the flag lives, and mirrors a hotkey press. Never activates Talkie
    /// — dictation targets the frontmost app (see `ToggleDictationIntent`).
    func toggleDictationFromIntent() {
        if isDictating {
            endDictation()
        } else {
            beginDictation()
        }
    }

    /// Toggle meeting recording from an App Intent (Shortcuts / Spotlight /
    /// Raycast). `meetingRecorder` is `private`, so a new `Intents/` file can't
    /// reach it to decide start-vs-stop; this one internal method keeps that
    /// decision here, next to the recorder it owns, mirroring
    /// `toggleDictationFromIntent()`. Never activates Talkie — the meeting pill
    /// and system-audio capture run off-screen, same as dictation.
    ///
    /// `start()` returns `false` when it refuses (mic denied, speech
    /// unavailable, a meeting/dictation already in flight); we translate that
    /// into a thrown error so Shortcuts shows the user *why* nothing happened
    /// instead of reporting a silent success. `stop()` is fire-and-forget from
    /// the intent's point of view — it always ends the session.
    func toggleMeetingRecordingFromIntent() async throws {
        if meetingRecorder.isRecording {
            await meetingRecorder.stop()
        } else {
            let started = await meetingRecorder.start()
            if !started {
                throw TalkieIntentError.meetingCouldNotStart
            }
        }
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
