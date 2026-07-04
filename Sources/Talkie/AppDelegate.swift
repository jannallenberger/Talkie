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
    /// L5-b: the on-device *invented* job title for the Milestones page. Owned here
    /// (not by the view) so its cache and generation state survive navigation. Its
    /// inputs are content-derived (vocabulary + app usage), so it joins the
    /// true-delete cascade — `MemoryView`'s "Clear everything" wipes `job_title.json`.
    let jobTitle = JobTitleStore()
    /// L3a: rolling per-dictation software-latency record (last 50, numeric only —
    /// no transcript text). Populated from the post-release `ProcessingTrace`; the
    /// UI is L3b, so nothing consumes it in a view yet — it just accumulates.
    let latency = LatencyStore()
    /// L3b: session-scoped memory-pressure observer. Started at launch; read by the
    /// Dictation Speed detail page's environment diagnostics (a row appears only
    /// after the OS has actually signalled pressure this session). Stores nothing.
    let systemPressure = SystemPressure()
    /// L2-a: the dashboard Scratchpad (notes + tasks). Also the rescue sink for
    /// transcripts that couldn't be pasted — see the `.leftOnClipboard` branch, where
    /// a NON-secure-input failure appends the transcript here instead of leaving it
    /// only on the clipboard to be lost on the next copy.
    let scratchpad = ScratchpadStore()
    /// L7: the user's optional profile picture (`profile.png` in Application Support).
    /// Photo-only and opt-in — no default avatar. Shown in-app on the dashboard header
    /// and meeting rows; never written into exports. Its `clear()` joins the
    /// "Clear everything" cascade in `MemoryView`.
    let profileImage = ProfileImageStore()
    /// L2-b (LOG-ONLY / PREVIEW): a calibration log of what the "added by Chirp"
    /// auto-add gate WOULD do for each extracted commitment. It writes ONLY to its own
    /// `scratchpad_ai_preview.json` — never to the Scratchpad, never to the UI — so
    /// Jann can tune the gate threshold from real logs before the live auto-add lane
    /// ships. Content-derived, so it joins the true-delete cascade in `MemoryView`.
    let autoAddPreviewLog = AutoAddPreviewLog()
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
    /// Watches one user-picked folder (D6) and auto-transcribes any audio/video file that
    /// lands there into a meeting, moving the original into a `Transcribed/` subfolder — all
    /// local file I/O, zero network. OFF until the user picks a folder (never seeded). Built
    /// in `applicationDidFinishLaunching` after `fileImporter`, whose queue it feeds.
    private var inboxWatcher: InboxWatcher!
    /// Re-arms `inboxWatcher` when the watched-folder preference changes (pick / clear in
    /// the Meetings settings row), so turning it on/off takes effect without a relaunch.
    private var inboxWatchObservation: AnyCancellable?
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

    /// The id of the last real (non-try-it, stored) dictation whose insertion actually
    /// landed via paste (`.inserted`), or nil when the most recent dictation was left
    /// on the clipboard / empty / not stored. B9's in-place voice edits ("scratch
    /// that", "replace X with Y") gate on this: `replaceBackward` / `deleteBackward`
    /// select-and-paste at the caret, which is only meaningful when the text is really
    /// in the field — so if the last insertion fell back to the clipboard
    /// (`leftOnClipboard`), the edit must NOT run and the phrase inserts literally.
    /// Compared against `history.entries.first?.id` at the dispatch site so a scratch
    /// only fires when the freshest entry is also the one that landed.
    private var lastInsertedDictationID: UUID?
    /// Bumped on every begin; lets an in-flight async setup detect that the
    /// user already released the key (or started a newer session) and bail.
    private var sessionID = 0
    /// True only once audio is actually flowing into a live analyzer session.
    private var sessionLive = false

    // MARK: Onboarding try-it sink (H5)

    /// When set, a dictation is a SEALED, side-effect-free "try it" run for the
    /// speak-first onboarding step: the normal engine + cleanup pipeline runs and
    /// the styled final text is delivered HERE instead of to the frontmost app.
    /// A try-it session must never touch the clipboard, paste/inject, route a
    /// command, start learning, or land in History / stats / graph / dashboard —
    /// `endDictation` checks this and short-circuits before any of that. Set by
    /// `toggleTryItDictation`, cleared on EVERY completion/failure/teardown path
    /// (guarded by the session-id pattern so a stale sink can never fire into a
    /// later, normal dictation). This is a Private-app-grade guarantee: the sink
    /// is the only place a try-it's words go, and it can't leak into a real session.
    private var dictationSink: ((String) -> Void)?
    /// Streams the live (interim) transcript to the onboarding field while you
    /// speak, so words appear as you talk. Fed from `setupEngineHandler` alongside
    /// the HUD's own live update. Cleared together with `dictationSink`.
    private var dictationInterimSink: ((String) -> Void)?
    /// Lifecycle reset for the try-it UI: invoked once when a try-it session ends
    /// for ANY reason (final text delivered, mic declined, capture failure, an
    /// abandoned/never-live session). Carries no content — it exists only so the
    /// onboarding record button can flip back to its idle state, since the failure
    /// teardown paths live in `beginDictation`/`handleCaptureFailure`, not just in
    /// the successful `endDictation` finish. Set and cleared with the two sinks.
    private var dictationTryItEnded: (() -> Void)?

    /// True while a try-it sink is installed. The one predicate `endDictation` and
    /// the teardown paths read, so "is this a sealed onboarding run?" has a single
    /// source of truth.
    private var isTryItDictation: Bool { dictationSink != nil }

    /// Clear the try-it sinks and fire the one-shot end callback. Every teardown
    /// path (success, mic-declined, capture failure, abandoned session) funnels
    /// through here so the sink can never survive into the next dictation and the
    /// onboarding button is always reset exactly once.
    private func clearTryItSinks() {
        let ended = dictationTryItEnded
        dictationSink = nil
        dictationInterimSink = nil
        dictationTryItEnded = nil
        micDeclinedTryItError = nil
        ended?()
    }

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
    /// H3 — a style the user picked via the in-pill switcher DURING this dictation,
    /// scoped to just this dictation (the switcher's tooltip promise). `nil` unless
    /// they cycled it this session. When set, it (a) is mirrored into the in-flight
    /// `sessionCleanup` + re-prewarmed so the stop-time pass actually uses it, and
    /// (b) drives the post-insert "Keep for {App}?" chip — the ONLY thing that makes
    /// the change persist. Cleared on every teardown path so it never leaks into the
    /// next session, and NEVER written to `appCleanupStyles` on cycle.
    private var sessionStyleOverride: CleanupStyle?
    /// The per-app rules resolved for the target app at the START of the session
    /// (global → per-category → per-app merge). Snapshotted once so a mid-session
    /// profile edit can't skew the in-flight session; `Sendable`, so it can ride
    /// into the `endDictation` processing Task. `nil` between sessions.
    private var sessionProfile: ResolvedProfile?
    /// L2-b (LOG-ONLY): the frontmost app as `AutoAddGate` needs to see it, captured
    /// at session start so the end-of-session commitment gate runs against the same
    /// target the dictation actually went into. `nil` when context awareness is off —
    /// the gate then fails closed (no suggestion), but the attempt is still logged so
    /// the fail-closed rate is visible in the calibration data. Sendable, so it rides
    /// into the `endDictation` processing Task alongside `sessionProfile`.
    private var sessionFrontApp: AutoAddGate.FrontApp?
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

        // L3b: begin watching for memory-pressure events so the speed diagnostics can
        // surface a row only if the OS actually reports pressure this session.
        systemPressure.start()

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

        // Watched-inbox folder (D6): auto-transcribe audio/video that lands in a folder the
        // user picks. Feeds the same `fileImporter` queue (so the same model-exclusivity
        // and dedup apply). Armed from the persisted preference — which defaults to OFF (no
        // seeded path) — and re-armed whenever that preference changes.
        inboxWatcher = InboxWatcher(coordinator: fileImporter, meetingStore: meetingStore)
        inboxWatcher.syncFromPreferences()
        inboxWatchObservation = InboxWatchPreferences.shared.$folderPath
            .removeDuplicates()
            .sink { [weak self] _ in self?.inboxWatcher?.syncFromPreferences() }

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

        // HUD cleanup-style switcher (feature 14 + H3): show + cycle the active
        // *style* in-pill. The label reflects the style that will ACTUALLY be used at
        // stop — the session-scoped override if the user cycled it this dictation,
        // else the in-flight snapshot, else the resolved default — so the pill never
        // lies. Cycling is SESSION-SCOPED (H3): it changes only THIS dictation, exactly
        // as the switcher's tooltip promises. It sets `sessionStyleOverride` and mirrors
        // the new style into the in-flight `sessionCleanup` (+ re-prewarms) so the
        // stop-time cleanup pass uses it — and writes NOTHING to `appCleanupStyles`.
        // A change persists only if the user later taps the post-insert "Keep for
        // {App}?" chip. When no session is live (rare — the switcher is a capture-phase
        // control) fall back to the "other" category so the label is never empty.
        hud.bindCleanupSwitcher(
            label: { [weak self] in
                guard let self else { return nil }
                return self.effectiveSessionStyle.displayName
            },
            cycle: { [weak self] in
                guard let self else { return }
                let all = CleanupStyle.allCases
                let current = self.effectiveSessionStyle
                let next = all.firstIndex(of: current).map { all[($0 + 1) % all.count] } ?? all[0]
                // Scope the change to THIS dictation only: remember the override (for
                // the post-insert keep chip) and mirror it into the in-flight snapshot
                // the stop-time pass reads. NO persisted-settings write happens here.
                self.sessionStyleOverride = next
                self.sessionCleanup = next
                // Re-prewarm the on-device cleanup model for the newly chosen style, so
                // the stop-time pass doesn't pay a cold load. Capture the actor-isolated
                // engine reference the same way `beginDictation` does before hopping off
                // the main actor. A no-op when the model is unavailable or the style is
                // `.off` (which skips the model entirely).
                let cleanupEngine = self.cleanup
                if next != .off, CleanupEngine.isAvailable {
                    Task { await cleanupEngine.prewarm(style: next) }
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

        // H1: only auto-open the window on a genuine first run — a user who hasn't
        // finished onboarding needs the welcome flow (it lives inside the window).
        // Existing users launch quietly into the menu bar instead of having the window
        // thrown at them every relaunch, consistent with H7 ("vanish into the menu
        // bar"); they reopen it from the status item, Dock, or Spotlight whenever they
        // want it. This also means the first-run onboarding never auto-triggers for
        // someone who already completed it.
        if !settings.hasOnboarded {
            openSettings(tab: .dashboard)
        }

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

    /// Reopening Talkie brings the main window back. This fires for a Dock-icon
    /// click AND for a Spotlight/Finder launch of an already-running instance —
    /// crucially it fires even while the app is `.accessory` (Dock-icon hidden after
    /// a genuine close, H7), which is exactly how the window returns from that state.
    /// `openSettings` flips the policy back to `.regular` and re-shows the window.
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
        appMenu.addItem(withTitle: String(format: "About %@".loc, Brand.displayName),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…",
                                           action: #selector(openSettingsMenu), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(format: "Hide %@".loc, Brand.displayName),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: String(format: "Quit %@".loc, Brand.displayName),
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
            if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: Brand.displayName) {
                image.isTemplate = true
                button.image = image
            }
            // Guarantee the item is visible even if the SF Symbol fails to load —
            // an image-less, title-less status item is zero-width (invisible).
            if button.image == nil {
                button.title = Brand.displayName
            }
            button.toolTip = String(format: "%@ — hold your key to dictate".loc, Brand.displayName)
        }
        item.menu = buildMenu()
        statusItem = item
        NSLog("Talkie: status item created (hasButton=\(item.button != nil), hasImage=\(item.button?.image != nil))")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // H7: after a genuine close the Dock icon is gone, so the window is only
        // reachable from here — keep "Open Talkie" at the very top, one click away.
        // (It also restores the Dock icon via `openSettings`.)
        menu.addItem(withTitle: String(format: "Open %@".loc, Brand.displayName), action: #selector(openMain), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())

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
        menu.addItem(withTitle: String(format: "Quit %@".loc, Brand.displayName), action: #selector(quit), keyEquivalent: "q")
            .target = self

        return menu
    }

    private func statusLine() -> String {
        // Pure menu-bar chrome — the brand name is interpolated verbatim (these
        // short status lines are deliberately unlocalized). `Brand.displayName`
        // keeps them following a rebrand; the "— …" tail stays as-is.
        if !TranscriptionEngine.isAvailable { return "\(Brand.displayName) — speech unavailable" }
        if !permissions.allGranted { return "\(Brand.displayName) — needs permissions" }
        return isDictating ? "\(Brand.displayName) — listening…" : "\(Brand.displayName) — ready"
    }

    private func hintLine() -> String {
        // One gesture for everyone: hold to talk, tap twice to lock hands-free.
        return String(format: "Hold %@ to talk · tap twice to lock".loc, settings.activationKey.displayName)
    }

    private func updateStatusUI() {
        guard let menu = statusItem?.menu else { return }
        // The status + hint lines sit below "Open Talkie" + its separator (H7 added
        // those two at the top), so they are items 2 and 3, not 0 and 1.
        if menu.items.indices.contains(2) { menu.items[2].title = statusLine() }
        if menu.items.indices.contains(3) { menu.items[3].title = hintLine() }
        let symbol = isDictating ? "waveform" : "mic.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: Brand.displayName)
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
                    // B5: a partial arrived — the recognizer is emitting words, so the
                    // user is speaking even if their voice never clears the level floor
                    // (the load-bearing quiet-speaker case). Count it as activity so the
                    // auto-stop watchdog resets its silence clock / cancels a countdown.
                    // Non-nil only for a locked session, so held sessions are unaffected.
                    AppDelegate.shared?.silenceWatchdog?.transcriptChanged()
                    // C1: hand the pill STRUCTURE (committed head + volatile tail), not
                    // the flattened `combined`, so it can render the still-changing tail
                    // fainter and let words firm up as they finalize. Display only — the
                    // transcript itself still flows to the focused app unchanged.
                    AppDelegate.sharedHUD?.updateTranscribing(finalized: update.finalizedText,
                                                              volatile: update.volatileText)
                    // H5: when a sealed onboarding try-it is active, also stream the
                    // live transcript into its results field so words appear as you
                    // speak. The HUD pill still updates too (acceptable/good — the
                    // pill during try-it is harmless). Reaches `self` (not the static
                    // HUD proxy) since the sink is per-instance state.
                    AppDelegate.shared?.dictationInterimSink?(update.combined)
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
    /// The dictation event stream's continuation. Hoisted from a `setupHotKey` local
    /// to a property (B5) so the silence auto-stop watchdog can yield `.end` into the
    /// SAME ordered stream a manual key-release goes through — the auto-stop is then
    /// byte-identical to a real tap (same `endDictation`, same FIFO ordering vs any
    /// in-flight begin). Still captured by the `HotKeyMonitor` closures below exactly as
    /// before; storing it changes nothing about the tap path.
    private var dictationEventContinuation: AsyncStream<DictationEvent>.Continuation?

    private func setupHotKey() {
        // Funnel press/release/lock edges through ONE ordered stream so a begin can
        // never be scheduled after its matching end (two independent Tasks have
        // no FIFO guarantee on the MainActor executor). The gesture machine lives in
        // HotKeyMonitor on the tap thread; it hands us already-decided begin/end/lock.
        let (stream, continuation) = AsyncStream<DictationEvent>.makeStream()
        dictationEventContinuation = continuation
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

    // MARK: Hands-free auto-stop (B5)

    /// The silence auto-stop watchdog for the CURRENT session — non-nil only while a
    /// hands-free-LOCKED session is live. A held (push-to-talk) session never gets one,
    /// so it can never auto-stop. Created in `lockDictation` (the moment the session
    /// becomes locked), fed by the `onLevel` closure + the engine's volatile handler,
    /// and torn down on every session-end path. `@MainActor`-confined like everything
    /// on the dictation path, so no locking is needed.
    private var silenceWatchdog: SilenceWatchdogDriver?

    /// Build + start the watchdog for a session that just locked hands-free. On its
    /// `.stop` it yields `.end` into the dictation event stream — the auto-stop then
    /// runs the exact same teardown a manual tap does. The countdown/cancel callbacks
    /// only touch the HUD pill.
    private func startSilenceWatchdog() {
        silenceWatchdog?.stop()   // defensive: never leak a prior session's watchdog
        let myID = sessionID
        silenceWatchdog = SilenceWatchdogDriver(
            onCountdownStarted: { [weak self] remaining in
                // Ignore a stale callback from a superseded session.
                guard let self, self.sessionID == myID else { return }
                self.hud.showSilenceCountdown(remaining: remaining)
            },
            onCancelled: { [weak self] in
                guard let self, self.sessionID == myID else { return }
                self.hud.cancelSilenceCountdown()
            },
            onStop: { [weak self] in
                guard let self, self.sessionID == myID else { return }
                // Clear the countdown UI, then end exactly as a manual tap would by
                // yielding `.end` into the ordered event stream (not calling
                // `endDictation()` directly — the stream keeps begin/end ordering).
                self.hud.cancelSilenceCountdown()
                self.dictationEventContinuation?.yield(.end)
            })
        silenceWatchdog?.start()
    }

    /// Tear down the current session's watchdog (every end path calls this). Safe to
    /// call when there is none.
    private func stopSilenceWatchdog() {
        silenceWatchdog?.stop()
        silenceWatchdog = nil
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
        // B5: only a LOCKED hands-free session can auto-stop on silence (a held session
        // ends when the key is released, so it never needs — and never gets — a
        // watchdog). Start it here, the moment the session becomes locked, and feed it
        // from the live level + volatile-transcript signals below.
        startSilenceWatchdog()
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
        // D8: on each accepted topic shift, record a chapter stamped with the
        // recorder's LIVE elapsed time. The engine fires `onAccepted` off its actor;
        // we hop to the main actor to read `elapsed` and append to the recorder's
        // `pendingChapters` (both main-actor state), which `stop()` folds into the
        // saved meeting. The timestamp is honestly the accept time — it lags the true
        // topic shift by the engine's hysteresis window, and is labeled as such, not
        // backdated. Guarded on an active recording so a stray late accept can't
        // append after stop.
        subtopicEngine = MeetingSubtopicEngine(model: subtopicModel) { [weak self] topic in
            Task { @MainActor in
                guard let self, self.meetingRecorder.isRecording else { return }
                self.meetingRecorder.pendingChapters.append(
                    Chapter(title: topic, start: self.meetingRecorder.elapsed)
                )
            }
        }
        meetingPill.attach(recorder: meetingRecorder, subtopic: subtopicModel)

        // Feed finalized transcript segments to the subtopic engine unconditionally.
        // D8: chapters are a SAVED-NOTES artifact, so the engine must see the
        // transcript on every recording regardless of the pill. `showMeetingPill`
        // governs only whether the live topic is DISPLAYED (the pill), not whether it
        // is COMPUTED — H1's toggle sweep wrongly conflated the two and re-gated
        // computation here, silently starving chapters for pill-hidden users. The
        // engine no-ops when its on-device model is unavailable, so this is cheap.
        meetingRecorder.onLiveSegment = { [weak self] _, text in
            Task { @MainActor in
                guard let self else { return }
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
        // Start fresh: drop any chapters a prior recording left behind (D8). The
        // recorder also clears this in start(); doing it here too means an accept
        // that somehow races the very start of a recording can't inherit stale state.
        meetingRecorder.pendingChapters = []
        // D8: SEPARATE computation from display. The subtopic engine drives the saved
        // note's "## Chapters" section, so it must run for EVERY recording — chapters
        // are an artifact of the notes the user keeps, not of the transient pill. Start
        // it unconditionally (it self-no-ops when the on-device model is unavailable).
        // Only the live PILL display honors `showMeetingPill`: H1 folded the standalone
        // live-topic toggle into that switch, but "show the pill" and "produce chapters"
        // are different concerns — the pill toggle must not silently suppress a
        // saved-notes feature. (No new toggle: respects H1's single-switch mandate.)
        Task { await subtopicEngine.start() }
        guard settings.showMeetingPill else { return }
        meetingPill.show()
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

    /// H3 — the style that will ACTUALLY clean this dictation, in priority order: a
    /// mid-session switcher override, else the in-flight snapshot captured at begin,
    /// else the resolved session/category default. This is what the pill label shows
    /// and what a cycle reads to compute its "next" case, so the label and the
    /// stop-time behaviour can never disagree.
    private var effectiveSessionStyle: CleanupStyle {
        sessionStyleOverride ?? sessionCleanup ?? activeCleanupStyle
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
        // B5 defensive: a fresh session starts un-locked and unwatched — never inherit a
        // prior session's auto-stop watchdog (it's re-created if/when this one locks).
        stopSilenceWatchdog()

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

        // Context awareness — but read the target FIRST (cheap NSWorkspace, no
        // Accessibility), resolve its per-app profile, and only THEN mine the focused
        // window/field for names. That ordering is the "Private app" (I1) privacy
        // invariant: an app marked `neverStore` must never have its focused text READ
        // at all — not read-and-discarded — so we gate the AX read on the resolved
        // profile. When context awareness is off, or the target is Talkie itself, we
        // also skip mining (the target still feeds the usage dashboard).
        let selfBundleID = AppPaths.bundleIdentifier
        let (frontApp, frontPID) = ContextCapture.frontTarget(selfBundleID: selfBundleID)
        currentTarget = frontApp

        // Resolve the per-app rules for this app once, here on the main actor
        // (global → per-category → per-app merge, falling back to `settings.*`
        // for every unset field). Snapshotted so a mid-session profile edit
        // can't skew the in-flight session; carried into `endDictation` below.
        var profile = profiles.resolve(for: frontApp, settings: settings)

        // The AX mine happens only when context awareness is on, the app is not
        // Talkie itself, AND the app is not marked Private. For a Private app the
        // focused field is never touched — `mine`'s `talkieDebugLog` line is absent
        // from the session log, which is the observable proof no read occurred.
        let captured: CapturedContext
        if settings.contextAwareness, frontApp.bundleID != selfBundleID, !profile.neverStore {
            captured = ContextCapture.mine(target: frontApp, pid: frontPID)
        } else {
            captured = CapturedContext(target: frontApp, phrases: [], windowTitle: nil,
                                       processID: frontPID)
        }

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

        // L2-b (LOG-ONLY): snapshot the target as the auto-add gate sees it. When
        // context awareness is off we pass `nil` (the gate fails closed — no
        // suggestion — but the end-of-session hook still logs the attempt so the
        // fail-closed rate shows up in the calibration data). We reuse `captured`,
        // whose `windowTitle` is already `nil` under that setting, so the agent-CLI
        // check degrades honestly.
        sessionFrontApp = settings.contextAwareness
            ? AutoAddGate.FrontApp(bundleID: captured.target.bundleID,
                                   category: captured.target.category,
                                   windowTitle: captured.windowTitle)
            : nil

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
            guard self.isDictating, self.sessionID == myID else {
                // H5: a try-it whose session was abandoned during the mic await —
                // clear its sink and reset the onboarding button (idempotent).
                self.clearTryItSinks()
                return
            }
            guard micOK else {
                self.isDictating = false
                self.updateStatusUI()
                self.birdBuddy.setActive(false)
                self.hud.showError("Microphone access is needed to dictate.")
                self.permissions.refresh()
                // H5: declining the mic ends the try-it — surface the honest inline
                // error in the onboarding field, then clear the sink and reset the
                // button (clearTryItSinks fires onEnded). Flow stays continuable.
                self.micDeclinedTryItError?("Microphone access is needed to try it — you can grant it and tap again.".loc)
                self.clearTryItSinks()
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
                    self.clearTryItSinks() // H5: abandoned try-it — reset its sink/UI.
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
                            // B5: feed the same normalized level to the hands-free
                            // auto-stop watchdog. Non-nil only for a locked session, so
                            // a held session is never watched. A level above the floor
                            // (speech) cancels a running countdown; sustained sub-floor
                            // level is the silence that arms + eventually stops.
                            self?.silenceWatchdog?.observe(level: level)
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
                    // H1: the "also pause other apps" sub-toggle is gone — the media-key
                    // fallback is now always allowed. It's gated on real output activity
                    // in `MusicController.pauseForDictation` (it only sends play/pause when
                    // another process is actually playing), so it can't fire spuriously.
                    self.musicController.pauseForDictation(allowMediaKeyFallback: true)
                }
                self.hud.showListening()
            } catch {
                // The user may have released the key (or started a newer session)
                // before this error surfaced — tear down silently rather than
                // flashing an error pill for a session they already abandoned.
                guard self.isDictating, self.sessionID == myID else {
                    streaming?.cancel()
                    await engine.cancelSession()
                    self.clearTryItSinks() // H5: abandoned try-it — reset its sink/UI.
                    return
                }
                self.isDictating = false
                self.updateStatusUI()
                self.birdBuddy.setActive(false)
                self.hud.showError(error.localizedDescription)
                streaming?.cancel()
                await engine.cancelSession()
                // H5: engine/audio start failed for a try-it — clear the sink and
                // reset the onboarding button; the HUD already shows the error.
                self.clearTryItSinks()
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
        stopSilenceWatchdog()   // B5: a dead mic ends the session — drop its watchdog too
        handsFreeLocked = false
        hud.setHandsFreeLocked(false)
        sessionLive = false
        recordingStartedAt = nil
        Feedback.stop()
        audio.stop()
        musicController.resumeAfterDictation()
        currentStreaming?.cancel()
        currentStreaming = nil
        // H3: a capture failure ends the session — drop any in-pill style override so
        // it can't leak into the next dictation (nothing was inserted, so no keep chip).
        sessionCleanup = nil
        sessionStyleOverride = nil
        sessionFrontApp = nil   // L2-b: drop the gate snapshot too (no ingest on this path).
        Task { await engine.cancelSession() }
        isProcessing = false
        updateStatusUI()
        birdBuddy.setActive(false)
        hud.showError(error.localizedDescription)
        // H5: a mid-session capture failure ends a try-it too — clear the sink and
        // reset the onboarding button (no text was ever delivered).
        clearTryItSinks()
    }

    func endDictation() {
        guard isDictating else { return }
        isDictating = false
        // B5: the session is ending (manual tap OR the watchdog yielded `.end`) — tear
        // the watchdog down so no timer outlives the session. Idempotent, so the
        // auto-stop path that just fired this is fine to re-tear here.
        stopSilenceWatchdog()
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
            // H3: a session abandoned during setup — clear any in-pill style override
            // (and its mirror) so it can't leak into the next dictation. Nothing was
            // inserted, so there is no keep chip to offer.
            sessionCleanup = nil
            sessionStyleOverride = nil
            sessionFrontApp = nil   // L2-b: drop the gate snapshot too (no ingest on this path).
            hud.hide()
            // H5: a try-it stopped before audio went live (e.g. clicked stop during
            // mic/model setup) — clear the sink and reset the onboarding button.
            clearTryItSinks()
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
        // "Private app" (I1): when set, this session inserts text normally but the
        // pipeline stores and learns NOTHING from it — the completion closure below
        // skips history/graph/app-usage/niche-harvest and the learn-from-edits watcher.
        // Aggregate word counts (lifetime stats + streak) still increment because they
        // carry no content and no app identity, keeping the WPM dashboard honest.
        let neverStore = resolved.neverStore
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
        // L2-b (LOG-ONLY): the target as the auto-add gate sees it, snapshotted at
        // session start (carries the window title for the agent-CLI check, which
        // `currentTarget` lacks). `nil` when context awareness was off → the gate
        // fails closed. Rides into the processing Task like `target`.
        let frontAppForGate = sessionFrontApp
        sessionFrontApp = nil
        let selfBundle = AppPaths.bundleIdentifier
        // Reuse the cleanup style captured at session start — unless the user cycled
        // the in-pill switcher this dictation, in which case `sessionCleanup` already
        // carries that H3 override (the cycle mirrors it here on purpose) so the
        // stop-time pass honors the switcher's tooltip. Snapshotting it still keeps a
        // later settings change from skewing the stats/filler accounting vs. what the
        // assembler actually cleaned.
        let style = sessionCleanup ?? resolved.cleanupStyle
        sessionCleanup = nil
        // H3 — decide whether to offer the post-insert "Keep for {App}?" chip. The pure
        // gate offers only when the user actually cycled the switcher this dictation, the
        // chosen style differs from the app's resolved default (cycling back is a no-op
        // worth no chip), and the app has a bundle id to key a rule against. Captured
        // here, before the override is cleared below, and surfaced only on a successful
        // `.inserted` outcome (the no-stacking settle gate lives in `maybeOfferKeepStyle`).
        let keepStyleOverride = KeepStyleOffer.decision(
            sessionOverride: sessionStyleOverride,
            resolvedDefault: resolved.cleanupStyle,
            bundleID: currentTarget.bundleID
        )
        // H3 — whether the style was changed mid-dictation. When it was, the streamed
        // per-segment cleanup that ran WHILE speaking used the OLD style, so its result
        // is stale; force the whole-transcript re-clean below (which reads the current
        // `style`) so a single-segment dictation still honors the switch. Without this,
        // cycling on an uninterrupted utterance would silently keep the pre-cycle style —
        // the exact "the tap did nothing to this dictation" bug H3 exists to kill.
        let styleWasOverridden = sessionStyleOverride != nil
        // Clear the session override on this (normal) teardown path — it must never
        // leak into the next dictation. Other teardown paths clear it too.
        sessionStyleOverride = nil
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
            // H5: a sealed try-it must NEVER inject — optimistic insertion pastes the
            // interim text into the frontmost app before the seam below, so it's
            // disabled whenever a try-it sink is installed.
            var optimistic: (count: Int, text: String)?
            if self.dictationSink == nil,
               optimisticEnabled, mode == .paste, cleanupEnabled, !languageSwitched,
               !finalRaw.isEmpty, CleanupEngine.isAvailable {
                let interimProcessed = TextProcessor.apply(
                    replacements: replacements, removeFillers: removeFillers,
                    autoCapitalize: autoCap, to: finalRaw
                )
                var interim = interimProcessed.text
                if vibeOn, !vibeSnapshot.isEmpty {
                    // G10: a terminal gets the repo-relative path (Sources/Views/File.tsx);
                    // an editor keeps the bare basename.
                    interim = SpokenFileMatcher.format(interim, snapshot: vibeSnapshot,
                                                       preferPaths: target.category == .terminal).0
                }
                if !interim.isEmpty, interim.count <= Self.optimisticMaxChars,
                   self.commandRouter.intent(for: interim,
                                              meetings: MeetingSnapshot(meetings: self.meetingStore.meetings),
                                              crossSurfaceEnabled: self.settings.crossSurfaceCommandsEnabled) == nil,
                   case .inserted = TextInjector.insert(interim, mode: mode) {
                    optimistic = (interim.count, interim)
                    self.hud.showInserting(replacedWords: [], privateSession: neverStore)
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
                // H3: if the user cycled the style mid-dictation, the streamed buffer
                // was cleaned with the OLD style — bypass it and re-clean with the
                // current one, so even an uninterrupted utterance reflects the switch.
                if let streaming, !languageSwitched, !styleWasOverridden, streaming.segmentCount <= 1 {
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

            // A14 (DARK — `Dev.llmJargonRepair`, default OFF): an on-device LLM repair
            // pass that catches badly-mangled novel jargon the PURELY PHONETIC
            // `NicheCorrector` above structurally cannot ("claude.md" heard as "cloud
            // MD" diverges too far in skeleton distance). It runs AFTER the phonetic
            // corrector on the same known-term list, and its diff kill-switch admits a
            // rewrite ONLY when every change is inserting one of those terms — worst
            // case it's a no-op. This is a measurement prototype; wiring it live is
            // gated on a jargon-corpus WER benchmark that has not been recorded. With
            // the flag OFF this branch is skipped and `cleaned` is byte-identical to a
            // build without A14 — the property the whole spike is built around.
            if Dev.llmJargonRepair, !nicheTerms.isEmpty, LLMJargonRepair.isAvailable {
                cleaned = await LLMJargonRepair().repair(cleaned, knownTerms: nicheTerms)
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

            // Structural dictation commands: a free-standing "new line"/"new
            // paragraph" (EN) or "neue Zeile"/"neuer Absatz" (DE) becomes a real
            // break in the inserted text. Deterministic + always-on, a sibling of
            // NumberNormalizer above. It runs AFTER the dictionary TextProcessor.apply
            // ON PURPOSE: a user dictionary rule that targets "new line" runs first
            // and consumes the phrase, so a custom mapping still wins — that's the
            // escape hatch. Running structural ahead of the dictionary would break it.
            finalText = StructuralCommands.apply(finalText, languageCode: cleanupLangCode)

            // Vibe coding: snap spoken filenames to the real files in your project
            // ("exercise library dot tsx" → "ExerciseLibrary.tsx").
            var fileFixes = 0
            if vibeOn, !vibeSnapshot.isEmpty {
                // G10: in a terminal, insert the repo-relative path (Sources/Views/File.tsx)
                // that the shell + Claude Code want; an editor keeps the bare basename.
                let (vibed, hits) = SpokenFileMatcher.format(finalText, snapshot: vibeSnapshot,
                                                             preferPaths: target.category == .terminal)
                finalText = vibed
                fileFixes = hits
            }

            guard !finalText.isEmpty else {
                // H5: an empty try-it (nothing intelligible said) still ends cleanly —
                // deliver the empty result and reset the onboarding button. Nothing is
                // ever inserted, and the gesture hint (a dictation-into-app affordance)
                // is irrelevant to the sealed try-it, so it's skipped.
                if let sink = self.dictationSink {
                    self.hud.hide()
                    sink(finalText)
                    self.clearTryItSinks()
                    return
                }
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

            // H5 — the sealed onboarding try-it seam. When a try-it sink is installed,
            // this dictation ran the normal engine + cleanup pipeline (so the user sees
            // real, styled output) but must go NOWHERE ELSE: no command routing, no
            // "note this" export, no clipboard/paste/injection, no learning-watch, and
            // nothing written to History / stats / graph / app-usage / niche-harvest.
            // We hand the finished `finalText` to the sink, reset the button, and
            // return BEFORE any of that machinery runs. The `defer` above already
            // released `isProcessing`. This is the Private-app-grade guarantee: a
            // try-it's words only ever reach the onboarding field.
            if let sink = self.dictationSink {
                self.hud.hide()
                sink(finalText)
                self.clearTryItSinks()
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

            // B9 — voice editing of just-inserted text ("scratch that" /
            // "replace X with Y"). Runs BEFORE the general command dispatch and the
            // dictation path, but ONLY when the last dictation is still a safe, live
            // edit target: same app + ≤45s (`ImplicitSelectionGate`) AND its insertion
            // actually landed in the field (`lastInsertedDictationID` matches the
            // freshest history entry — the last-outcome-`.inserted` bit). Gated on
            // `optimistic == nil` like every other interception here (with optimistic
            // insertion on, the interim is already pasted, so intercepting would strand
            // it). The router additionally enforces the false-positive kill switch
            // (`replace X with Y` is an edit only if X literally occurs, word-bounded,
            // in that text); anything that isn't a byte-exact edit command falls through
            // and dictates literally.
            if optimistic == nil,
               let editTarget = ImplicitSelectionGate.eligible(
                   lastEntry: self.history.entries.first, now: Date(), currentTarget: target
               ),
               editTarget.id == self.lastInsertedDictationID,
               let editIntent = self.commandRouter.intent(for: finalText, lastInserted: editTarget),
               editIntent is ScratchThatIntent || editIntent is ReplaceWordIntent {
                if await self.runVoiceEdit(intent: editIntent, target: editTarget, mode: mode) {
                    self.isProcessing = false
                    return
                }
                // The edit was skipped (best-effort AX check says the field no longer
                // ends with the expected text, or the recomputed edit didn't apply):
                // literal insertion is the safe failure, so fall through to dictate the
                // phrase exactly as spoken.
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
                // H1: the "let commands target your last dictation" toggle is gone —
                // this fallback is now always on. It's safe by construction: it only
                // changes what a command does once it's ALREADY matched and has nothing
                // selected, the `ImplicitSelectionGate` still bounds it to the same app
                // within `maxAge`, and every use is gated behind an explicit HUD preview
                // before anything is written.
                if intent.needsSelection, selection?.isEmpty != false,
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
                        } else if result.replacement.isEmpty {
                            // A side-effect intent (e.g. "run shortcut Ship It") ran and
                            // has nothing to insert — every other CommandResult is
                            // insertion-only, so an empty replacement is the explicit
                            // "done, type nothing" signal. Confirm with a toast naming the
                            // shortcut, never inject the empty string. Parse the name from
                            // `ctx.spokenCommand` (an immutable copy) rather than the
                            // `var finalText`, so this read doesn't widen that variable's
                            // isolation region into the mixed-isolation learning closures below.
                            let ranName = RunShortcutParser.parse(ctx.spokenCommand) ?? ctx.spokenCommand
                            self.hud.showSaved(String(format: "Ran shortcut “%@”".loc, ranName))
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

            // Aggregate word counts run for EVERY app, Private or not: they carry no
            // transcript content and no app identity, so the lifetime WPM gauge and
            // the daily streak stay honest even when the app is marked Private (I1).
            self.stats.record(words: words, durationSec: duration)
            self.stats.recordFixes(
                dictionary: processed.replacementHits + biasApplied.count + nicheFixes.count + fileFixes,
                fillers: processed.fillersRemoved,
                aiWords: aiWordsChanged
            )
            // Per-day activity (streak + heatmap) — also a pure aggregate word count.
            self.activity.record(words: words)

            // Everything below RECORDS CONTENT or APP IDENTITY, or arms learning from
            // it — the history entry, the "where your words went" app-usage record, the
            // context-graph provenance, and the niche-vocabulary harvest. A "Private
            // app" (I1) stores and learns NOTHING, so we skip all of it: nothing is
            // written and then discarded — it's simply never recorded.
            if !neverStore {
                // L4: this dictation's words/phrases are CONTENT, so the lifetime
                // word/phrase frequency store is skipped for a Private app too.
                self.wordFreq.record(text: finalText)
                self.history.add(
                    finalText, wordCount: words, durationSec: duration,
                    appName: target.name, appCategory: target.category.rawValue,
                    bundleID: target.bundleID,
                    id: dictationID
                )
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
                // L2-b (LOG-ONLY / PREVIEW — writes NOTHING to the Scratchpad). For each
                // commitment this dictation surfaced, record what the "added by Chirp"
                // auto-add gate WOULD decide, so Jann can calibrate the threshold from
                // real logs before the live lane ships. This runs ONLY inside
                // `!neverStore`, so a Private app (I1) produces zero preview records —
                // the gate never even sees it. The live-dictation path uses the Stage-1
                // heuristic extractor (`GraphLLMExtractor` is meeting-only, so `.heuristic`
                // here); the gate applies its stricter second-person/future check to those.
                // Records carry `dictationID` so they join the true-delete cascade.
                let existingScratchpadLines = self.scratchpad.lines.map(\.text)
                for commitment in ContextGraphExtractor.commitments(in: finalText) {
                    let decision = AutoAddGate.shouldSuggest(
                        commitmentText: commitment,
                        source: .heuristic,
                        frontApp: frontAppForGate,
                        existingLines: existingScratchpadLines
                    )
                    self.autoAddPreviewLog.record(
                        commitmentText: commitment,
                        frontAppBundleID: frontAppForGate?.bundleID,
                        source: .heuristic,
                        decision: decision,
                        sourceDictationID: dictationID.uuidString,
                        nowUnix: nowUnix
                    )
                }
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
                // B9: remember that THIS dictation's text actually landed in the field,
                // so a follow-up "scratch that" / "replace X with Y" may edit it in
                // place. Only when it was stored (a Private app keeps no history entry
                // to edit) — otherwise the edit gate has no matching entry and must not
                // fire. The optimistic-replace path (`optimistic != nil`) also lands as
                // `.inserted`, and its text is genuinely on screen, so it qualifies too.
                self.lastInsertedDictationID = neverStore ? nil : dictationID
                Feedback.done()
                self.hud.showInserting(replacedWords: replacedWords, privateSession: neverStore)
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
                // ping them with an Undo (WhisperFlow-style live learning). A
                // "Private app" (I1) learns nothing, so the watcher (and the Claude
                // Code transcript scan it schedules) never arms — fixing a word right
                // after dictating into a Private app adds nothing to the dictionary.
                if self.settings.learnFromEdits, !neverStore {
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
                // Suppressed for a Private app (I1): tapping "Fix" would teach the
                // dictionary, and a Private app learns nothing from what you dictate.
                if !neverStore { self.maybeOfferLowConfidenceReview(reviewFlagged) }
                // H8 — once ever, after a 3-day streak of real use, offer to start
                // Talkie at login (so the hotkey stops dying silently after a reboot).
                // Queued LAST and with the longest settle, so it loses to the insertion
                // pill and to the A9/A12 offers above; a resolved flag persists so an
                // ignored offer never reappears. A no-op unless the streak/settings
                // gates pass. Runs for Private apps too — it carries no transcript
                // content and the streak was already recorded above (I1-safe).
                self.maybeOfferLaunchAtLogin()
                // H3 — if the user cycled the in-pill cleanup switcher this dictation
                // to a non-default style, offer to keep it for this app. Nil unless a
                // real, differing override happened; the helper adds the bundle-id and
                // no-stacking gates (it loses to a learned ping / copy prompt).
                self.maybeOfferKeepStyle(keepStyleOverride, target: target)
            case .leftOnClipboard(let reason):
                // B9: the text is on the clipboard, NOT in the field — a caret-relative
                // edit would corrupt whatever is focused, so clear the edit target.
                self.lastInsertedDictationID = nil
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
                    shortcut: self.pasteLastShortcutDisplay
                )
            case .empty:
                // B9: nothing landed — no valid edit target.
                self.lastInsertedDictationID = nil
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

    // MARK: Voice editing of just-inserted text (B9)

    /// Execute a B9 in-place edit ("scratch that" / "replace X with Y") against the
    /// text just dictated into the front app. Returns `true` when the edit was applied
    /// (the caller should stop — nothing else runs for this utterance) and `false` when
    /// it was deliberately SKIPPED, so the caller falls through and dictates the phrase
    /// literally (the safe failure).
    ///
    /// Runs the edit IMMEDIATELY — no confirm tap. B9 edits are byte-exact (a
    /// deterministic delete or rightmost-occurrence swap, not a fuzzy LLM rewrite), and
    /// the RSI user this is built for can't reach for a confirm chip; instead every edit
    /// shows a tap-optional Undo pill (`showLearned`-style) that restores the original
    /// via the same clipboard-paste primitive B1/B2 use.
    ///
    /// Best-effort safety net beyond the time/app/outcome gate: a cheap AX read of the
    /// focused field. If the field is READABLE and its text does NOT still end with what
    /// we inserted, the caret/content moved out from under us — skip and insert
    /// literally. An UNREADABLE field (Electron/web: VS Code, Slack, Chrome, Claude) is
    /// NOT a mismatch; per `ImplicitSelectionGate`'s doctrine it fails OPEN, because a
    /// stricter AX check is exactly as blind there and would defeat the feature where
    /// it's needed most.
    /// - Returns: whether an edit was applied.
    private func runVoiceEdit(intent: any CommandIntent, target: DictationEntry, mode: InsertionMode) async -> Bool {
        // `.type`-learned apps can't be edited by the paste-based backward primitives
        // (`replaceBackward`/`deleteBackward` are paste-mode only). Rather than a
        // partial select+retype that risks corrupting the field, treat a non-paste app
        // as "can't safely edit" and insert literally. (Paste is the default; only apps
        // that failed a paste and self-healed to `.type` land here — rare.)
        guard mode == .paste else { return false }

        // Best-effort end-of-field check (fails OPEN when unreadable).
        if !focusedFieldStillEndsWith(target.text) { return false }

        let original = target.text
        let originalCount = original.count

        switch intent {
        case let scratch as ScratchThatIntent:
            _ = scratch // carries `original`; we use `target.text` (identical) directly
            let outcome = TextInjector.deleteBackward(graphemeCount: originalCount, mode: mode)
            guard case .inserted = outcome else { return false }
            // The scratched text is no longer on screen and no longer in history.
            self.history.delete(target)
            // A scratch consumes the edit target: a second "scratch that" must not
            // re-fire against a now-deleted entry.
            if self.lastInsertedDictationID == target.id { self.lastInsertedDictationID = nil }
            self.hud.showLearned("Scratched".loc) { [weak self] in
                guard let self else { return }
                // Undo: re-insert the original at the caret (B2 paste path) and restore
                // the history entry so the two agree again. A fresh entry (new id) is
                // the honest record — it's a re-insertion, not the resurrection of the
                // exact prior row — and it becomes the new edit target.
                _ = TextInjector.insert(original, mode: mode)
                let restored = self.history.add(
                    original, wordCount: WordCounter.count(original), durationSec: 0,
                    appName: target.appName, appCategory: target.appCategory, bundleID: target.bundleID
                )
                self.lastInsertedDictationID = restored?.id
                self.hud.showReverted()
            }
            return true

        case let replace as ReplaceWordIntent:
            guard let edited = replace.editedText, edited != original else { return false }
            let outcome = TextInjector.replaceBackward(
                graphemeCount: originalCount, with: edited, mode: mode
            )
            guard case .inserted = outcome else { return false }
            // History now reflects what's on screen, so a follow-up "replace…" composes
            // on the edited text. No stats/graph re-ingestion — an edit isn't a new
            // dictation (see `HistoryStore.updateText`).
            self.history.updateText(id: target.id, newText: edited)
            let editedCount = edited.count
            let message = String(
                format: "Replaced “%@” with “%@”".loc,
                replace.find, replace.replacement
            )
            self.hud.showLearned(message) { [weak self] in
                guard let self else { return }
                // Undo: swap the edited span back to the original via the same
                // backward-select-and-paste primitive, and restore the history text.
                _ = TextInjector.replaceBackward(
                    graphemeCount: editedCount, with: original, mode: mode
                )
                self.history.updateText(id: target.id, newText: original)
                self.hud.showReverted()
            }
            return true

        default:
            return false
        }
    }

    /// Best-effort: whether the focused field's text still ends with `expected` (the
    /// text we just inserted), tolerating the smart-quote/dash reformatting apps apply.
    /// Returns `true` (proceed) when the field is UNREADABLE — Electron/web apps expose
    /// no AX value, and per `ImplicitSelectionGate` doctrine we fail OPEN there rather
    /// than block the feature in exactly the apps that need it. Only a readable field
    /// whose visible tail no longer matches returns `false` (skip the edit).
    private func focusedFieldStillEndsWith(_ expected: String) -> Bool {
        guard let (_, value) = AXFieldReader.focusedElementValue() else {
            return true // unreadable → fail open
        }
        let haystack = AXFieldReader.normalizeForMatch(value).trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = AXFieldReader.normalizeForMatch(expected).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        // Prefer an exact tail match (the common case: our text is the last thing
        // typed), but accept containment too — some fields append a trailing newline or
        // the app moved the caret without altering our run. A field that doesn't
        // contain our text at all is a genuine mismatch: skip.
        return haystack.hasSuffix(needle) || haystack.contains(needle)
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

    // MARK: H8 — earned launch-at-login offer

    /// After a successful dictation, offer ONCE — in one tap — to start Talkie at
    /// login, but only once the user has actually earned it: three consecutive days of
    /// real use (`activity.currentStreak >= 3`). The point is that after a reboot the
    /// hotkey is dead until the user remembers Talkie exists; someone who's dictated
    /// three days running clearly wants it around, so this is earned help, not a
    /// growth-hack nag.
    ///
    /// Offered at most once, EVER: `LaunchAtLoginOffer.resolved` persists in
    /// UserDefaults and is set whether the user enables it or ignores it, so an ignored
    /// offer never reappears — including across relaunches. Users who already turned the
    /// Behavior-card toggle on never see it (`!settings.launchAtLogin`). It fits the
    /// single-phase HUD queue exactly like the A9/A12 offers: it waits out the brief
    /// insert/learn pings, then shows ONLY if nothing interactive is on the notch — so a
    /// learned pill, copy prompt, command preview, Vibe offer, or review chip all win,
    /// and the offer simply waits for a later dictation (it hasn't been resolved yet, so
    /// nothing is burned). A touch longer settle than the review chip so it loses to it.
    private func maybeOfferLaunchAtLogin() {
        // Cheap synchronous gate first — no point scheduling a task that will bail.
        guard LaunchAtLoginOffer.shouldOffer(
            launchAtLogin: settings.launchAtLogin,
            resolved: LaunchAtLoginOffer.resolved,
            currentStreak: activity.currentStreak
        ) else { return }
        Task { @MainActor in
            // Let the insert/learn pings — and the A9/A12 offers that queue ahead of
            // this — breathe and claim the notch first. A little longer than the review
            // chip's 1.8s so this offer deterministically loses to it.
            try? await Task.sleep(for: .seconds(2.2))
            // Re-check on the freshest state (the same pure gate) AND that nothing
            // interactive is up — a learned/copy/command/vibe/review pill all suppress
            // it. Every gate fails safe toward NOT showing: an unearned or colliding
            // offer is worse than none.
            guard LaunchAtLoginOffer.shouldOffer(
                    launchAtLogin: self.settings.launchAtLogin,
                    resolved: LaunchAtLoginOffer.resolved,
                    currentStreak: self.activity.currentStreak),
                  !self.isDictating, !self.isProcessing,
                  !self.hud.isPresentingInteractivePill else { return }
            self.hud.showLaunchOffer(
                onEnable: { [weak self] in
                    guard let self else { return }
                    // Flip the existing setting on — its didSet calls LaunchAtLogin.set,
                    // registering the SMAppService login item — and resolve the offer so
                    // it never appears again. A brief "Done" confirmation (the existing
                    // non-interactive saved-pill primitive) closes the loop.
                    self.settings.launchAtLogin = true
                    LaunchAtLoginOffer.resolve()
                    self.hud.showSaved("Talkie will start at login.".loc)
                },
                onResolve: { LaunchAtLoginOffer.resolve() }
            )
        }
    }

    // MARK: H3 — post-insert "Keep for {App}?" chip

    /// After a successful insert where the user cycled the in-pill cleanup switcher
    /// to a style that differs from this app's default (`override`, already decided
    /// at stop), offer — in one tap — to make it the app's per-app rule. This is the
    /// ONLY way an in-pill switcher change persists: the cycle itself was scoped to
    /// just that dictation (honoring the switcher's tooltip), so ignoring this chip
    /// discards the change.
    ///
    /// Gates, all failing safe toward NOT showing:
    /// - `override` is nil unless a real, differing switch happened this dictation.
    /// - Suppressed when the target app has NO bundle id (helper apps, and Talkie
    ///   itself) — there's no stable key to write a per-app rule against.
    /// - Fits the single-phase HUD queue like the A9/A12/H8 offers: it waits out the
    ///   brief insert/learn pings, then shows ONLY if nothing interactive is on the
    ///   notch — so a learned ping (which fires from the async edit-watcher) and the
    ///   copy-prompt both win and the keep chip is simply dropped that turn (learning
    ///   and paste-recovery beat a persistence nicety). A touch longer settle than the
    ///   review chip so it also loses to A12.
    private func maybeOfferKeepStyle(_ override: CleanupStyle?, target: TargetApp) {
        guard let override, let bundleID = target.bundleID else { return }
        let styleName = override.displayName
        let appName = target.name
        Task { @MainActor in
            // Let the insert/learn pings — and the A9/A12/H8 offers that queue ahead of
            // this — breathe and claim the notch first. Slightly longer than the review
            // chip's 1.8s so a learned ping or a review chip deterministically wins.
            try? await Task.sleep(for: .seconds(2.4))
            guard !self.isDictating, !self.isProcessing,
                  !self.hud.isPresentingInteractivePill else { return }
            self.hud.showKeepStyle(style: styleName, app: appName) { [weak self] in
                guard let self else { return }
                // MERGE into the app's existing override sheet (read-modify-write) so
                // unrelated overrides (insertion mode, vocabulary filter, Private) are
                // preserved; refresh the display name while we're here. Mirrors the B2
                // insertion-mode heal path's upsert idiom.
                var profile = self.profiles.profile(for: bundleID)
                    ?? AppProfile(bundleID: bundleID, displayName: appName)
                profile.displayName = appName
                profile.cleanupStyle = override
                self.profiles.upsert(profile)
                // Brief confirmation via the existing non-interactive saved pill.
                self.hud.showSaved(String(format: "%@ will use %@ from now on.".loc, appName, styleName))
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
    /// flight (shared insertion path).
    private func pasteLastTranscript() {
        // H1: the enable/disable toggle is gone — the re-paste chord is always live.
        // The key combo is derived to never collide with the activation key
        // (`ActivationKey.pasteShortcut`), so there's nothing to opt out of.
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

    /// Status-menu "Open Talkie" (H7): bring the window back to the dashboard and
    /// restore the Dock icon. `openSettings` handles the `.regular` flip + focus tick.
    @objc private func openMain() { openSettings(tab: .dashboard) }
    @objc private func openDictionary() { openSettings(tab: .dictionary) }
    @objc private func openSettingsMenu() { openSettings(tab: .general) }

    func openSettings(tab: SettingsTab) {
        permissions.refresh()
        if mainWindow == nil {
            let controller = MainWindowController(
                settings: settings,
                dictionary: dictionary,
                permissions: permissions,
                history: history,
                stats: stats,
                appUsage: appUsage,
                activity: activity,
                wordFreq: wordFreq,
                jobTitle: jobTitle,
                latency: latency,
                systemPressure: systemPressure,
                scratchpad: scratchpad,
                profileImage: profileImage,
                autoAddPreviewLog: autoAddPreviewLog,
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
            // H7: a genuine window close drops the Dock icon — Talkie lives on as a
            // menu-bar item until reopened. The controller only fires this when no
            // sheet is attached (see `windowWillClose`). We additionally refuse to
            // vanish while first-run onboarding is on screen (it IS the window's
            // content until `hasOnboarded`): a mid-flow close must not strip the Dock
            // icon out from under someone still setting up.
            controller.onGenuineClose = { [weak self] in
                guard self?.settings.hasOnboarded == true else { return }
                NSApp.setActivationPolicy(.accessory)
            }
            mainWindow = controller
        }
        // Showing the window must restore the Dock presence (H7). Flip to `.regular`
        // FIRST, then order the window front on the NEXT runloop tick: AppKit has a
        // bug where a window ordered front in the same turn as the policy flip comes
        // up without key focus. The async hop lets the policy change settle so
        // `makeKeyAndOrderFront` + `activate` (inside `show`) actually take focus.
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            self?.mainWindow?.show(tab: tab)
        }
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

    // MARK: Onboarding try-it (H5)

    /// Drive the speak-first onboarding try-it. Idle → install the sinks and start a
    /// SEALED dictation (see `dictationSink`); active → stop it. The record button in
    /// `OnboardingView` calls this on every tap; it's a toggle so the same button both
    /// starts and stops.
    ///
    /// Mic permission is requested INLINE by the existing
    /// `AudioCapture.requestMicrophoneAccess()` await inside `beginDictation` — that
    /// system mic prompt is the try-it's ONLY prompt (no Input Monitoring, no
    /// Accessibility). If the user declines, `beginDictation`'s mic-declined path
    /// clears the sinks and fires `onEnded`, so `onError` + the reset both land and
    /// the onboarding flow stays continuable.
    ///
    /// - Parameters:
    ///   - onInterim: live transcript as you speak (streamed from the engine handler).
    ///   - onFinal: the finished, styled text (what a real dictation would have typed).
    ///   - onError: an honest inline message when the mic is unavailable/declined.
    ///   - onEnded: fired exactly once when the session ends for ANY reason, so the
    ///     button can return to idle (carries no content).
    /// - Returns: `true` iff a new sealed try-it dictation was actually started, so the
    ///   caller can set its recording state only on a real start (a stop, a busy nudge,
    ///   or a synchronous refusal all return `false`).
    @discardableResult
    func toggleTryItDictation(
        onInterim: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (String) -> Void,
        onEnded: @escaping () -> Void
    ) -> Bool {
        // Active try-it (or any in-flight dictation while a sink is installed) → stop.
        if isTryItDictation {
            endDictation()
            return false
        }
        // Don't start a try-it over a real dictation/processing pass sharing the
        // engine + audio; nudge the pill and bail (mirrors beginDictation's guard).
        guard !isDictating, !isProcessing else {
            hud.nudgeBusy()
            return false
        }
        guard TranscriptionEngine.isAvailable else {
            onError("On-device speech isn't available on this Mac.".loc)
            return false
        }
        // Install the sinks FIRST, then begin — `beginDictation`'s async mic step and
        // `endDictation`'s finish both read `dictationSink` to seal the session.
        // `micDeclinedTryItError` bridges beginDictation's mic-declined branch to the
        // onboarding field's inline error; all four closures are cleared together in
        // `clearTryItSinks` on every teardown path.
        dictationInterimSink = onInterim
        dictationSink = onFinal
        dictationTryItEnded = onEnded
        micDeclinedTryItError = onError
        beginDictation()
        // `beginDictation` can refuse SYNCHRONOUSLY (e.g. a meeting is recording) and
        // return before its async task — which is the only path that would otherwise
        // clear the sinks. If it didn't take (`isDictating` still false), surface the
        // reason inline and tear the sinks down now so they can never leak into a later
        // real dictation. (`isDictating` becomes true synchronously at the top of a
        // successful begin, before the async mic await.)
        guard isDictating else {
            onError("Talkie is busy right now — try again in a moment.".loc)
            clearTryItSinks()
            return false
        }
        return true
    }

    /// Bridges `beginDictation`'s mic-declined branch to the onboarding field's inline
    /// error. Set by `toggleTryItDictation`, read once by the mic-declined path, and
    /// cleared alongside the sinks. Kept separate from the content sinks because it
    /// carries a user-facing message, not transcript text.
    private var micDeclinedTryItError: ((String) -> Void)?

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

/// One-shot persisted state for the earned launch-at-login offer (H8). This is NOT a
/// preference — it's a "have we already offered?" latch — so it lives here as a plain
/// UserDefaults flag rather than as an `AppSettings` property (which would imply a
/// user-facing toggle). Set the first time the offer is shown-and-dismissed OR
/// accepted, whichever comes first, and read before ever showing the offer, so it's
/// surfaced at most once, ever — including across relaunches. Mirrors the `GestureHint`
/// counter pattern: no setting, no other state, just a boolean in the plist.
enum LaunchAtLoginOffer {
    private static let resolvedKey = "launchAtLoginOfferResolved"

    /// How many consecutive active days earn the offer. Three is deliberately a real
    /// habit, not a first-session upsell: someone who's dictated three days running is
    /// telling you Talkie belongs on this Mac, so offering to survive a reboot is
    /// earned help, not a growth-hack nag.
    static let requiredStreak = 3

    /// The whole gate as a pure function: offer only when launch-at-login is still off,
    /// the offer was never resolved, and the streak has been earned. Extracted so the
    /// decision is unit-testable without the file system, UserDefaults, or the HUD —
    /// `maybeOfferLaunchAtLogin` calls this for both its cheap pre-check and its
    /// freshest-state re-check after the settle delay.
    static func shouldOffer(launchAtLogin: Bool, resolved: Bool, currentStreak: Int) -> Bool {
        !launchAtLogin && !resolved && currentStreak >= requiredStreak
    }

    /// Whether the offer has already been resolved (accepted or ignored) and must
    /// never be shown again. Main-actor because it's only touched from the dictation
    /// pipeline, so `UserDefaults` access stays on the main thread. `defaults` is
    /// injectable purely so the persistence round-trip is unit-testable against a
    /// throwaway suite instead of `.standard`.
    @MainActor
    static func isResolved(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: resolvedKey)
    }

    /// Convenience accessor for the production call sites (reads `.standard`).
    @MainActor
    static var resolved: Bool { isResolved() }

    /// Mark the offer resolved. Idempotent — safe to call from both the tap path and
    /// the timeout path (only the first write matters).
    @MainActor
    static func resolve(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: resolvedKey)
    }
}

/// The pure decision for H3's post-insert "Keep for {App}?" chip: given the style the
/// user cycled the in-pill switcher to this dictation (`sessionOverride`, nil if they
/// never touched it), the style that was actually resolved as the app's default for
/// this session (`resolvedDefault`), and the target app's bundle id (`bundleID`, nil
/// for helper apps and Talkie itself), decide which style to offer to keep — or nil to
/// show nothing. Extracted so the gate is unit-testable without the HUD, the profile
/// store, or a live session.
///
/// It offers only when ALL hold: the user actually cycled to an override, that override
/// differs from the resolved default (cycling back to the default is a no-op worth no
/// chip), and there is a bundle id to key a per-app rule against. Every branch fails
/// safe toward NOT offering — a spurious "keep?" chip is pure interruption.
enum KeepStyleOffer {
    static func decision(sessionOverride: CleanupStyle?,
                         resolvedDefault: CleanupStyle,
                         bundleID: String?) -> CleanupStyle? {
        guard let sessionOverride, bundleID != nil else { return nil }
        return sessionOverride != resolvedDefault ? sessionOverride : nil
    }
}
