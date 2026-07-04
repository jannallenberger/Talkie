import AppKit
import SwiftUI
import UniformTypeIdentifiers

#if TALKIE_DEV_TOOLS
import TalkieUpdater
#endif

enum SettingsTab: Hashable, CaseIterable {
    case dashboard
    case memory
    case meetings
    case dictionary
    case commands
    case vibeCoding
    case general

    var title: String {
        switch self {
        case .dashboard:   return "Dashboard"
        case .memory:      return "Memory"
        case .meetings:    return "Meetings"
        case .dictionary:  return "Dictionary"
        case .commands:    return "Commands"
        case .vibeCoding:  return "Vibe Coding"
        case .general:     return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard:   return "square.grid.2x2.fill"
        case .memory:      return "brain"
        case .meetings:    return "person.2.fill"
        case .dictionary:  return "character.book.closed.fill"
        case .commands:    return "bolt.fill"
        case .vibeCoding:  return "chevron.left.forwardslash.chevron.right"
        case .general:     return "gearshape.fill"
        }
    }

    /// Per-item macaw-feather tint for the sidebar (v2). Feature tabs wear a
    /// feather hue; Settings rides the brand blue.
    var tint: Color {
        switch self {
        case .dashboard:   return Theme.featherCoral
        case .memory:      return Theme.featherGold
        case .meetings:    return Theme.featherPlum
        case .dictionary:  return Theme.featherGreen
        case .commands:    return Theme.featherPlum
        case .vibeCoding:  return Theme.featherBlue
        case .general:     return Theme.coral
        }
    }
}

/// A push-navigation route *inside* the Settings tab (L6a). The Settings root is
/// a flat index of grouped cards (HYBRID IA); only these three genuinely deep
/// areas push to a child screen rather than crowding the root. The cases are the
/// scaffold — L6b (`allLanguages`), L6c (`meetings`), and L6d (`verifyClaims`)
/// fill in the real destinations; until then they resolve to a placeholder so the
/// route is navigable and the build stays green.
enum SettingsPage: Hashable {
    /// L6b — the full "All languages" picker (root shows only a selected strip).
    case allLanguages
    /// L6c — the Meetings settings subpage (also the deep-link target for the
    /// Meetings tab, via `SettingsRouter.pendingPage`).
    case meetings
    /// L6d — the "Verify our claims" zero-network proof surface.
    case verifyClaims
}

@MainActor
final class SettingsRouter: ObservableObject {
    @Published var selectedTab: SettingsTab = .dashboard

    /// A subpage another tab wants Settings to open when it next appears (L6a
    /// scaffold, consumed by L6c's Meetings deep link). Purely additive: nothing
    /// sets it yet, and the Settings root drains it on appear, so a `nil` here is
    /// the normal "just show the index" case.
    @Published var pendingPage: SettingsPage?
}

/// The app's main window (Dock app). A Claude-style sidebar shell hosting the
/// dashboard, history, and settings panes.
///
/// It is the window's `NSWindowDelegate` so it can tell `AppDelegate` when the
/// user *genuinely* closes the window (not merely miniaturizes it, and not while
/// a sheet is up). On a genuine close the app drops its Dock icon and lives on as
/// a menu-bar item (H7) — the window is the whole toggle, fully reversible by
/// reopening from the status menu or Spotlight/Finder.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let router = SettingsRouter()

    /// Called from `windowWillClose` on a genuine close (no attached sheet).
    /// `AppDelegate` sets this to flip the activation policy to `.accessory`
    /// (Dock icon disappears; status item + hotkey remain). Never fires for a
    /// miniaturize (that isn't a close) or while a sheet like `NSOpenPanel` is up.
    var onGenuineClose: (() -> Void)?

    init(
        settings: AppSettings,
        dictionary: DictionaryStore,
        permissions: PermissionsModel,
        history: HistoryStore,
        stats: StatsStore,
        appUsage: AppUsageStore,
        activity: ActivityStore,
        wordFreq: WordFrequencyStore,
        jobTitle: JobTitleStore,
        latency: LatencyStore,
        systemPressure: SystemPressure,
        scratchpad: ScratchpadStore,
        profileImage: ProfileImageStore,
        autoAddPreviewLog: AutoAddPreviewLog,
        projectIndex: ProjectIndexStore,
        contextSummary: ContextSummaryStore,
        meetingRecorder: MeetingRecorder,
        meetingStore: MeetingStore,
        contextGraph: ContextGraphStore,
        macros: MacroStore,
        profiles: AppProfileStore,
        searchEngine: SearchEngine,
        nicheVocab: NicheVocabStore,
        commandRouter: CommandRouter,
        hud: HUDController,
        onRetryHotKey: @escaping () -> Bool
    ) {
        let root = MainView(
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
            router: router,
            onRetryHotKey: onRetryHotKey
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Talkie"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // Opaque v2 canvas; NavigationSplitView supplies the Liquid Glass sidebar.
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: 0x000000) : NSColor(hex: 0xFFFFFF)
        }
        window.contentView = NSHostingView(rootView: root)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("TalkieMainWindow")
        window.center()
        super.init()
        // Observe close so the app can vanish into the menu bar (H7). The window
        // outlives the close (`isReleasedWhenClosed = false`) and this controller
        // is retained by `AppDelegate`, so reopening reuses the same instance.
        window.delegate = self
    }

    func show(tab: SettingsTab) {
        router.selectedTab = tab
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: NSWindowDelegate

    /// Fires on a genuine window close. We guard against a sheet being up
    /// (`NSOpenPanel`/`NSSavePanel` attach as `attachedSheet`) — closing while a
    /// sheet is presented shouldn't strip the Dock icon. A miniaturize never routes
    /// here (it isn't a close), so no extra guard is needed for that. `AppDelegate`
    /// does the actual `.accessory` flip via `onGenuineClose`.
    func windowWillClose(_ notification: Notification) {
        guard window.attachedSheet == nil else { return }
        onGenuineClose?()
    }
}

struct MainView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var dictionary: DictionaryStore
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var history: HistoryStore
    @ObservedObject var stats: StatsStore
    @ObservedObject var appUsage: AppUsageStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var wordFreq: WordFrequencyStore
    /// L5-b: the on-device invented job title, shown on the Milestones page.
    @ObservedObject var jobTitle: JobTitleStore
    @ObservedObject var latency: LatencyStore
    @ObservedObject var systemPressure: SystemPressure
    @ObservedObject var scratchpad: ScratchpadStore
    /// L7: the optional profile picture, forwarded to the dashboard header, the
    /// meeting rows, and `MemoryView` (whose "Clear everything" clears it too).
    @ObservedObject var profileImage: ProfileImageStore
    /// L2-b (LOG-ONLY): forwarded to `MemoryView` only so its true-delete cascade can
    /// purge the AI-auto-add calibration log. Not `@ObservedObject` — this log drives
    /// no UI, so nothing here should redraw when it changes.
    let autoAddPreviewLog: AutoAddPreviewLog
    @ObservedObject var projectIndex: ProjectIndexStore
    @ObservedObject var contextSummary: ContextSummaryStore
    @ObservedObject var meetingRecorder: MeetingRecorder
    @ObservedObject var meetingStore: MeetingStore
    @ObservedObject var contextGraph: ContextGraphStore
    @ObservedObject var macros: MacroStore
    @ObservedObject var profiles: AppProfileStore
    @ObservedObject var searchEngine: SearchEngine
    @ObservedObject var nicheVocab: NicheVocabStore
    let commandRouter: CommandRouter
    let hud: HUDController
    @ObservedObject var router: SettingsRouter
    let onRetryHotKey: () -> Bool

    var body: some View {
        Group {
            if settings.hasOnboarded {
                NavigationSplitView {
                    SidebarList(router: router, settings: settings, permissions: permissions)
                } detail: {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(Theme.canvas)
                }
                .transition(.opacity)
            } else {
                OnboardingView(settings: settings, permissions: permissions, onRetryHotKey: onRetryHotKey)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .animation(.easeInOut(duration: 0.4), value: settings.hasOnboarded)
    }

    @ViewBuilder
    private var content: some View {
        switch router.selectedTab {
        case .dashboard:
            DashboardView(settings: settings, stats: stats, history: history,
                          activity: activity, appUsage: appUsage,
                          scratchpad: scratchpad, profileImage: profileImage,
                          wordFreq: wordFreq,
                          jobTitle: jobTitle,
                          latency: latency, pressure: systemPressure, router: router)
        case .meetings:
            MeetingsView(recorder: meetingRecorder, store: meetingStore,
                         settings: settings, profileImage: profileImage)
        case .dictionary:
            DictionarySettings(dictionary: dictionary, nicheVocab: nicheVocab)
        case .memory:
            MemoryView(contextGraph: contextGraph, history: history,
                       searchEngine: searchEngine, meetingStore: meetingStore,
                       wordFreq: wordFreq, scratchpad: scratchpad,
                       autoAddPreviewLog: autoAddPreviewLog,
                       contextSummary: contextSummary,
                       jobTitle: jobTitle, profileImage: profileImage)
        case .commands:
            CommandsView(settings: settings, macros: macros,
                         commandRouter: commandRouter, hud: hud,
                         meetingStore: meetingStore)
        case .vibeCoding:
            VibeCodingView(projectIndex: projectIndex, settings: settings)
        case .general:
            SettingsHome(settings: settings, permissions: permissions,
                         profiles: profiles,
                         history: history, router: router, onRetryHotKey: onRetryHotKey)
        }
    }
}

// MARK: - Sidebar (native macOS 26 Liquid Glass)

/// The system sidebar: a `List` inside `NavigationSplitView` gets the floating
/// Liquid Glass material automatically on macOS 26. Per-row feather tints come
/// from `.listItemTint`; the wordmark rides the toolbar, the activation hint
/// pins to the bottom.
private struct SidebarList: View {
    @ObservedObject var router: SettingsRouter
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsModel

    private var selection: Binding<SettingsTab?> {
        Binding(
            get: { router.selectedTab },
            set: { router.selectedTab = $0 ?? router.selectedTab }
        )
    }

    var body: some View {
        List(SettingsTab.allCases, id: \.self, selection: selection) { tab in
            Label(LocalizedStringKey(tab.title), systemImage: tab.icon)
                .listItemTint(tab.tint)
                .badge(tab == .general && !permissions.allGranted ? 1 : 0)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 260)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(text: "Hold to talk · tap twice to lock")
                Text(settings.activationKey.displayName)
                    .font(.talkieHeading(12, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }
}

/// Page header used by the non-dashboard panes — serif title + subtitle.
struct PageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title))
                .font(.talkieDisplay(26))
                .foregroundStyle(Theme.ink)
            if let subtitle {
                Text(LocalizedStringKey(subtitle))
                    .font(.talkieHeading(13, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - General

/// Settings landing — a flat index of plainly-labeled groups on one scrolling
/// page, wrapped in a `NavigationStack` (L6a HYBRID IA). Most groups render their
/// cards inline; only three genuinely deep areas — All languages (L6b), Meetings
/// (L6c), and Verify our claims (L6d) — push to a child screen via a
/// `SettingsPage` route so the root stays a legible index instead of an endless
/// scroll. Each group carries a `SettingsSectionHeader` (sentence case, larger,
/// `Theme.ink`) so section titles read a clear rung above the card `Eyebrow`s
/// nested under them. Another tab can request a subpage by setting
/// `SettingsRouter.pendingPage`; the root drains it on appear (consumed by L6c).
private struct SettingsHome: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var profiles: AppProfileStore
    @ObservedObject var history: HistoryStore
    @ObservedObject var router: SettingsRouter
    let onRetryHotKey: () -> Bool

    /// The push-navigation stack path. Held here so `SettingsRouter.pendingPage`
    /// can deep-link a subpage: on appear (and on any later change) we drain the
    /// pending page onto this path, then clear it (L6a scaffold; L6c drives it).
    @State private var path: [SettingsPage] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    PageHeader(title: "Settings",
                               subtitle: "Tune how Talkie listens, cleans up, and behaves.")

                    // H1: the dedicated Profile section is gone — your name is edited inline
                    // on the Dashboard header now (click "Welcome back, …"). One fewer group.
                    //
                    // ── 1. Dictation ─────────────────────────────────────────────
                    section("Dictation",
                            subtitle: "Your dictation key, how text lands, and the mic.") {
                        ActivationSettings(settings: settings)
                        MicrophoneSettings(settings: settings)
                    }
                    // ── 2. Cleanup & intelligence ────────────────────────────────
                    // Smart cleanup sits beside the Context-awareness + Learning
                    // toggles as one story (L6e). The old Memory count card was
                    // retired — the sidebar Memory tab is the surface for those
                    // counts — so `ContextSettings` no longer needs the context
                    // graph or the router.
                    section("Cleanup & intelligence",
                            subtitle: "How Talkie polishes text and learns your words.") {
                        CleanupSettings(settings: settings)
                        ContextSettings(settings: settings)
                    }
                    // ── 3. Languages ─────────────────────────────────────────────
                    // L6b REPLACES the full grid with a compact selected-strip plus an
                    // "All languages" push (`SettingsPage.allLanguages`, wired in the
                    // NavigationStack below). For now the whole grid renders inline.
                    section("Languages",
                            subtitle: "Which languages you speak; Talkie auto-detects.") {
                        // ⇥ L6b slot: selected-strip + NavigationLink(value: SettingsPage.allLanguages).
                        LanguageSettings(settings: settings)
                    }
                    // ── 4. Apps ──────────────────────────────────────────────────
                    section("Apps",
                            subtitle: "Per-app cleanup styles for the apps you customize.") {
                        AppProfilesSettings(profiles: profiles)
                    }
                    // ── 5. Meetings ──────────────────────────────────────────────
                    // L6c MOUNTS a Meetings row here that pushes `SettingsPage.meetings`
                    // (also the deep-link target for the Meetings tab via `pendingPage`).
                    // Calendar context — reading meeting names — belongs to this group.
                    section("Meetings",
                            subtitle: "Recording, transcription, and calendar context.") {
                        // ⇥ L6c slot: Meetings row → NavigationLink(value: SettingsPage.meetings).
                        CalendarSettings()
                    }
                    // ── 6. Notes & export ────────────────────────────────────────
                    // Dictation notes route through the same `ExportPreferences` as
                    // meeting notes, so "Notes & export" is the honest label. The
                    // general app-behavior toggles (sounds, login, floating bird) ride
                    // along here rather than spawning a ninth group.
                    section("Notes & export",
                            subtitle: "Where notes and transcripts go, plus app behavior.") {
                        ExportDestinationsSettings()
                        BehaviorSettings(settings: settings)
                    }
                    // ── 7. Claude ────────────────────────────────────────────────
                    // The public "Connect to Claude" card lives at the root (H1 hoisted it
                    // out of the Developer section, which is now hidden in normal builds).
                    // It ships with every install and is 100% on-device, so it belongs in
                    // front of every user, not behind a dev flag.
                    section("Claude",
                            subtitle: "Let Claude read your meetings and context, on-device.") {
                        MCPConnectorCard()
                    }
                    // ── 8. Privacy & permissions ─────────────────────────────────
                    // L6d collapses the proofs behind a "Verify our claims" push
                    // (`SettingsPage.verifyClaims`), keeping the permission levers inline.
                    section("Privacy & permissions",
                            subtitle: "The permissions Talkie needs and proof nothing leaves.") {
                        // ⇥ L6d slot: "Verify our claims" row → NavigationLink(value: SettingsPage.verifyClaims).
                        PrivacyAndPermissionsSettings(settings: settings, permissions: permissions,
                                                      history: history, onRetryHotKey: onRetryHotKey)
                    }
                    // H1: the Developer section is hidden in a normal public build. It
                    // reappears in Debug builds, when `TalkieDevMode` is set in defaults, or
                    // in `TALKIE_DEV_TOOLS` dev-channel builds (see `showDeveloperSection`).
                    if showDeveloperSection {
                        section("Developer",
                                subtitle: "Tools that ship only in development builds.") {
                            DeveloperSettings(settings: settings)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.canvas)
            // HYBRID push destinations (L6a scaffold). Each case resolves to a
            // placeholder subpage for now; L6b/L6c/L6d swap in the real panes. The
            // routes are navigable today so the scaffold is verifiable.
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .allLanguages:
                    // L6b fills this in with the full picker.
                    SubpagePlaceholder(
                        title: "All languages",
                        subtitle: "The full language picker will live here.")
                case .meetings:
                    // L6c fills this in with the Meetings settings pane.
                    SubpagePlaceholder(
                        title: "Meetings",
                        subtitle: "Meeting recording and transcription settings will live here.")
                case .verifyClaims:
                    // L6d — the full zero-network proof detail: the three
                    // verify-yourself commands, the live entitlement list, and the
                    // data-locations bullets, relocated off the root intact.
                    VerifyClaimsSubpage()
                }
            }
        }
        // Deep-link drain: if another tab asked for a subpage, push it and clear
        // the request. Runs on first appear and whenever the request changes, so a
        // link set while Settings is already open still lands (L6c).
        .onAppear { drainPendingPage() }
        .onChange(of: router.pendingPage) { _, _ in drainPendingPage() }
    }

    /// Consume `SettingsRouter.pendingPage`: push it onto the nav path and clear
    /// it. No-op when nothing is pending (the common case). Additive scaffolding —
    /// nothing sets `pendingPage` until L6c.
    private func drainPendingPage() {
        guard let page = router.pendingPage else { return }
        path = [page]
        router.pendingPage = nil
    }

    /// A settings group: a `SettingsSectionHeader` (sentence case, `Theme.ink`,
    /// a rung larger than the card `Eyebrow`) over a one-line plain-language
    /// subtitle, then the group's cards. The header is deliberately NOT an
    /// `Eyebrow`: card headers keep `Eyebrow`, so a group title and a card title
    /// no longer render pixel-identical (the L6a typography fix).
    @ViewBuilder
    private func section<Content: View>(_ title: String, subtitle: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeader(title: title, subtitle: subtitle)
            content()
        }
    }

    /// Whether the Developer section is shown (H1). It's hidden in a plain public
    /// Release build and reappears in three cases:
    ///   • `Dev.isEnabled` — a Debug build, or `TalkieDevMode` set in defaults
    ///     (`defaults write com.coralate.talkie TalkieDevMode -bool YES`), and
    ///   • `TALKIE_DEV_TOOLS` dev-channel builds — which are *Release* builds
    ///     (`run.sh`/`release_dev.sh` build `-c release`), so `Dev.isEnabled` is false
    ///     there. We must still show the section in that case, because the in-app
    ///     updater (`AppUpdateSection`, compiled only under `TALKIE_DEV_TOOLS`) lives
    ///     inside it — gating on `Dev.isEnabled` alone would strand dev-channel
    ///     collaborators without a way to pull the next build.
    private var showDeveloperSection: Bool {
        #if TALKIE_DEV_TOOLS
        return true
        #else
        return Dev.isEnabled
        #endif
    }
}

/// The header for a top-level Settings *group* (L6a). Deliberately distinct from
/// the card `Eyebrow` so the two rungs of the hierarchy read apart: this is
/// SENTENCE CASE, `.talkieHeading(13, weight: .semibold)`, and `Theme.ink`,
/// whereas `Eyebrow` is UPPERCASED, 11pt semibold, and `Theme.inkSecondary`
/// (DesignSystem.swift). That's four differing attributes — size (13 vs 11),
/// color (ink vs inkSecondary), case (sentence vs upper), and tracking (none vs
/// 0.8) — so a group title no longer looks pixel-identical to the card titles
/// nested beneath it. Lives here, not in DesignSystem.swift (which is read-only).
struct SettingsSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title))
                .font(.talkieHeading(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
            if let subtitle {
                Text(LocalizedStringKey(subtitle))
                    .font(.talkieHeading(12, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

/// A stand-in destination for the three HYBRID subpages until L6b/L6c/L6d build
/// the real panes (L6a scaffold). Reuses `SubPage` so the placeholder already
/// wears the app's serif header + canvas, and a `back`-able `NavigationStack`
/// push is demonstrably working. Not shipped to users in normal flow — nothing
/// links to these routes yet; they exist so the scaffold is verifiable.
private struct SubpagePlaceholder: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        SubPage(title: title, subtitle: subtitle) {
            SettingsCard {
                SettingsNote(
                    text: "This settings page is coming soon.".loc,
                    tone: Theme.inkTertiary,
                    icon: "hammer")
            }
        }
    }
}

/// Developer tools — replaying the first-run onboarding, the diagnostic bundle, and
/// the on-device jargon-bias A/B probe. Hidden in a normal public build (H1); the
/// enclosing section only renders when `SettingsHome.showDeveloperSection` is true
/// (a Debug build, the `TalkieDevMode` defaults escape hatch, or a `TALKIE_DEV_TOOLS`
/// dev-channel build). The public "Connect to Claude" card used to live here too —
/// H1 hoisted it out to its own root "Claude" section so it stays reachable when this
/// section is hidden.
private struct DeveloperSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var replaying = false
    // A14 dark flag (`Dev.llmJargonRepair`). Bound to the same defaults key so the
    // measurement prototype is toggleable here instead of via `defaults write`.
    // Lives ONLY in the (dev-gated) Developer section — it is not a user setting.
    @AppStorage(Dev.llmJargonRepairKey) private var llmJargonRepair = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            #if TALKIE_DEV_TOOLS
            AppUpdateSection()
            #endif
            SettingsCard(
                header: "Onboarding",
                footer: "Replays the first-run welcome flow so you can review it — or just see it again on this Mac. Your name, settings, history, and dictionary are untouched."
            ) {
                SettingsRow(
                    title: "First-run onboarding",
                    subtitle: replaying ? "Opening the welcome flow…" : "Show the welcome flow again"
                ) {
                    Button("Replay") {
                        replaying = true
                        // Defer a tick so the button's press settles before the
                        // whole window crossfades over to onboarding.
                        DispatchQueue.main.async { settings.hasOnboarded = false }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
                    .disabled(replaying)
                }
            }

            ImproveTalkieCard(settings: settings)

            // Gate-zero check for the niche-vocabulary feature: does on-device
            // contextualStrings biasing actually move recognition? Test it by talking.
            if BiasABProbe.isAvailable {
                BiasABTestView()
            }

            // A14 (DARK): the on-device LLM jargon-repair spike. OFF by default and
            // unproven — it runs an extra on-device model pass after the phonetic
            // corrector to rescue badly-mangled jargon, admitting ONLY changes that
            // insert a known term (diff kill-switch; worst case a no-op). Leaving it
            // off keeps dictation output byte-identical. Live wiring awaits a
            // jargon-corpus WER benchmark, so this is for measurement only.
            SettingsCard(
                header: "LLM jargon repair (experimental)",
                footer: "Runs an extra on-device model pass to fix badly-mangled jargon the phonetic corrector can't catch (e.g. \"cloud MD\" → \"Claude.md\"). It can only insert your known terms — never rewrite anything else. Off by default; unproven, for measurement."
            ) {
                SettingsToggleRow(
                    title: "Repair mangled jargon with the on-device LLM",
                    subtitle: LLMJargonRepair.isAvailable
                        ? "Post-hoc, after the phonetic corrector. Guarded so it can only swap in your saved terms."
                        : "Needs Apple Intelligence to be on.",
                    isOn: $llmJargonRepair
                )
            }
        }
    }
}

/// "Connect to Claude" — the one-click connector card. Every installed Talkie.app
/// now bundles the `talkie-mcp` stdio server (Contents/MacOS/talkie-mcp) plus a
/// ready-to-install `.mcpb` (Contents/Resources/Talkie.mcpb), so this works with no
/// checkout, no `swift build`, and no maker-specific paths. Two rows: Claude Desktop
/// (hand the `.mcpb` to the OS handler) and Claude Code / other MCP clients (copy the
/// exact `mcpServers` config or the `claude mcp add` one-liner, both pointing at the
/// resolved binary path). 100% on-device — the server only reads your local stores.
private struct MCPConnectorCard: View {
    /// The `talkie-mcp` binary this machine should use. Prefers the copy bundled
    /// inside THIS app (the common case for every installed Talkie); falls back to
    /// the two dev-checkout build paths so a maker running from source still gets a
    /// live path instead of the old "not built yet" dead end.
    private static func binaryPath() -> String? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/talkie-mcp").path
        let home = NSHomeDirectory()
        let candidates = [
            bundled,
            "\(home)/Talkie/.build/release/talkie-mcp",   // dev checkout (release)
            "\(home)/Talkie/.build/debug/talkie-mcp",     // dev checkout (debug)
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The `.mcpb` bundled beside the app, if present.
    private static func mcpbURL() -> URL? {
        guard let url = Bundle.main.url(forResource: "Talkie", withExtension: "mcpb") else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The exact `mcpServers` config both Claude Desktop and Claude Code accept
    /// (the old `{"tools": …}` shape was rejected by both).
    private static func mcpServersJSON(_ path: String) -> String {
        // Hand-rolled so the shape is guaranteed and escaping stays predictable;
        // macOS paths don't contain quotes/backslashes in practice, but escape the
        // two JSON-significant characters defensively anyway.
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "mcpServers": {
            "talkie": {
              "command": "\(escaped)"
            }
          }
        }
        """
    }

    /// `claude mcp add <name> -- <command>`; quote the path in case it lives
    /// somewhere with spaces.
    private static func claudeAddCommand(_ path: String) -> String {
        "claude mcp add talkie -- \"\(path)\""
    }

    /// One chip in the "What Claude can do" strip. `write == true` marks a tool that
    /// only QUEUES a suggestion for the user to confirm (the two A5 teach-back tools);
    /// those render tinted with an "asks first" suffix so the disclosure is honest —
    /// the reads are silent-auto, the writes ask. This list is the third hand-kept
    /// mirror of the tool set (alongside MCPServer.toolSpecs and connector/manifest.json
    /// tools[]); scripts/check-mcp-drift.sh fails CI if the three ever disagree.
    private struct ToolChip: Identifiable { let name: String; let write: Bool; var id: String { name } }
    private let toolChips: [ToolChip] = [
        .init(name: "list_meetings", write: false),
        .init(name: "get_meeting", write: false),
        .init(name: "get_brief", write: false),
        .init(name: "list_commitments", write: false),
        .init(name: "lookup_entity", write: false),
        .init(name: "search", write: false),
        .init(name: "get_recent_context", write: false),
        .init(name: "graph_query", write: false),
        .init(name: "get_stats", write: false),
        .init(name: "get_dictionary", write: false),
        .init(name: "list_dictations", write: false),
        .init(name: "read_scratchpad", write: false),
        .init(name: "add_vocabulary_term", write: true),
        .init(name: "add_replacement", write: true),
        .init(name: "remove_replacement", write: true),
        .init(name: "update_replacement", write: true),
        .init(name: "remove_vocabulary_term", write: true),
    ]

    @State private var copiedConfig = false
    @State private var copiedCommand = false
    @State private var copiedPrompt = false
    @State private var desktopStatus: String?

    private var path: String? { Self.binaryPath() }

    var body: some View {
        SettingsCard(
            header: "Connect to Claude",
            footer: "Talkie ships a tiny local server so Claude can read your meetings, brief, commitments, context, stats, dictionary, and notes — on-device, nothing leaves your Mac. Claude can also manage your dictionary — adding, changing, or removing terms and rules — but every change waits for your one-tap confirmation with an Undo. Bundled with the app: no separate download or build.".loc
        ) {
            if let path {
                // (a) Claude Desktop — one double-click via the bundled .mcpb.
                SettingsRow(
                    title: "Claude Desktop".loc,
                    subtitle: desktopStatus ?? "Install the connector with one click".loc
                ) {
                    Button("Install…") { openDesktopConnector() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.coral)
                        .disabled(Self.mcpbURL() == nil)
                }
                SettingsDivider()

                // (b) Claude Code / other MCP clients — copyable config + CLI one-liner.
                SettingsRow(
                    title: "Claude Code & other MCP clients".loc,
                    subtitle: "Add this to your .mcp.json, or run the command".loc
                ) {
                    Button {
                        copyToPasteboard(Self.mcpServersJSON(path))
                        flash($copiedConfig)
                    } label: {
                        Label(copiedConfig ? "Copied".loc : "Copy config".loc,
                              systemImage: copiedConfig ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.coral)
                }
                SettingsRow(title: "Or from the terminal".loc) {
                    Button {
                        copyToPasteboard(Self.claudeAddCommand(path))
                        flash($copiedCommand)
                    } label: {
                        Label(copiedCommand ? "Copied".loc : "Copy command".loc,
                              systemImage: copiedCommand ? "checkmark" : "terminal")
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.coral)
                }
                // (c) Let Claude wire itself up: a paste-into-Claude prompt that has it
                // run the add command, learn the tools, and honestly frame the writes
                // (queued, confirmed in Talkie with an Undo) — then verify with `search`.
                SettingsRow(
                    title: "Or let Claude set it up".loc,
                    subtitle: "Paste this into Claude and it connects the server itself".loc
                ) {
                    Button {
                        copyToPasteboard(MCPSetupPrompt.setupPrompt(binaryPath: path))
                        flash($copiedPrompt)
                    } label: {
                        Label(copiedPrompt ? "Copied".loc : "Copy setup prompt".loc,
                              systemImage: copiedPrompt ? "checkmark" : "text.bubble")
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.coral)
                }
                SettingsDivider()

                // The tools Claude gains, as chips. Reads render plainly; the two
                // teach-back writes are tinted with an "asks first" suffix so the
                // disclosure is honest (reads auto-run, writes wait for a tap).
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "What Claude can do")
                    FlowLayout(spacing: 6) {
                        ForEach(toolChips) { chip in
                            HStack(spacing: 4) {
                                Text(chip.name)
                                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                if chip.write {
                                    Text("asks first".loc)
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .textCase(.uppercase)
                                }
                            }
                            .foregroundStyle(chip.write ? Theme.coralDeep : Theme.inkSecondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                    .fill(chip.write ? Theme.coralWash : Theme.surface)
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            } else {
                // Only reachable from a checkout with no built binary — bundle users
                // always have Contents/MacOS/talkie-mcp. Softened, honest copy.
                SettingsNote(
                    text: "The connector binary isn't here yet. Run this app from a built Talkie.app (./scripts/run.sh) and it ships bundled — no extra step.".loc,
                    tone: Theme.inkTertiary
                )
            }
        }
    }

    /// Hands the bundled `.mcpb` to the OS. Claude Desktop registers itself as the
    /// `.mcpb` handler, so `open` launches its install dialog; if no handler is
    /// registered (Claude Desktop not installed), fall back to revealing the file in
    /// Finder so the user can drag it in manually (plan 07 §"Reveal in Finder").
    private func openDesktopConnector() {
        guard let url = Self.mcpbURL() else {
            desktopStatus = "Connector file not found in this build".loc
            return
        }
        if NSWorkspace.shared.open(url) {
            desktopStatus = "Opened in Claude Desktop".loc
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            desktopStatus = "Revealed in Finder — drag it into Claude Desktop".loc
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func flash(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        Task { try? await Task.sleep(for: .seconds(1.4)); flag.wrappedValue = false }
    }
}

/// "Improve Talkie" — the one-click, preview-before-copy bug bundle (K8). Gathers
/// version, environment, a whitelisted settings snapshot, permission states, and a
/// REDACTED tail of the debug log, then shows it to the user IN FULL before
/// anything touches the clipboard. A second button opens a pre-filled GitHub issue
/// in the browser (section headers only — the bundle is never put in the URL).
///
/// Preview-before-copy is a hard requirement: `BugBundle.gather` runs when the
/// sheet opens, the full text is shown scrollable + selectable, and ONLY the
/// sheet's own Copy button writes the pasteboard. Nothing reaches the clipboard
/// before the user has seen the exact bytes.
private struct ImproveTalkieCard: View {
    @ObservedObject var settings: AppSettings
    /// A private permissions probe just for the bundle. `refresh()` reads live TCC
    /// state, so a fresh instance reports the same grants as the shared model —
    /// this keeps the card self-contained (no new init parameter on DeveloperSettings).
    @StateObject private var permissions = PermissionsModel()
    @State private var previewing = false

    var body: some View {
        SettingsCard(
            header: "Improve Talkie",
            footer: "Builds a diagnostic bundle — version, this Mac's setup, your settings, and a redacted tail of the debug log — so a bug report has what it needs. You see the whole thing before anything is copied, and your name, dictionary, history, and dictated words are never included."
        ) {
            SettingsRow(
                title: "Diagnostic bundle",
                subtitle: "Review it in full, then copy — nothing is copied until you do"
            ) {
                Button("Review…") { previewing = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
            }
            if Brand.repoURL != nil {
                SettingsDivider()
                SettingsRow(
                    title: "Report a bug",
                    subtitle: "Opens Talkie's GitHub in your browser to file an issue"
                ) {
                    Button {
                        openIssue()
                    } label: {
                        Label("Open GitHub", systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.coral)
                }
            }
        }
        .sheet(isPresented: $previewing) {
            BugBundlePreviewSheet(
                text: BugBundle.gather(settings: settings, permissions: permissions)
            ) { previewing = false }
        }
    }

    /// Hand a pre-filled "new issue" link to the user's browser. The body carries
    /// SECTION HEADERS ONLY (an instruction to paste the reviewed bundle), never the
    /// bundle itself — so no diagnostic content travels in the URL. The base URL
    /// comes from `Brand.repoURL` (Info.plist), so there is no hard-coded web URL in
    /// Swift; `NSWorkspace.open` is itself gate-clean (nothing is fetched here).
    private func openIssue() {
        guard let base = Brand.repoURL else { return }
        let body = """
        Thanks for helping improve Talkie! Please describe what happened, then \
        paste the diagnostic bundle you reviewed (Settings ▸ Developer ▸ Improve \
        Talkie ▸ Review…) below.

        ## What happened

        ## What you expected

        ## Diagnostic bundle
        <!-- paste the reviewed bundle here -->
        """
        var comps = URLComponents(string: base + "/issues/new")
        comps?.queryItems = [
            URLQueryItem(name: "title", value: "Bug report"),
            URLQueryItem(name: "body", value: body),
        ]
        // Browser handoff only — opened in the user's browser, never fetched in-process
        // (the base URL lives in Info.plist, so no web URL literal appears in Swift).
        if let url = comps?.url { NSWorkspace.shared.open(url) }
    }
}

/// The preview-before-copy sheet: the FULL bundle text, scrollable and selectable,
/// with the ONLY control that can write the clipboard. The user reads the exact
/// bytes here first; `Copy` is the single path to the pasteboard.
private struct BugBundlePreviewSheet: View {
    let text: String
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostic bundle").font(.talkieHeading(16, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("This is exactly what will be copied — read it first. Nothing has been copied yet.")
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
            }

            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 320)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surface)
            )

            HStack(spacing: 10) {
                Spacer()
                Button("Close") { onClose() }
                    .buttonStyle(.bordered)
                Button {
                    copyToClipboard()
                } label: {
                    Label(copied ? "Copied".loc : "Copy".loc,
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.coral)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .background(Theme.canvas)
    }

    /// The one and only write to the pasteboard in this feature — reached only from
    /// the sheet's Copy button, after the user has seen the full text above.
    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
    }
}

#if TALKIE_DEV_TOOLS
/// "App updates" — the in-app updater UI (dev-tools flavor only). Lets a
/// collaborator pull the newest Talkie that was published to GitHub, swap this
/// app in place, and relaunch — so they always have the latest without rebuilding
/// from source. All networking lives in the separate `TalkieUpdater` module; this
/// view only observes its state, so the on-device core stays free of network code.
private struct AppUpdateSection: View {
    @ObservedObject private var updater = AppUpdater.shared
    @State private var tokenField = ""

    var body: some View {
        SettingsCard(
            header: "App updates",
            footer: "Pulls the newest Talkie published to GitHub, swaps this app in place, and relaunches — so you always have the latest without rebuilding. This updater is compiled only into dev builds; the public build ships no update or network code."
        ) {
            SettingsRow(title: "This build", subtitle: "Version \(updater.currentVersion)") {
                Text("build \(updater.currentBuild)")
                    .font(.talkieHeading(13, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
            }
            SettingsDivider()
            statusRow
            if updater.auth == .none {
                SettingsDivider()
                tokenSetup
            }
            SettingsDivider()
            SettingsToggleRow(
                title: "Check for updates when Talkie launches",
                subtitle: "Offers the newest build a few seconds after you open Talkie.",
                isOn: $updater.autoCheckOnLaunch
            )
        }
        .onAppear {
            if updater.auth != .none, case .idle = updater.state {
                Task { await updater.check() }
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch updater.state {
        case .idle, .upToDate, .failed:
            SettingsRow(title: idleTitle, subtitle: idleSubtitle) {
                Button("Check now") { Task { await updater.check() } }
                    .buttonStyle(.bordered)
            }
        case .checking:
            SettingsRow(title: "Checking for updates…") {
                ProgressView().controlSize(.small)
            }
        case .available(let release):
            SettingsRow(
                title: "Build \(release.build) is available",
                subtitle: release.notes.isEmpty
                    ? "Newer than your build \(updater.currentBuild)."
                    : release.notes
            ) {
                Button("Update") { Task { await updater.downloadAndInstall() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
            }
        case .downloading(let progress):
            SettingsRow(title: "Downloading the update…") {
                if let progress {
                    ProgressView(value: progress).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        case .installing:
            SettingsRow(title: "Installing and relaunching…") {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var idleTitle: String {
        switch updater.state {
        case .upToDate: return "You're on the latest build"
        case .failed:   return "Couldn't check for updates"
        default:        return "Check for a newer Talkie"
        }
    }

    private var idleSubtitle: String? {
        switch updater.state {
        case .upToDate:
            return "Build \(updater.currentBuild) is current."
        case .failed(let message):
            return message
        default:
            switch updater.auth {
            case .githubCLI: return "Connected via the GitHub CLI."
            case .token:     return "Connected with your saved token."
            case .none:      return nil
            }
        }
    }

    @ViewBuilder private var tokenSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Talkie's repo is private, so the updater needs read access. Either run `gh auth login` in Terminal, or paste a GitHub token with read access to the repo (github.com/settings/tokens).")
                .font(.callout)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecureField("GitHub access token", text: $tokenField)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    updater.saveToken(tokenField)
                    tokenField = ""
                    Task { await updater.check() }
                }
                .buttonStyle(.bordered)
                .disabled(tokenField.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}
#endif

/// Shared scaffold for every settings subpage: a serif page header above a
/// vertical stack of brand-surface cards on the pure canvas. Replaces the old
/// bare grouped `Form` so each subpage matches the Dictionary / Vibe Coding /
/// Permissions panes — one unified, layered-surface look.
///
/// Internal (not `private`) so the new panes under `Settings/` — Voice commands,
/// Per-app rules, Calendar, Export, Privacy — reuse the exact same scaffold and
/// row/card vocabulary rather than inventing a parallel look.
struct SubPage<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: title, subtitle: subtitle)
                content
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .navigationTitle("")
    }
}

/// A titled settings card: an optional all-caps eyebrow header, a raised brand
/// surface holding hairline-divided rows, and an optional footer note on the
/// canvas. The single building block that unifies the subpages.
struct SettingsCard<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let header { Eyebrow(text: header).padding(.horizontal, 4) }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .talkieSurface()
            if let footer {
                Text(footer).font(.callout).foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A hairline divider between rows inside a `SettingsCard`, inset past any
/// leading control so it reads as a row separator, never an element outline.
struct SettingsDivider: View {
    var leadingInset: CGFloat = 16
    var body: some View {
        Divider().overlay(Theme.hairline).padding(.leading, leadingInset)
    }
}

/// One row inside a `SettingsCard`: a leading title (+ optional subtitle) and an
/// arbitrary trailing control, consistently padded so every row lines up.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.talkieHeading(14, weight: .medium)).foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle).font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// A switch row on a card surface — title/subtitle left, brand-tinted switch
/// right. Built as an explicit HStack (not a labelled `Toggle`) so the row
/// always spans the card width instead of hugging and centering.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.talkieHeading(14, weight: .medium)).foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle).font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.coral)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// An explanatory note rendered as a full-width row inside a card.
struct SettingsNote: View {
    let text: String
    var tone: Color = Theme.inkSecondary
    var icon: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            }
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(tone)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

private struct MicrophoneSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(
                header: "Microphone",
                footer: "Automatic picks a real microphone for you — handy when a Bluetooth speaker is your audio output but has no mic. Pick a specific device to pin it."
            ) {
                SettingsRow(title: "Input device") {
                    Picker("", selection: $settings.preferredInputDeviceUID) {
                        Text("Automatic (recommended)").tag(String?.none)
                        ForEach(devices) { device in
                            Text(device.name).tag(String?.some(device.uid))
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            SettingsCard(
                header: "Music",
                footer: "Pauses Apple Music or Spotify while you dictate, then resumes it when you stop — and best-effort pauses anything else that's actually playing (browsers, podcasts). macOS will ask for permission to control Music/Spotify the first time."
            ) {
                SettingsToggleRow(title: "Pause music while dictating",
                                  isOn: $settings.pauseMusicWhileDictating)
            }
        }
        .onAppear { devices = AudioDevices.inputDevices() }
    }
}

private struct ActivationSettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(
                header: "Activation",
                // One gesture family for everyone — no mode to choose. Spell it out
                // once here so the picker's removal doesn't leave the behavior a
                // mystery. When a mouse side button is bound we append an honest note
                // that the tap is listen-only, so the button still does its normal job
                // in the front app.
                footer: activationFooter
            ) {
                SettingsRow(title: "Dictation key") {
                    Picker("", selection: $settings.activationKey) {
                        ForEach(ActivationKey.allCases) { key in
                            if let symbol = key.symbolName {
                                Label(key.displayName, systemImage: symbol).tag(key)
                            } else {
                                Text(key.displayName).tag(key)
                            }
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            SettingsCard(
                header: "Insertion",
                // H1 removed the always-safe toggles here: the implicit-command-target
                // fallback and the re-paste chord are now always on (both are safe by
                // construction). The one remaining knob is optimistic insertion.
                // Re-paste still works with the key combo below; the copy-prompt pill
                // still shows it whenever a dictation couldn't find a field to paste into.
                footer: "Talkie pastes instantly and retries with typing if a paste doesn't land, learning the winner per app — no Paste/Type switch needed. Press \(settings.activationKey.pasteShortcut.display) any time to re-paste your most recent transcript into the focused field."
            ) {
                SettingsToggleRow(
                    title: "Insert instantly, polish in place",
                    subtitle: "Experimental — pastes your raw words the moment you stop, then swaps in the cleaned version. May misfire if you keep typing right after.",
                    isOn: $settings.optimisticInsertion
                )
            }
        }
    }

    /// The Activation card's footer. Always explains the gesture family; when the
    /// bound trigger is a mouse side button it also states, honestly, that the tap
    /// is listen-only — the button keeps doing its normal job in the front app, and
    /// it must reach macOS as a real button (vendor drivers that remap it to a
    /// keystroke are out of Talkie's hands).
    private var activationFooter: String {
        let base = "Hold the key and speak, then release to insert. Tap it twice to lock hands-free — recording keeps going with nothing held; tap once to stop and insert.".loc
        guard settings.activationKey.isMouseButton else { return base }
        let note = "The side button still does its normal job in the app you're using — Talkie only listens for it, and it must reach macOS as a real button (some mice remap it in their own software).".loc
        return base + "\n\n" + note
    }
}

private struct CleanupSettings: View {
    @ObservedObject var settings: AppSettings

    private func styleBinding(_ category: AppCategory) -> Binding<CleanupStyle> {
        Binding(
            get: { settings.cleanupStyle(for: category) },
            set: { settings.appCleanupStyles[category.rawValue] = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(header: "Smart cleanup",
                         footer: "A style per kind of app — friendly for Messages, professional for Mail, faithful for code and terminals. The style is the whole story: Off inserts exactly what you said, Faithful only fixes slips, and the others rewrite for tone and clarity.") {
                ForEach(Array(AppCategory.allCases.enumerated()), id: \.element) { index, category in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(title: category.label) {
                        Picker("", selection: styleBinding(category)) {
                            ForEach(CleanupStyle.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                SettingsDivider(leadingInset: 0)
                if let warning = CleanupEngine.unavailableMessage {
                    SettingsNote(text: warning, tone: Theme.warning, icon: "exclamationmark.triangle.fill")
                } else {
                    SettingsNote(text: "Resolves spoken self-corrections and fixes grammar. Runs entirely on your Mac; nothing leaves the device.",
                                 tone: Theme.inkTertiary)
                }
            }
        }
    }
}

private struct LanguageSettings: View {
    @ObservedObject var settings: AppSettings

    private let columns = [GridItem(.adaptive(minimum: 176, maximum: 220), spacing: 12)]

    /// Toggle a language, keeping at least one always selected.
    private func toggle(_ id: String) {
        var langs = settings.spokenLanguages
        if langs.contains(id) {
            guard langs.count > 1 else { return }
            langs.removeAll { $0 == id }
        } else {
            langs.append(id)
        }
        settings.spokenLanguages = langs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(talkieLanguageCatalog) { lang in
                    LanguageCard(
                        language: lang,
                        selected: settings.spokenLanguages.contains(lang.id),
                        locked: settings.spokenLanguages == [lang.id]
                    ) { toggle(lang.id) }
                }
            }
            Text(settings.spokenLanguages.count > 1
                 ? "Talkie auto-detects which of these you're speaking each time."
                 : "Pick more than one to have Talkie auto-detect your language.")
                .font(.callout)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.horizontal, 4)
                .padding(.top, 2)
        }
    }
}

/// A tappable language tile: flag, language + country, and a check that fills the
/// corner when selected. Selected tiles wear the brand wash + ring.
private struct LanguageCard: View {
    let language: TalkieLanguage
    let selected: Bool
    /// True when this is the *only* selected language — tapping it is a no-op
    /// (Talkie always needs at least one), so the tile reads as locked-on.
    let locked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 13) {
                // The flag is the hero — large, centered, with the selection check
                // as a badge on its corner.
                flag
                    .frame(width: 96, height: 96)
                    .overlay(alignment: .bottomTrailing) {
                        if selected { checkBadge.offset(x: 5, y: 5) }
                    }
                VStack(spacing: 1) {
                    Text(language.gridTitle)
                        .font(.talkieHeading(14.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(language.regionName)
                        .font(.talkieHeading(11.5, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(selected ? Theme.coralWash : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(selected ? Theme.coral : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 7)
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.14), value: selected)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(locked ? "Talkie keeps at least one language"
                     : (selected ? "Tap to remove" : "Tap to add"))
    }

    private var flag: some View {
        Group {
            if let region = Locale(identifier: language.id).region?.identifier,
               let img = Brand.image("Flag\(region)") {
                Image(nsImage: img).resizable().scaledToFit()
            } else {
                Text(language.flag).font(.system(size: 64))
            }
        }
    }

    private var checkBadge: some View {
        ZStack {
            Circle().fill(Theme.coral)
                .overlay(Circle().strokeBorder(selected ? Theme.coralWash : Theme.surface, lineWidth: 3))
                .frame(width: 26, height: 26)
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

/// The Context-awareness and Learning toggles, relocated here beside Smart
/// cleanup (L6e) so the whole "Cleanup & intelligence" story reads as one. Both
/// toggles are load-bearing for the vibe/jargon spine — with context awareness
/// off, window-title capture returns nil, which silently no-ops the Vibe-coding
/// indexing offer (A9) and the `.prompt` cleanup promotion (G9) — so they live
/// here bit-for-bit, never gated or merged away. The former Memory count card
/// was retired: the sidebar Memory tab is the surface, and the counts already
/// live there, so no `ContextGraphStore`/`SettingsRouter` plumbing is needed.
///
/// Copy note: the card `String`s bypass `LocalizedStringKey`, so the edited
/// footers/titles route through `.loc` explicitly (house rule,
/// PrivacySettings.swift:190-196).
private struct ContextSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(
                header: "Context awareness",
                footer: "Talkie reads the names already on screen — who you're messaging, the file you have open — and biases recognition so it spells them right. Local and read-only. Also powers Vibe-coding offers and the Prompt cleanup style, which stay quiet while this is off.".loc
            ) {
                SettingsToggleRow(title: "Use the app I'm dictating into for context".loc,
                                  isOn: $settings.contextAwareness)
            }
            SettingsCard(
                header: "Learning",
                footer: "When you fix a word right after dictating, Talkie remembers the correction. Auto-added rules are tagged in the Dictionary tab — prune any you don't want.".loc
            ) {
                SettingsToggleRow(title: "Learn from my edits".loc,
                                  subtitle: "Auto-improve the dictionary.".loc,
                                  isOn: $settings.learnFromEdits)
            }
        }
    }
}

private struct BehaviorSettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard {
                SettingsToggleRow(title: "Play sounds", isOn: $settings.playSounds)
                SettingsDivider()
                SettingsToggleRow(title: "Open Talkie at login", isOn: $settings.launchAtLogin)
                SettingsDivider()
                SettingsToggleRow(title: "Show floating bird",
                                  subtitle: "A draggable macaw that pulses while you dictate",
                                  isOn: $settings.showBirdBuddy)
            }
        }
    }
}

// MARK: - Dictionary

private struct DictionarySettings: View {
    @ObservedObject var dictionary: DictionaryStore
    @ObservedObject var nicheVocab: NicheVocabStore
    @State private var newTerm: String = ""

    /// The self-learned terms that have graduated into the live corrector — the ones
    /// currently rescuing close misses without a hand-curated Dictionary entry.
    private var learnedTerms: [String] {
        nicheVocab.snapshot()
            .correctorTerms(forNiche: NicheID.default.key, limit: 60)
            // Don't repeat terms the user has already curated by hand above.
            .filter { term in !dictionary.vocabulary.contains { $0.lowercased() == term.lowercased() } }
    }

    // Import/export (.talkiepack). The preview is computed BEFORE anything is
    // written, so the sheet can show what will be added vs. what already exists and
    // the user confirms once. `importError` shows a calm message when a dropped or
    // picked file isn't a valid pack — and nothing is changed.
    @State private var pendingPack: TalkiePack?
    @State private var pendingPreview: MergePreview?
    @State private var importError: String?
    @State private var mergeResult: MergeSummary?
    @State private var isTargetedForDrop = false

    // A7 — import from another dictation app (VoiceInk / Superwhisper / Wispr Flow).
    // Auto-detected apps (those with a dictionary file on disk) are offered directly;
    // every app also gets a "Choose a file…" picker so an export saved elsewhere still
    // imports. The parsed competitor file becomes a TalkiePack and flows through the
    // exact same preview/merge sheet as a native .talkiepack — one code path.
    @State private var detectedApps: [CompetitorDictionaryImport.Detected] = []

    // A6 — profession starter packs. Tapping a pack loads its bundled .talkiepack
    // and stages the SAME preview/merge sheet as a file import (one code path). A
    // missing/broken bundled resource is a packaging bug, surfaced calmly via the
    // existing importError alert rather than crashing.

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    PageHeader(title: "Dictionary",
                               subtitle: "Names, brands, and jargon Talkie should spell correctly.")
                    Spacer()
                    importExportButtons
                }

                // Custom vocabulary.
                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow(text: "Custom vocabulary")
                    HStack(spacing: 8) {
                        TextField("Add a word or phrase…", text: $newTerm)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addTerm)
                        Button("Add", action: addTerm)
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.coral)
                            .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .controlSize(.large)
                    if dictionary.vocabulary.isEmpty {
                        Text("No custom words yet — add names or jargon Talkie keeps mishearing.")
                            .font(.talkieHeading(13, weight: .regular))
                            .foregroundStyle(Theme.inkTertiary)
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(dictionary.vocabulary, id: \.self) { term in
                                VocabChip(term: term) { removeVocab(term) }
                            }
                        }
                        Text("These words are also used to auto-correct misrecognitions in what you dictate.")
                            .font(.callout)
                            .foregroundStyle(Theme.inkTertiary)
                    }
                }
                .talkieCard()

                // A6 — profession starter packs. One tap installs 60–300 curated,
                // guard-safe field terms so the corrector rescues close misses from
                // day one. Install-only; each pack flows through the same preview
                // sheet as a file import so nothing is added without a confirm.
                starterPacksCard

                // L16 — "Install my jargon": a copy-prompt the user pastes into
                // Claude. Claude (via the talkie MCP) reads how they actually talk to
                // it and suggests the terms Talkie would mis-hear, queued for a one-tap
                // confirm with Undo. Sits in the dictionary's import/export region
                // beside the starter packs and the header Export button.
                InstallMyJargonCard()

                // Learned vocabulary — jargon Talkie picked up from what you say and
                // confirm, now correcting close misses on its own. Read-only; stays
                // hidden until something has graduated, so it never adds noise.
                if !learnedTerms.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow(text: "Learned vocabulary")
                        Text("Words Talkie picked up from what you dictate and correct. They now fix close misses on their own, no rule needed. Remove one to tell Talkie it got that wrong.")
                            .font(.talkieHeading(13, weight: .regular))
                            .foregroundStyle(Theme.inkSecondary)
                        FlowLayout(spacing: 8) {
                            ForEach(learnedTerms, id: \.self) { term in
                                VocabChip(term: term) { nicheVocab.recordRejection(term) }
                            }
                        }
                    }
                    .talkieCard()
                }

                // Replacements.
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Eyebrow(text: "Replacements")
                        Spacer()
                        Button { dictionary.addReplacement() } label: {
                            Label("Add rule", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Rewrite what was heard into what you meant — e.g. “correlate” → “Coralate”.")
                        .font(.talkieHeading(13, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)

                    if dictionary.replacements.isEmpty {
                        Text("No replacement rules yet.")
                            .font(.talkieHeading(13, weight: .regular))
                            .foregroundStyle(Theme.inkTertiary)
                    } else {
                        VStack(spacing: 10) {
                            ForEach($dictionary.replacements) { $rule in
                                ReplacementRow(rule: $rule) { removeRule(rule) }
                            }
                        }
                    }
                }
                .talkieCard()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            // A calm brand wash confirms a valid drag is over the pane.
            Theme.canvas.overlay(
                isTargetedForDrop
                    ? Theme.coral.opacity(0.06)
                    : Color.clear
            )
        )
        .onChange(of: dictionary.replacements) { _, _ in dictionary.save() }
        .onChange(of: dictionary.vocabulary) { _, _ in dictionary.save() }
        // A7 — check which other dictation apps have a dictionary on disk so the
        // "Import from another app" menu can offer them directly. Cheap fileExists
        // checks only; runs when the pane appears.
        .onAppear { detectedApps = CompetitorDictionaryImport.detectInstalledApps() }
        // Drag a .talkiepack onto the Dictionary tab to import it.
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            loadDroppedPack(providers)
        }
        // Double-clicking a .talkiepack in Finder routes here (see AppDelegate).
        .onReceive(NotificationCenter.default.publisher(for: .talkieOpenDictionaryPack)) { note in
            if let url = note.object as? URL { openPack(at: url) }
        }
        .sheet(item: Binding(
            get: { pendingPreview.map { PreviewBox(preview: $0) } },
            set: { if $0 == nil { pendingPreview = nil; pendingPack = nil } }
        )) { box in
            ImportPreviewSheet(
                preview: box.preview,
                onConfirm: { confirmImport() },
                onCancel: { pendingPreview = nil; pendingPack = nil }
            )
        }
        .alert("Couldn't read that file",
               isPresented: Binding(get: { importError != nil },
                                    set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("Dictionary imported",
               isPresented: Binding(get: { mergeResult != nil },
                                    set: { if !$0 { mergeResult = nil } })) {
            Button("OK", role: .cancel) { mergeResult = nil }
        } message: {
            Text(mergeResultMessage)
        }
    }

    // MARK: Import / export UI

    private var importExportButtons: some View {
        HStack(spacing: 8) {
            Button { presentImportPanel() } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .help("Import a .talkiepack file — preview what's inside before adding it")

            importFromAnotherAppMenu

            Button { presentExportPanel() } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(dictionary.vocabulary.isEmpty && dictionary.replacementsSnapshot().isEmpty)
            .help("Save your whole dictionary to a shareable .talkiepack file")
        }
    }

    /// A7 — "Import from another app". A menu, not a button, because there are two axes:
    /// which app, and (detected file vs. pick-your-own). Detected apps get a one-tap
    /// entry that reads the file we found; every app also gets a "Choose a file…" item
    /// for exports saved elsewhere. Whatever the source, the parsed file lands in the
    /// same preview sheet as a native pack.
    private var importFromAnotherAppMenu: some View {
        Menu {
            if detectedApps.isEmpty {
                Text("No dictation apps detected on this Mac")
            } else {
                ForEach(detectedApps) { detected in
                    Button {
                        importFromCompetitor(app: detected.app, at: detected.fileURL)
                    } label: {
                        Label(String(format: "Import from %@".loc, detected.app.displayName),
                              systemImage: "checkmark.circle")
                    }
                }
            }
            Divider()
            // Picker fallback for every supported app, so an export saved anywhere still
            // imports even when auto-detect found nothing.
            ForEach(CompetitorDictionaryImport.App.allCases, id: \.rawValue) { app in
                Button {
                    presentCompetitorImportPanel(app: app)
                } label: {
                    Text(String(format: "Choose a %@ file…".loc, app.displayName))
                }
            }
        } label: {
            Label("Import from another app", systemImage: "arrow.down.doc")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Bring your dictionary over from VoiceInk, Superwhisper, or Wispr Flow")
    }

    // MARK: Starter packs (A6)

    /// The card offering one-tap install of a profession vocabulary. Each row opens
    /// the pack's bundled `.talkiepack` in the same preview sheet as a file import,
    /// so the user always confirms before anything is added (and a re-install of a
    /// pack you already have shows every row dimmed and adds nothing).
    private var starterPacksCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Starter packs")
            // The honesty line — spelled out so expectations are calibrated: this
            // fixes CLOSE misses, it can't teach the recognizer a brand-new word.
            Text("Work in a niche field? Install a pack of common terms so Talkie fixes close misses of them from your first dictation. It can't make the recognizer say a word it's never heard — it proofreads what you dictate and swaps a close-sounding mistake for the right term.")
                .font(.talkieHeading(13, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
            VStack(spacing: 10) {
                ForEach(StarterPack.allCases) { pack in
                    StarterPackRow(pack: pack) { installStarterPack(pack) }
                }
            }
            Text("Preview what's inside before it's added — nothing is installed until you confirm.")
                .font(.talkieHeading(11.5, weight: .regular))
                .foregroundStyle(Theme.inkTertiary)
        }
        .talkieCard()
    }

    /// Load a bundled pack and stage its preview — writes nothing yet, exactly like
    /// `openPack`. A missing/undecodable bundled resource is a packaging bug (the
    /// copy block in `build_app.sh` didn't run); we surface it through the same calm
    /// alert as a bad file rather than crashing.
    private func installStarterPack(_ pack: StarterPack) {
        do {
            let loaded = try pack.load()
            pendingPack = loaded
            pendingPreview = dictionary.previewMerge(pack: loaded)
        } catch {
            importError = "Talkie couldn't open that starter pack. Reinstalling Talkie should fix it.".loc
        }
    }

    private func addTerm() {
        dictionary.addVocabularyTerm(newTerm)
        newTerm = ""
    }
    private func removeVocab(_ term: String) {
        if let i = dictionary.vocabulary.firstIndex(of: term) {
            dictionary.removeVocabulary(at: IndexSet(integer: i))
        }
    }
    private func removeRule(_ rule: Replacement) {
        if let i = dictionary.replacements.firstIndex(where: { $0.id == rule.id }) {
            dictionary.removeReplacements(at: IndexSet(integer: i))
        }
    }

    // MARK: Export

    /// Write the whole dictionary to a `.talkiepack` via a save panel. The pack name
    /// defaults to the machine's short name so the shared file has a sensible title;
    /// the user can rename the file in the panel.
    private func presentExportPanel() {
        let defaultName = Host.current().localizedName ?? "Talkie"
        let pack = dictionary.exportPack(name: defaultName, description: nil, attribution: nil)
        let panel = NSSavePanel()
        panel.title = "Export dictionary"
        panel.nameFieldStringValue = pack.suggestedFileName
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: TalkiePack.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try pack.encoded().write(to: url, options: .atomic)
            } catch {
                importError = "Talkie couldn't save the file. Please try a different location.".loc
            }
        }
    }

    // MARK: Import

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import dictionary"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let type = UTType(filenameExtension: TalkiePack.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            openPack(at: url)
        }
    }

    /// Read a pack file and stage its merge preview — writes nothing yet. A malformed
    /// or unreadable file shows an error and changes nothing (acceptance criterion).
    private func openPack(at url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            importError = "Talkie couldn't open that file.".loc
            return
        }
        do {
            let pack = try TalkiePack.decoded(from: data)
            pendingPack = pack
            pendingPreview = dictionary.previewMerge(pack: pack)
        } catch {
            importError = "That doesn't look like a Talkie dictionary (.talkiepack).".loc
        }
    }

    // MARK: Import from another app (A7)

    /// Read a detected competitor file and stage its preview — writes nothing yet. Same
    /// contract as `openPack`: a malformed/unreadable file shows a calm error and changes
    /// nothing. The produced pack is stamped "Imported from <App>" so the preview shows
    /// provenance.
    private func importFromCompetitor(app: CompetitorDictionaryImport.App, at url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        do {
            let pack = try CompetitorDictionaryImport.readPack(app: app, from: url)
            pendingPack = pack
            pendingPreview = dictionary.previewMerge(pack: pack)
        } catch {
            importError = String(format: "Talkie couldn't read that %@ file.".loc, app.displayName)
        }
    }

    /// Open a file picker for a specific competitor app (the "Choose a file…" fallback),
    /// then parse the chosen file with that app's parser. We don't constrain the picker to
    /// one extension — competitor exports use varied names/extensions — so the user can
    /// point at whatever they exported; the parser decides if it's readable.
    private func presentCompetitorImportPanel(app: CompetitorDictionaryImport.App) {
        let panel = NSOpenPanel()
        panel.title = String(format: "Import from %@".loc, app.displayName)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            importFromCompetitor(app: app, at: url)
        }
    }

    /// Handle a file dropped onto the pane. We only accept a single file URL; anything
    /// else is ignored. Returns true when we took the drop.
    private func loadDroppedPack(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in openPack(at: url) }
        }
        return true
    }

    /// Commit the staged merge. Idempotent by construction — the merge only adds
    /// entries that don't already exist, so re-confirming the same pack adds nothing.
    private func confirmImport() {
        guard let pack = pendingPack else { return }
        let result = dictionary.merge(pack: pack)
        pendingPreview = nil
        pendingPack = nil
        mergeResult = result
    }

    /// The post-import confirmation. Built from localized format strings (`%d`
    /// placeholders) so each language keeps grammatical control of the whole
    /// sentence; `.loc` looks the templates up in every `.lproj`.
    private var mergeResultMessage: String {
        guard let r = mergeResult else { return "" }
        if r.isEmpty {
            return "Everything in that pack was already in your dictionary — nothing to add.".loc
        }
        if r.vocabularyAdded > 0 && r.replacementsAdded > 0 {
            return String(format: "Added %d words and %d rules to your dictionary.".loc,
                          r.vocabularyAdded, r.replacementsAdded)
        }
        if r.vocabularyAdded > 0 {
            return String(format: "Added %d words to your dictionary.".loc, r.vocabularyAdded)
        }
        return String(format: "Added %d rules to your dictionary.".loc, r.replacementsAdded)
    }
}

/// `MergePreview` isn't `Identifiable`, and `.sheet(item:)` needs identity — wrap it.
private struct PreviewBox: Identifiable {
    let id = UUID()
    let preview: MergePreview
}

/// One row in the Starter-packs card (A6): a glyph, the pack's title + one-line
/// description, and an Install button that opens its bundled `.talkiepack` in the
/// shared preview sheet. Matches the calm `SettingsRow` feel without a new style.
private struct StarterPackRow: View {
    let pack: StarterPack
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pack.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.coral)
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.title)
                    .font(.talkieHeading(14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(pack.shortDescription)
                    .font(.talkieHeading(12, weight: .regular))
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onInstall) {
                Label("Install", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .help(String(format: "Preview and add the %@ pack".loc, pack.title))
        }
        .padding(.vertical, 4)
    }
}

private struct VocabChip: View {
    let term: String
    let onRemove: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text(term)
                .font(.talkieHeading(12.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.surfaceSunken))
    }
}

private struct ReplacementRow: View {
    @Binding var rule: Replacement
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("heard", text: $rule.from)
                .textFieldStyle(.roundedBorder)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
            TextField("written", text: $rule.to)
                .textFieldStyle(.roundedBorder)
            // Fixed-width slot so the toggles line up across every row, learned or not.
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.coral)
                .opacity(rule.isLearned ? 1 : 0)
                .frame(width: 13)
                .help(rule.isLearned ? "Learned automatically from your edits" : "")
            Toggle("Aa", isOn: $rule.caseSensitive)
                .toggleStyle(.button).help("Case sensitive")
            Toggle("W", isOn: $rule.wholeWord)
                .toggleStyle(.button).help("Whole word only")
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .help("Delete this rule")
        }
    }
}

// MARK: - Import preview sheet

/// Shows exactly what a `.talkiepack` will add before anything is written: the pack's
/// name/attribution, the new terms and rules, and — dimmed — the ones you already have
/// (so a re-import obviously adds nothing). One Confirm applies it; Cancel changes
/// nothing. Reuses the app's `Theme`, `talkieCard`, and `Eyebrow` so it's
/// indistinguishable from the rest of the dictionary UI.
private struct ImportPreviewSheet: View {
    let preview: MergePreview
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !preview.vocab.isEmpty { vocabSection }
                    if !preview.rules.isEmpty { rulesSection }
                    if preview.vocab.isEmpty && preview.rules.isEmpty {
                        Text("This pack is empty — there's nothing to add.")
                            .font(.talkieHeading(13, weight: .regular))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    // BYO-sync note (iCloud sync is out of scope — this is the doc for it).
                    Text("Tip: keep a .talkiepack in iCloud Drive or a dotfiles repo to sync it across your Macs — Talkie never uploads anything.")
                        .font(.talkieHeading(11.5, weight: .regular))
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.top, 4)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 540)
        .background(Theme.canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Import dictionary")
            Text(preview.packName)
                .font(.talkieDisplay(22))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            if let desc = preview.packDescription, !desc.isEmpty {
                Text(desc)
                    .font(.talkieHeading(13, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
            }
            if let attribution = preview.attribution, !attribution.isEmpty {
                Text(attribution)
                    .font(.talkieHeading(12, weight: .regular))
                    .foregroundStyle(Theme.inkTertiary)
            }
            summaryLine
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryLine: some View {
        let newV = preview.newVocabCount
        let newR = preview.newRuleCount
        let existing = (preview.vocab.count - newV) + (preview.rules.count - newR)
        return Text(summaryText(newVocab: newV, newRules: newR, alreadyHave: existing))
            .font(.talkieHeading(12.5, weight: .medium))
            .foregroundStyle(newV + newR > 0 ? Theme.coral : Theme.inkSecondary)
            .padding(.top, 2)
    }

    /// The one-line summary at the top of the sheet. Localized format strings (`%d`)
    /// keep each language grammatical; `.loc` resolves the templates per `.lproj`.
    private func summaryText(newVocab: Int, newRules: Int, alreadyHave: Int) -> String {
        if newVocab + newRules == 0 {
            return "You already have everything in this pack.".loc
        }
        var line: String
        if newVocab > 0 && newRules > 0 {
            line = String(format: "Adds %d new words and %d new rules.".loc, newVocab, newRules)
        } else if newVocab > 0 {
            line = String(format: "Adds %d new words.".loc, newVocab)
        } else {
            line = String(format: "Adds %d new rules.".loc, newRules)
        }
        if alreadyHave > 0 {
            line += " " + String(format: "%d already in your dictionary.".loc, alreadyHave)
        }
        return line
    }

    private var vocabSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Vocabulary")
            FlowLayout(spacing: 8) {
                ForEach(preview.vocab) { row in
                    Text(row.term)
                        .font(.talkieHeading(12.5, weight: .medium))
                        .foregroundStyle(row.existing ? Theme.inkTertiary : Theme.ink)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.surfaceSunken))
                        .opacity(row.existing ? 0.5 : 1)
                        .help(row.existing ? "Already in your dictionary".loc : "Will be added".loc)
                }
            }
        }
        .talkieCard()
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Replacements")
            VStack(spacing: 8) {
                ForEach(preview.rules) { row in
                    HStack(spacing: 8) {
                        Text(row.from)
                            .font(.talkieHeading(13, weight: .regular))
                            .foregroundStyle(row.existing ? Theme.inkTertiary : Theme.inkSecondary)
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                        Text(row.to)
                            .font(.talkieHeading(13, weight: .medium))
                            .foregroundStyle(row.existing ? Theme.inkTertiary : Theme.ink)
                            .lineLimit(1)
                        Spacer()
                        if row.existing {
                            Text("Have it")
                                .font(.talkieHeading(11, weight: .medium))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(row.existing ? 0.5 : 1)
                }
            }
        }
        .talkieCard()
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Button(preview.hasSomethingToAdd ? "Add to dictionary" : "Nothing to add",
                   action: onConfirm)
                .buttonStyle(.borderedProminent)
                .tint(Theme.coral)
                .keyboardShortcut(.defaultAction)
                .disabled(!preview.hasSomethingToAdd)
        }
        .controlSize(.large)
        .padding(16)
    }
}

extension Notification.Name {
    /// Posted by AppDelegate when a `.talkiepack` is opened from Finder, so the
    /// Dictionary pane can stage the import preview. Object is the file `URL`.
    static let talkieOpenDictionaryPack = Notification.Name("talkieOpenDictionaryPack")
}

// MARK: - Privacy & Permissions

/// Merged "Privacy & Permissions": the three local permissions Talkie needs,
/// followed by the verifiable proof that nothing leaves your Mac. Replaces the
/// two formerly separate Permissions and Privacy panes with one.
private struct PrivacyAndPermissionsSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var history: HistoryStore
    let onRetryHotKey: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PermissionsSection(permissions: permissions, onRetryHotKey: onRetryHotKey)
            PrivacySection(settings: settings, history: history)
        }
    }
}

/// The permissions block, card-only (no `SubPage`) so it composes into the merged
/// Privacy & Permissions page above.
private struct PermissionsSection: View {
    @ObservedObject var permissions: PermissionsModel
    let onRetryHotKey: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(
                header: "Permissions",
                footer: "After granting Input Monitoring or Accessibility, you may need to quit and reopen Talkie for the change to take effect."
            ) {
                PermissionRow(
                    title: "Microphone",
                    detail: "Capture your voice while you dictate.",
                    granted: permissions.microphone,
                    action: { Task { await permissions.requestMicrophone() } },
                    openSettings: permissions.openMicrophoneSettings
                )
                SettingsDivider()
                PermissionRow(
                    title: "Input Monitoring",
                    detail: "Detect your dictation key anywhere in the system.",
                    granted: permissions.inputMonitoring,
                    action: {
                        permissions.requestInputMonitoring()
                        // The grant may already be live but the tap can still fail
                        // to install in this process — surface a one-click relaunch
                        // rather than a silent granted-but-dead hotkey.
                        if !onRetryHotKey() && permissions.inputMonitoring {
                            permissions.hotKeyNeedsRelaunch = true
                        }
                    },
                    openSettings: permissions.openInputMonitoringSettings
                )
                SettingsDivider()
                PermissionRow(
                    title: "Accessibility",
                    detail: "Paste the transcribed text into the app you're using.",
                    granted: permissions.accessibility,
                    action: permissions.promptAccessibility,
                    openSettings: permissions.openAccessibilitySettings
                )
            }

            // When the grant landed but the tap still can't install, promote a
            // prominent one-click relaunch — the only reliable fix for the TCC
            // quirk, and always the user's tap (never automatic).
            if permissions.hotKeyNeedsRelaunch {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.warning)
                    Text("Input Monitoring is granted, but Talkie needs a relaunch to start hearing your key.")
                        .font(.talkieHeading(13, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Relaunch now") { permissions.relaunch() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.coral)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warning.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.warning.opacity(0.30)))
            }

            HStack {
                Button("Quit & Reopen") { permissions.relaunch() }
                Spacer()
                if permissions.allGranted {
                    HStack(spacing: 7) {
                        ClayIcon(name: "IconSeal", size: 22)
                        Text("All set")
                            .font(.talkieHeading(13, weight: .semibold))
                            .foregroundStyle(Theme.positive)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        // Poll live so a grant made in System Settings reflects here within ~1s;
        // stop when the card leaves the screen so no loop runs unobserved.
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if granted {
                ClayIcon(name: "IconCheck", size: 26)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.talkieHeading(14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(detail).font(.callout).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if !granted {
                VStack(spacing: 4) {
                    Button("Grant", action: action)
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
