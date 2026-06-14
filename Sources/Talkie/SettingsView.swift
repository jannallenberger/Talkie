import AppKit
import SwiftUI

enum SettingsTab: Hashable, CaseIterable {
    case dashboard
    case history
    case meetings
    case search
    case dictionary
    case vibeCoding
    case general

    var title: String {
        switch self {
        case .dashboard:   return "Dashboard"
        case .history:     return "History"
        case .meetings:    return "Meetings"
        case .search:      return "Search"
        case .dictionary:  return "Dictionary"
        case .vibeCoding:  return "Vibe Coding"
        case .general:     return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard:   return "square.grid.2x2.fill"
        case .history:     return "clock.fill"
        case .meetings:    return "person.2.fill"
        case .search:      return "magnifyingglass"
        case .dictionary:  return "character.book.closed.fill"
        case .vibeCoding:  return "chevron.left.forwardslash.chevron.right"
        case .general:     return "gearshape.fill"
        }
    }

    /// Per-item macaw-feather tint for the sidebar (v2). Feature tabs wear a
    /// feather hue; Settings rides the brand blue.
    var tint: Color {
        switch self {
        case .dashboard:   return Theme.featherCoral
        case .history:     return Theme.featherGold
        case .meetings:    return Theme.featherPlum
        case .search:      return Theme.featherBlue
        case .dictionary:  return Theme.featherGreen
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
        case .history:
            HistorySettings(history: history)
        case .meetings:
            MeetingsView(recorder: meetingRecorder, store: meetingStore)
        case .search:
            SearchView(engine: searchEngine, history: history, meetingStore: meetingStore)
        case .dictionary:
            DictionarySettings(dictionary: dictionary)
        case .vibeCoding:
            VibeCodingView(projectIndex: projectIndex, settings: settings)
        case .general:
            SettingsHome(settings: settings, permissions: permissions,
                         macros: macros, profiles: profiles,
                         onRetryHotKey: onRetryHotKey)
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
            Label(tab.title, systemImage: tab.icon)
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
            Text(title)
                .font(.talkieDisplay(26))
                .foregroundStyle(Theme.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.talkieHeading(13, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - History

private struct HistorySettings: View {
    @ObservedObject var history: HistoryStore

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                PageHeader(title: "History", subtitle: "Everything you've dictated in the last 7 days.")
                Spacer()
                Button {
                    copyToClipboard(history.allAsText())
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .disabled(history.entries.isEmpty)
                Button(role: .destructive) {
                    history.clearAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(history.entries.isEmpty)
            }

            if history.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.inkTertiary)
                    Text("No dictations yet")
                        .font(.talkieHeading(15))
                        .foregroundStyle(Theme.inkSecondary)
                    Text("Hold your dictation key and speak — what you say will show up here.")
                        .font(.callout)
                        .foregroundStyle(Theme.inkTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(history.entries) { entry in
                            HistoryRow(entry: entry, formatter: Self.dateFormatter) {
                                copyToClipboard(entry.text)
                            } onDelete: {
                                history.delete(entry)
                            }
                        }
                    }
                }
            }
        }
        .padding(28)
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

private struct HistoryRow: View {
    let entry: DictationEntry
    let formatter: DateFormatter
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var copied = false

    private var appSymbol: String {
        AppCategory(rawValue: entry.appCategory ?? "")?.symbol ?? "app.dashed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(formatter.string(from: entry.date))
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkTertiary)
                if let appName = entry.appName, !appName.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: appSymbol).font(.system(size: 9, weight: .semibold))
                        Text(appName)
                    }
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkTertiary)
                }
                Spacer()
                Button {
                    onCopy()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(copied ? Theme.positive : Theme.inkSecondary)
                }
                .buttonStyle(.plain)
                .help("Copy this dictation")
            }
            Text(entry.text)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .talkieCard(padding: 14)
    }
}

// MARK: - General

private enum SettingsRoute: Hashable {
    case profile, activation, cleanup, languages, context, behavior
    case voiceCommands, appProfiles, calendar, export, privacy
    case permissions, developer
}

/// Settings landing — a tidy index of category rows, each pushing a focused
/// subpage so no single screen floods the user with options.
private struct SettingsHome: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var macros: MacroStore
    @ObservedObject var profiles: AppProfileStore
    let onRetryHotKey: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: "Settings",
                               subtitle: "Tune how Talkie listens, cleans up, and behaves.")
                    // One grouped card with clay-icon rows + hairline dividers.
                    VStack(spacing: 0) {
                        ForEach(Array(categoryRows.enumerated()), id: \.offset) { _, r in
                            SettingsRowView(icon: r.icon, title: r.title, subtitle: r.subtitle, route: r.route)
                            Divider().overlay(Theme.hairline).padding(.leading, 64)
                        }
                        SettingsRowView(icon: "IconShield", title: "Permissions",
                                        subtitle: permissions.allGranted ? "All granted" : "Action needed",
                                        badge: !permissions.allGranted, route: .permissions)
                        if Dev.isEnabled {
                            Divider().overlay(Theme.hairline).padding(.leading, 64)
                            SettingsRowView(icon: "", title: "Developer",
                                            subtitle: "Replay onboarding · debug tools",
                                            route: .developer, systemIcon: "hammer.fill")
                        }
                    }
                    .talkieSurface()
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.canvas)
            .navigationDestination(for: SettingsRoute.self) { route in
                subpage(route)
            }
        }
    }

    private var categoryRows: [(route: SettingsRoute, icon: String, title: String, subtitle: String)] {
        [
            (.profile, "IconPerson", "Profile",
             settings.userName.isEmpty ? "Set your name" : settings.userName),
            (.activation, "IconKeyboard", "Activation & insertion",
             "\(settings.activationKey.displayName) · \(settings.activationMode == .holdToTalk ? "Hold" : "Toggle")"),
            (.cleanup, "IconWand", "Cleanup & style",
             settings.appAdaptiveCleanup ? "Adapts per app" : settings.cleanupLevel.displayName),
            (.languages, "IconGlobe", "Languages",
             "\(settings.spokenLanguages.count) selected"),
            (.context, "IconBrain", "Context & learning",
             settings.contextAwareness ? "Context on" : "Context off"),
            (.voiceCommands, "IconWand", "Voice commands",
             macros.macros.count == 1 ? "1 macro" : "\(macros.macros.count) macros"),
            (.appProfiles, "IconSliders", "Per-app rules",
             profiles.customizedCount == 0 ? "Same everywhere"
                : (profiles.customizedCount == 1 ? "1 app customized" : "\(profiles.customizedCount) apps customized")),
            (.calendar, "IconBrain", "Calendar",
             CalendarMeetingContext.isAuthorized ? "Connected" : "Off"),
            (.export, "IconGlobe", "Export destinations",
             ExportPreferences.shared.summary),
            (.behavior, "IconSliders", "Behavior", "Sounds, open at login"),
            (.privacy, "IconShield", "Privacy",
             "Nothing leaves your Mac"),
        ]
    }

    @ViewBuilder
    private func subpage(_ route: SettingsRoute) -> some View {
        switch route {
        case .profile:       ProfileSettings(settings: settings)
        case .activation:    ActivationSettings(settings: settings)
        case .cleanup:       CleanupSettings(settings: settings)
        case .languages:     LanguageSettings(settings: settings)
        case .context:       ContextSettings(settings: settings)
        case .behavior:      BehaviorSettings(settings: settings)
        case .voiceCommands: VoiceCommandsSettings(macros: macros)
        case .appProfiles:   AppProfilesSettings(profiles: profiles, settings: settings)
        case .calendar:      CalendarSettings()
        case .export:        ExportDestinationsSettings()
        case .privacy:       PrivacySettings()
        case .permissions:   PermissionsSettings(permissions: permissions, onRetryHotKey: onRetryHotKey)
        case .developer:     DeveloperSettings(settings: settings)
        }
    }
}

/// Developer-only tools, surfaced when `Dev.isEnabled` (Debug builds, or a
/// release build with `TalkieDevMode` set). Replays the first-run onboarding
/// without wiping any of the user's data.
private struct DeveloperSettings: View {
    @ObservedObject var settings: AppSettings
    @AppStorage(Dev.devModeKey) private var devMode = false
    @State private var replaying = false

    var body: some View {
        SubPage(title: "Developer",
                subtitle: "Tools for building Talkie. Hidden from normal users.") {
            SettingsCard(
                header: "Onboarding",
                footer: "Replays the first-run flow so you can review it. Your name, settings, history, and dictionary are untouched."
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

            SettingsCard(
                header: "Developer mode",
                footer: "Keeps this Developer page available in a Release build too. Debug builds always show it."
            ) {
                SettingsToggleRow(
                    title: "Keep developer mode on",
                    subtitle: "Persists across launches.",
                    isOn: $devMode
                )
            }
        }
    }
}

/// A single settings-index row: a clay brand icon, title + state subtitle, and a
/// chevron, with a soft hover highlight. Rows live inside one grouped card.
private struct SettingsRowView: View {
    let icon: String
    let title: String
    let subtitle: String
    var badge: Bool = false
    let route: SettingsRoute
    /// When set, renders an SF Symbol instead of a Brand clay icon (e.g. the
    /// Developer row, which has no clay asset).
    var systemIcon: String? = nil
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                Group {
                    if let systemIcon {
                        Image(systemName: systemIcon)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                    } else if let img = Brand.image(icon) {
                        Image(nsImage: img).resizable().scaledToFit()
                    } else {
                        Image(systemName: "square.dashed").foregroundStyle(Theme.inkTertiary)
                    }
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.talkieHeading(14.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.talkieHeading(12.5, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if badge { Circle().fill(Theme.danger).frame(width: 7, height: 7) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(hovering ? Theme.inkSecondary.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

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
        SubPage(title: "Profile", subtitle: "What Talkie calls you.") {
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

private struct ActivationSettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        SubPage(title: "Activation & insertion",
                subtitle: "The key that starts Talkie, and how it places your text.") {
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
        SubPage(title: "Cleanup & style", subtitle: "How Talkie polishes what you say.") {
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
        SubPage(title: "Languages",
                subtitle: "Tap the ones you speak — Talkie auto-detects between them.") {
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
    var body: some View {
        SubPage(title: "Context & learning",
                subtitle: "What Talkie reads around you, and how it improves over time.") {
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
        }
    }
}

private struct BehaviorSettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        SubPage(title: "Behavior", subtitle: "The small touches.") {
            SettingsCard {
                SettingsToggleRow(title: "Play sounds", isOn: $settings.playSounds)
                SettingsDivider()
                SettingsToggleRow(title: "Open Talkie at login", isOn: $settings.launchAtLogin)
            }
        }
    }
}

// MARK: - Dictionary

private struct DictionarySettings: View {
    @ObservedObject var dictionary: DictionaryStore
    @State private var newTerm: String = ""

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
                    }
                }
                .talkieCard()

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
        }
    }
}

// MARK: - Permissions

private struct PermissionsSettings: View {
    @ObservedObject var permissions: PermissionsModel
    let onRetryHotKey: () -> Void

    var body: some View {
        SubPage(title: "Permissions",
                subtitle: "Talkie needs three permissions to work — all local.") {
            SettingsCard(footer: "After granting Input Monitoring or Accessibility, you may need to quit and reopen Talkie for the change to take effect.") {
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
