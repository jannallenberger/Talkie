import AppKit
import SwiftUI

enum SettingsTab: Hashable, CaseIterable {
    case dashboard
    case history
    case meetings
    case dictionary
    case vibeCoding
    case general

    var title: String {
        switch self {
        case .dashboard:   return "Dashboard"
        case .history:     return "History"
        case .meetings:    return "Meetings"
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
            } else {
                OnboardingView(settings: settings, permissions: permissions, onRetryHotKey: onRetryHotKey)
            }
        }
        .frame(minWidth: 900, minHeight: 640)
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
        case .dictionary:
            DictionarySettings(dictionary: dictionary)
        case .vibeCoding:
            VibeCodingView(projectIndex: projectIndex, settings: settings)
        case .general:
            SettingsHome(settings: settings, permissions: permissions, onRetryHotKey: onRetryHotKey)
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
    @State private var hovering = false

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
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
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
        .onHover { hovering = $0 }
    }
}

// MARK: - General

/// Per-app-category cleanup-style pickers. Extracted into its own view so the
/// (large) GeneralSettings body stays inside the Swift type-checker's budget.
private struct AppStylePickers: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        ForEach(AppCategory.allCases, id: \.self) { category in
            AppStyleRow(settings: settings, category: category)
        }
    }
}

private struct AppStyleRow: View {
    @ObservedObject var settings: AppSettings
    let category: AppCategory

    var body: some View {
        Picker(category.label, selection: binding) {
            ForEach(CleanupStyle.allCases) { style in
                Text(style.displayName).tag(style)
            }
        }
    }

    private var binding: Binding<CleanupStyle> {
        Binding(
            get: { settings.cleanupStyle(for: category) },
            set: { settings.appCleanupStyles[category.rawValue] = $0.rawValue }
        )
    }
}

private enum SettingsRoute: Hashable {
    case profile, activation, cleanup, languages, context, behavior, permissions
}

/// Settings landing — a tidy index of category rows, each pushing a focused
/// subpage so no single screen floods the user with options.
private struct SettingsHome: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsModel
    let onRetryHotKey: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: "Settings",
                               subtitle: "Tune how Talkie listens, cleans up, and behaves.")
                    VStack(spacing: 10) {
                        row(.profile, "person.crop.circle.fill", Theme.featherBlue, "Profile",
                            settings.userName.isEmpty ? "Set your name" : settings.userName)
                        row(.activation, "keyboard.fill", Theme.featherCoral, "Activation & insertion",
                            "\(settings.activationKey.displayName) · \(settings.activationMode == .holdToTalk ? "Hold" : "Toggle")")
                        row(.cleanup, "wand.and.stars", Theme.featherPlum, "Cleanup & style",
                            settings.appAdaptiveCleanup ? "Adapts per app" : settings.cleanupLevel.displayName)
                        row(.languages, "globe", Theme.featherGreen, "Languages",
                            "\(settings.spokenLanguages.count) selected")
                        row(.context, "sparkles", Theme.featherGold, "Context & learning",
                            settings.contextAwareness ? "Context on" : "Context off")
                        row(.behavior, "switch.2", Theme.featherBlue, "Behavior",
                            "Sounds, open at login")
                        row(.permissions, "lock.shield.fill",
                            permissions.allGranted ? Theme.featherGreen : Theme.warning,
                            "Permissions",
                            permissions.allGranted ? "All granted" : "Action needed",
                            badge: !permissions.allGranted)
                    }
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

    private func row(_ route: SettingsRoute, _ icon: String, _ tint: Color,
                     _ title: String, _ subtitle: String, badge: Bool = false) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.talkieHeading(14, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if badge { Circle().fill(Theme.danger).frame(width: 7, height: 7) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
            .talkieCard(padding: 14)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func subpage(_ route: SettingsRoute) -> some View {
        switch route {
        case .profile:     ProfileSettings(settings: settings)
        case .activation:  ActivationSettings(settings: settings)
        case .cleanup:     CleanupSettings(settings: settings)
        case .languages:   LanguageSettings(settings: settings)
        case .context:     ContextSettings(settings: settings)
        case .behavior:    BehaviorSettings(settings: settings)
        case .permissions: PermissionsSettings(permissions: permissions, onRetryHotKey: onRetryHotKey)
        }
    }
}

/// Shared scaffold: serif title pinned above a grouped form that scrolls.
private struct SubPage<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: title, subtitle: subtitle)
                .padding(.horizontal, 28)
                .padding(.top, 28)
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas)
        .navigationTitle("")
    }
}

private struct ProfileSettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        SubPage(title: "Profile", subtitle: "What Talkie calls you.") {
            Section {
                TextField("Your name", text: $settings.userName)
            } footer: {
                Text("Shown on your dashboard as “Welcome back”. Stays on your Mac.")
            }
        }
    }
}

private struct ActivationSettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        SubPage(title: "Activation & insertion") {
            Section("Activation") {
                Picker("Dictation key", selection: $settings.activationKey) {
                    ForEach(ActivationKey.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Mode", selection: $settings.activationMode) {
                    ForEach(ActivationMode.allCases) { Text($0.displayName).tag($0) }
                }
                Text(settings.activationMode == .holdToTalk
                     ? "Hold the key, speak, release to insert the text."
                     : "Tap the key to start, tap again to stop and insert.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Insertion") {
                Picker("Insert text by", selection: $settings.insertionMode) {
                    ForEach(InsertionMode.allCases) { Text($0.displayName).tag($0) }
                }
            }
        }
    }
}

private struct CleanupSettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        SubPage(title: "Cleanup & style", subtitle: "How Talkie polishes what you say.") {
            Section("Smart cleanup") {
                Toggle("Adapt the style to the app", isOn: $settings.appAdaptiveCleanup)
                if settings.appAdaptiveCleanup {
                    Text("Talkie picks a personality per app — friendly for Messages, professional for Mail, faithful for code.")
                        .font(.callout).foregroundStyle(.secondary)
                    AppStylePickers(settings: settings)
                } else {
                    Picker("Cleanup level", selection: $settings.cleanupLevel) {
                        ForEach(CleanupLevel.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.cleanupLevel.detail).font(.callout).foregroundStyle(.secondary)
                }
                if let warning = CleanupEngine.unavailableMessage {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    Text("Resolves spoken self-corrections and fixes grammar. Runs entirely on your Mac; nothing leaves the device.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Section("Basic cleanup") {
                Toggle("Capitalize the first letter", isOn: $settings.autoCapitalize)
                Toggle("Remove filler words (um, uh, hmm…)", isOn: $settings.cleanupFillers)
                Text("These apply when Smart cleanup isn't rewriting the text.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct LanguageSettings: View {
    @ObservedObject var settings: AppSettings
    private func toggle(_ id: String, on: Bool) {
        var langs = settings.spokenLanguages
        if on {
            if !langs.contains(id) { langs.append(id) }
        } else {
            guard langs.count > 1 else { return }
            langs.removeAll { $0 == id }
        }
        settings.spokenLanguages = langs
    }
    var body: some View {
        SubPage(title: "Languages", subtitle: "Talkie auto-detects between the ones you pick.") {
            Section("Languages you speak") {
                ForEach(talkieLanguageCatalog) { lang in
                    Toggle(lang.name, isOn: Binding(
                        get: { settings.spokenLanguages.contains(lang.id) },
                        set: { toggle(lang.id, on: $0) }
                    ))
                }
                Text(settings.spokenLanguages.count > 1
                     ? "Talkie auto-detects which of these you're speaking each time."
                     : "Pick more than one to have Talkie auto-detect your language.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ContextSettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        SubPage(title: "Context & learning") {
            Section("Context awareness") {
                Toggle("Use the app I'm dictating into for context", isOn: $settings.contextAwareness)
                Text("Talkie reads the names already on screen — who you're messaging, the file you have open — and biases recognition so it spells them right. Local and read-only.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Learning") {
                Toggle("Learn from my edits (auto-improve the dictionary)", isOn: $settings.learnFromEdits)
                Text("When you fix a word right after dictating, Talkie remembers the correction. Auto-added rules are tagged in the Dictionary tab — prune any you don't want.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct BehaviorSettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        SubPage(title: "Behavior") {
            Section {
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Open Talkie at login", isOn: $settings.launchAtLogin)
            }
        }
    }
}

// MARK: - Dictionary

private struct DictionarySettings: View {
    @ObservedObject var dictionary: DictionaryStore
    @State private var newTerm: String = ""

    private let chipCols = [GridItem(.adaptive(minimum: 116), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Dictionary",
                           subtitle: "Names, brands, and jargon Talkie should spell correctly.")

                // Custom vocabulary.
                VStack(alignment: .leading, spacing: 12) {
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
                    if dictionary.vocabulary.isEmpty {
                        Text("No custom words yet — add names or jargon Talkie keeps mishearing.")
                            .font(.talkieHeading(13, weight: .regular))
                            .foregroundStyle(Theme.inkTertiary)
                    } else {
                        LazyVGrid(columns: chipCols, alignment: .leading, spacing: 8) {
                            ForEach(dictionary.vocabulary, id: \.self) { term in
                                VocabChip(term: term) { removeVocab(term) }
                            }
                        }
                    }
                }
                .talkieCard()

                // Replacements.
                VStack(alignment: .leading, spacing: 12) {
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
                        VStack(spacing: 8) {
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
            if rule.isLearned {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.coral)
                    .help("Learned automatically from your edits")
            }
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
            .help("Delete rule")
        }
    }
}

// MARK: - Permissions

private struct PermissionsSettings: View {
    @ObservedObject var permissions: PermissionsModel
    let onRetryHotKey: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Permissions",
                       subtitle: "Talkie needs three permissions to work — all local.")

            PermissionRow(
                title: "Microphone",
                detail: "Capture your voice while you dictate.",
                granted: permissions.microphone,
                action: { Task { await permissions.requestMicrophone() } },
                openSettings: permissions.openMicrophoneSettings
            )

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

            PermissionRow(
                title: "Accessibility",
                detail: "Paste the transcribed text into the app you're using.",
                granted: permissions.accessibility,
                action: permissions.promptAccessibility,
                openSettings: permissions.openAccessibilitySettings
            )

            Spacer()

            Text("After granting Input Monitoring or Accessibility, you may need to quit and reopen Talkie for the change to take effect.")
                .font(.caption)
                .foregroundStyle(Theme.inkTertiary)

            HStack {
                Button("Re-check") { permissions.refresh() }
                Button("Quit & Reopen") { relaunch() }
                Spacer()
                if permissions.allGranted {
                    Label("All set", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.positive)
                }
            }
        }
        .padding(28)
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(granted ? Theme.positive : Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.talkieHeading(14))
                    .foregroundStyle(Theme.ink)
                Text(detail).font(.callout).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            if !granted {
                VStack(spacing: 4) {
                    Button("Grant", action: action)
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .talkieCard(padding: 14)
    }
}
