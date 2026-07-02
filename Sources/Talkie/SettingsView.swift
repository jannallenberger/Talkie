import AppKit
import SwiftUI

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

@MainActor
final class SettingsRouter: ObservableObject {
    @Published var selectedTab: SettingsTab = .dashboard
}

/// The app's main window (Dock app). A Claude-style sidebar shell hosting the
/// dashboard, history, and settings panes.
@MainActor
final class MainWindowController {
    private let window: NSWindow
    private let router = SettingsRouter()

    init(
        settings: AppSettings,
        dictionary: DictionaryStore,
        permissions: PermissionsModel,
        history: HistoryStore,
        stats: StatsStore,
        appUsage: AppUsageStore,
        activity: ActivityStore,
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
        onRetryHotKey: @escaping () -> Void
    ) {
        let root = MainView(
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
    }

    func show(tab: SettingsTab) {
        router.selectedTab = tab
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
    let onRetryHotKey: () -> Void

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
                          contextSummary: contextSummary, router: router)
        case .meetings:
            MeetingsView(recorder: meetingRecorder, store: meetingStore, settings: settings)
        case .dictionary:
            DictionarySettings(dictionary: dictionary, nicheVocab: nicheVocab)
        case .memory:
            MemoryView(contextGraph: contextGraph, history: history,
                       searchEngine: searchEngine, meetingStore: meetingStore)
        case .commands:
            CommandsView(settings: settings, macros: macros,
                         commandRouter: commandRouter, hud: hud,
                         meetingStore: meetingStore)
        case .vibeCoding:
            VibeCodingView(projectIndex: projectIndex, settings: settings)
        case .general:
            SettingsHome(settings: settings, permissions: permissions,
                         profiles: profiles, contextGraph: contextGraph,
                         router: router, onRetryHotKey: onRetryHotKey)
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
                Eyebrow(text: settings.activationMode == .holdToTalk ? "Hold to talk" : "Tap to toggle")
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

/// Settings landing — flat, named sections on one scrolling page. Never more
/// than this one level: no section pushes to a further child screen (Apple HIG's
/// "flat toolbar panes, no sidebar-within-settings" convention for a macOS
/// Settings surface).
private struct SettingsHome: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var profiles: AppProfileStore
    @ObservedObject var contextGraph: ContextGraphStore
    @ObservedObject var router: SettingsRouter
    let onRetryHotKey: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(title: "Settings",
                           subtitle: "Tune how Talkie listens, cleans up, and behaves.")

                section("Profile") {
                    ProfileSettings(settings: settings)
                }
                section("Dictation") {
                    ActivationSettings(settings: settings)
                    MicrophoneSettings(settings: settings)
                    CleanupSettings(settings: settings)
                    LanguageSettings(settings: settings)
                }
                section("Per-app & context") {
                    ContextSettings(settings: settings, contextGraph: contextGraph, router: router)
                    AppProfilesSettings(profiles: profiles, settings: settings)
                    CalendarSettings()
                }
                section("Behavior") {
                    BehaviorSettings(settings: settings)
                    ExportDestinationsSettings()
                }
                section("Privacy & Permissions") {
                    PrivacyAndPermissionsSettings(permissions: permissions, onRetryHotKey: onRetryHotKey)
                }
                section("Developer") {
                    DeveloperSettings(settings: settings)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow(text: title.uppercased())
            content()
        }
    }
}

/// Developer tools (replaying the first-run onboarding, etc.). The Settings index
/// always shows this row now, so these are reachable in any build — no need for a
/// Debug build or the `TalkieDevMode` default.
private struct DeveloperSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var replaying = false

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

            MCPConnectorCard()

            // Gate-zero check for the niche-vocabulary feature: does on-device
            // contextualStrings biasing actually move recognition? Test it by talking.
            if BiasABProbe.isAvailable {
                BiasABTestView()
            }
        }
    }
}

/// "Local MCP server" — surfaces the `talkie-mcp` binary (zero-network stdio
/// JSON-RPC server over the on-disk stores) so it's discoverable, instead of a
/// user having to find the binary and hand-configure an MCP client themselves.
/// Config/discovery only — no server management UI, matching its nature as a
/// CLI-facing tool the app doesn't run or supervise.
private struct MCPConnectorCard: View {
    @State private var copied = false

    /// `talkie-mcp` is a separate SwiftPM product, never bundled into the app —
    /// only present on disk if it's been built. Search plausible build-output
    /// locations rather than assume one; show an honest "not built yet" state
    /// instead of copying a path that doesn't exist.
    private var binaryPath: String? {
        let candidates = [
            "\(NSHomeDirectory())/Talkie/.build/release/talkie-mcp",
            "\(NSHomeDirectory())/Talkie/.build/debug/talkie-mcp",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var body: some View {
        SettingsCard(
            header: "Local MCP server",
            footer: "talkie-mcp is a separate, zero-network stdio server exposing your meetings, brief, commitments, and search to Claude Desktop or any MCP client — read-mostly, entirely on-device."
        ) {
            if let binaryPath {
                SettingsRow(title: "talkie-mcp", subtitle: binaryPath) {
                    Button(copied ? "Copied" : "Copy config") { copyConfig(binaryPath) }
                        .buttonStyle(.bordered)
                }
            } else {
                SettingsNote(
                    text: "Not built yet. Run `swift build --product talkie-mcp` from the Talkie checkout, then reopen this pane.",
                    tone: Theme.inkTertiary
                )
            }
        }
    }

    private func copyConfig(_ path: String) {
        let json = """
        {
          "tools": {
            "talkie": {
              "command": "\(path)"
            }
          }
        }
        """
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(json, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
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

private struct ProfileSettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(footer: "Shown on your dashboard as “Welcome back”. Stays on your Mac.") {
                SettingsRow(title: "Name") {
                    TextField("Your name", text: $settings.userName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
            }
        }
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
                footer: "Pauses Apple Music or Spotify while you dictate, then resumes it when you stop. macOS will ask for permission to control them the first time."
            ) {
                SettingsToggleRow(title: "Pause music while dictating",
                                  isOn: $settings.pauseMusicWhileDictating)
                if settings.pauseMusicWhileDictating {
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Also pause other apps",
                        subtitle: "Best-effort play/pause for browsers, podcasts, etc. when Music/Spotify aren't playing. Can't read state, so it may occasionally toggle the wrong thing.",
                        isOn: $settings.pauseMusicMediaKeyFallback)
                }
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
                footer: settings.activationMode == .holdToTalk
                    ? "Hold the key, speak, release to insert the text."
                    : "Tap the key to start, tap again to stop and insert."
            ) {
                SettingsRow(title: "Dictation key") {
                    Picker("", selection: $settings.activationKey) {
                        ForEach(ActivationKey.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsDivider()
                SettingsRow(title: "Mode") {
                    Picker("", selection: $settings.activationMode) {
                        ForEach(ActivationMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            SettingsCard(header: "Insertion") {
                SettingsRow(title: "Insert text by") {
                    Picker("", selection: $settings.insertionMode) {
                        ForEach(InsertionMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if settings.insertionMode == .paste {
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Insert instantly, polish in place",
                        subtitle: "Experimental — pastes your raw words the moment you stop, then swaps in the cleaned version. May misfire if you keep typing right after.",
                        isOn: $settings.optimisticInsertion
                    )
                }
                SettingsDivider()
                SettingsToggleRow(
                    title: "Let commands target your last dictation",
                    subtitle: "If nothing's selected, a command like “make this a list” can rewrite the text you just dictated instead of doing nothing — only in the same app, within 45 seconds, and you'll always see a preview before it lands.",
                    isOn: $settings.implicitCommandTarget
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Re-paste last transcript with \(settings.activationKey.pasteShortcut.display)",
                    subtitle: "Press \(settings.activationKey.pasteShortcut.display) to drop your most recent transcript into the focused field — handy when Talkie couldn’t find one to paste into. Picked to never clash with your dictation key.",
                    isOn: $settings.pasteLastShortcutEnabled
                )
            }
        }
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
            SettingsCard(header: "Smart cleanup") {
                SettingsToggleRow(
                    title: "Adapt the style to the app",
                    subtitle: "A personality per app — friendly for Messages, professional for Mail, faithful for code.",
                    isOn: $settings.appAdaptiveCleanup
                )
                if settings.appAdaptiveCleanup {
                    ForEach(AppCategory.allCases, id: \.self) { category in
                        SettingsDivider()
                        SettingsRow(title: category.label) {
                            Picker("", selection: styleBinding(category)) {
                                ForEach(CleanupStyle.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                } else {
                    SettingsDivider(leadingInset: 0)
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $settings.cleanupLevel) {
                            ForEach(CleanupLevel.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented)
                        Text(settings.cleanupLevel.detail)
                            .font(.callout).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                }
                SettingsDivider(leadingInset: 0)
                if let warning = CleanupEngine.unavailableMessage {
                    SettingsNote(text: warning, tone: Theme.warning, icon: "exclamationmark.triangle.fill")
                } else {
                    SettingsNote(text: "Resolves spoken self-corrections and fixes grammar. Runs entirely on your Mac; nothing leaves the device.",
                                 tone: Theme.inkTertiary)
                }
            }
            SettingsCard(header: "Basic cleanup",
                         footer: "These apply when Smart cleanup isn't rewriting the text.") {
                SettingsToggleRow(title: "Capitalize the first letter", isOn: $settings.autoCapitalize)
                SettingsDivider()
                SettingsToggleRow(title: "Remove filler words", subtitle: "um, uh, hmm…",
                                  isOn: $settings.cleanupFillers)
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

private struct ContextSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var contextGraph: ContextGraphStore
    @ObservedObject var router: SettingsRouter

    private var peopleCount: Int { contextGraph.snapshot().entities(of: .person).count }
    private var projectCount: Int { contextGraph.snapshot().entities(of: .project).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(
                header: "Context awareness",
                footer: "Talkie reads the names already on screen — who you're messaging, the file you have open — and biases recognition so it spells them right. Local and read-only."
            ) {
                SettingsToggleRow(title: "Use the app I'm dictating into for context",
                                  isOn: $settings.contextAwareness)
            }
            SettingsCard(
                header: "Learning",
                footer: "When you fix a word right after dictating, Talkie remembers the correction. Auto-added rules are tagged in the Dictionary tab — prune any you don't want."
            ) {
                SettingsToggleRow(title: "Learn from my edits",
                                  subtitle: "Auto-improve the dictionary.",
                                  isOn: $settings.learnFromEdits)
            }
            SettingsCard(header: "Memory") {
                SettingsRow(
                    title: "\(peopleCount) people, \(projectCount) projects tracked",
                    subtitle: "Everything Talkie has picked up from your dictations and meetings."
                ) {
                    Button("Open Memory") { router.selectedTab = .memory }
                        .buttonStyle(.bordered)
                }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Dictionary",
                           subtitle: "Names, brands, and jargon Talkie should spell correctly.")

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
        .background(Theme.canvas)
        .onChange(of: dictionary.replacements) { _, _ in dictionary.save() }
        .onChange(of: dictionary.vocabulary) { _, _ in dictionary.save() }
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

// MARK: - Privacy & Permissions

/// Merged "Privacy & Permissions": the three local permissions Talkie needs,
/// followed by the verifiable proof that nothing leaves your Mac. Replaces the
/// two formerly separate Permissions and Privacy panes with one.
private struct PrivacyAndPermissionsSettings: View {
    @ObservedObject var permissions: PermissionsModel
    let onRetryHotKey: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PermissionsSection(permissions: permissions, onRetryHotKey: onRetryHotKey)
            PrivacySection()
        }
    }
}

/// The permissions block, card-only (no `SubPage`) so it composes into the merged
/// Privacy & Permissions page above.
private struct PermissionsSection: View {
    @ObservedObject var permissions: PermissionsModel
    let onRetryHotKey: () -> Void

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
                        onRetryHotKey()
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

            HStack {
                Button("Re-check") { permissions.refresh() }
                Button("Quit & Reopen") { relaunch() }
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
        .onAppear { permissions.refresh() }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.4; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
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
