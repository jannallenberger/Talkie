import AppKit
import SwiftUI

enum SettingsTab: Hashable, CaseIterable {
    case dashboard
    case history
    case dictionary
    case vibeCoding
    case general
    case permissions

    var title: String {
        switch self {
        case .dashboard:   return "Dashboard"
        case .history:     return "History"
        case .dictionary:  return "Dictionary"
        case .vibeCoding:  return "Vibe Coding"
        case .general:     return "Settings"
        case .permissions: return "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .dashboard:   return "square.grid.2x2.fill"
        case .history:     return "clock.fill"
        case .dictionary:  return "character.book.closed.fill"
        case .vibeCoding:  return "chevron.left.forwardslash.chevron.right"
        case .general:     return "gearshape.fill"
        case .permissions: return "lock.shield.fill"
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
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: 0x191815) : NSColor(hex: 0xF4F2EA)
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
    @ObservedObject var router: SettingsRouter
    let onRetryHotKey: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(router: router, settings: settings, permissions: permissions)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.canvas)
        }
        .frame(minWidth: 900, minHeight: 640)
        .background(Theme.canvas)
    }

    @ViewBuilder
    private var content: some View {
        switch router.selectedTab {
        case .dashboard:
            DashboardView(settings: settings, stats: stats, history: history,
                          activity: activity, appUsage: appUsage, router: router)
        case .history:
            HistorySettings(history: history)
        case .dictionary:
            DictionarySettings(dictionary: dictionary)
        case .vibeCoding:
            VibeCodingView(projectIndex: projectIndex, settings: settings)
        case .general:
            GeneralSettings(settings: settings)
        case .permissions:
            PermissionsSettings(permissions: permissions, onRetryHotKey: onRetryHotKey)
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var router: SettingsRouter
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Brand lockup — the actual app icon + serif wordmark.
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                Text("Talkie")
                    .font(.talkieDisplay(21))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)

            ForEach(SettingsTab.allCases, id: \.self) { tab in
                SidebarButton(
                    tab: tab,
                    isActive: router.selectedTab == tab,
                    badge: tab == .permissions && !permissions.allGranted
                ) { router.selectedTab = tab }
            }

            Spacer()

            // Footer: live activation hint.
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(text: settings.activationMode == .holdToTalk ? "Hold to talk" : "Tap to toggle")
                Text(settings.activationKey.displayName)
                    .font(.talkieHeading(12, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .padding(.top, 44) // clear the transparent titlebar / traffic lights
        .frame(width: 214)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.canvasRaised)
    }
}

private struct SidebarButton: View {
    let tab: SettingsTab
    let isActive: Bool
    var badge: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(isActive ? Theme.coral : Theme.inkSecondary)
                Text(tab.title)
                    .font(.talkieHeading(13.5, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? Theme.ink : Theme.inkSecondary)
                Spacer()
                if badge {
                    Circle().fill(Theme.coral).frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isActive ? Theme.coralWash : (hovering ? Theme.surfaceSunken : .clear))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(formatter.string(from: entry.date))
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkTertiary)
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

private struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings

    private func toggleLanguage(_ id: String, on: Bool) {
        var langs = settings.spokenLanguages
        if on {
            if !langs.contains(id) { langs.append(id) }
        } else {
            guard langs.count > 1 else { return } // always keep at least one
            langs.removeAll { $0 == id }
        }
        settings.spokenLanguages = langs
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Settings")
                Form {
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
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Section("Insertion") {
                        Picker("Insert text by", selection: $settings.insertionMode) {
                            ForEach(InsertionMode.allCases) { Text($0.displayName).tag($0) }
                        }
                    }

                    Section("Smart cleanup") {
                        Toggle("Adapt the style to the app", isOn: $settings.appAdaptiveCleanup)

                        if settings.appAdaptiveCleanup {
                            Text("Talkie picks a personality per app — friendly for Messages, professional for Mail, faithful for code.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            AppStylePickers(settings: settings)
                        } else {
                            Picker("Cleanup level", selection: $settings.cleanupLevel) {
                                ForEach(CleanupLevel.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            Text(settings.cleanupLevel.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        if let warning = CleanupEngine.unavailableMessage {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        } else {
                            Text("Resolves spoken self-corrections and fixes grammar. Runs entirely on your Mac; nothing leaves the device.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Section("Basic cleanup") {
                        Toggle("Capitalize the first letter", isOn: $settings.autoCapitalize)
                        Toggle("Remove filler words (um, uh, hmm…)", isOn: $settings.cleanupFillers)
                        Text("These apply when Smart cleanup isn't rewriting the text.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }

                    Section("Context awareness") {
                        Toggle("Use the app I'm dictating into for context", isOn: $settings.contextAwareness)
                        Text("Talkie reads the names already on screen — who you're messaging, the file you have open — and biases recognition so it spells them right. Local and read-only.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Section("Learning") {
                        Toggle("Learn from my edits (auto-improve the dictionary)", isOn: $settings.learnFromEdits)
                        Text("When you fix a word right after dictating, Talkie remembers the correction. Auto-added rules are tagged in the Dictionary tab — prune any you don't want.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Section("Languages you speak") {
                        ForEach(talkieLanguageCatalog) { lang in
                            Toggle(lang.name, isOn: Binding(
                                get: { settings.spokenLanguages.contains(lang.id) },
                                set: { toggleLanguage(lang.id, on: $0) }
                            ))
                        }
                        Text(settings.spokenLanguages.count > 1
                             ? "Talkie auto-detects which of these you're speaking each time."
                             : "Pick more than one to have Talkie auto-detect your language.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Section("Behavior") {
                        Toggle("Play sounds", isOn: $settings.playSounds)
                        Toggle("Open Talkie at login", isOn: $settings.launchAtLogin)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 720)
            }
            .padding(28)
        }
    }
}

// MARK: - Dictionary

private struct DictionarySettings: View {
    @ObservedObject var dictionary: DictionaryStore
    @State private var newTerm: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Dictionary",
                       subtitle: "Names, brands, and jargon Talkie should spell correctly.")

            HStack {
                TextField("Add a word or phrase…", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if dictionary.vocabulary.isEmpty {
                Text("No custom words yet.")
                    .font(.callout)
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                List {
                    ForEach(dictionary.vocabulary, id: \.self) { term in
                        Text(term)
                    }
                    .onDelete { dictionary.removeVocabulary(at: $0) }
                }
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
            }

            HStack {
                Text("Replacements")
                    .font(.talkieDisplay(17))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button {
                    dictionary.addReplacement()
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            .padding(.top, 4)
            Text("Rewrite what was heard into what you meant — e.g. “correlate” → “Coralate”.")
                .font(.callout)
                .foregroundStyle(Theme.inkSecondary)

            List {
                ForEach($dictionary.replacements) { $rule in
                    ReplacementRow(rule: $rule)
                }
                .onDelete { dictionary.removeReplacements(at: $0) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
        .padding(28)
        .onChange(of: dictionary.replacements) { _, _ in dictionary.save() }
        .onChange(of: dictionary.vocabulary) { _, _ in dictionary.save() }
    }

    private func addTerm() {
        dictionary.addVocabularyTerm(newTerm)
        newTerm = ""
    }
}

private struct ReplacementRow: View {
    @Binding var rule: Replacement

    var body: some View {
        HStack(spacing: 8) {
            TextField("heard", text: $rule.from)
                .textFieldStyle(.roundedBorder)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            TextField("written", text: $rule.to)
                .textFieldStyle(.roundedBorder)
            if rule.isLearned {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.coral)
                    .help("Learned automatically from your edits")
            }
            Toggle("Aa", isOn: $rule.caseSensitive)
                .toggleStyle(.button)
                .help("Case sensitive")
            Toggle("W", isOn: $rule.wholeWord)
                .toggleStyle(.button)
                .help("Whole word only")
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
