import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case history
    case stats
    case general
    case dictionary
    case permissions
}

@MainActor
final class SettingsRouter: ObservableObject {
    @Published var selectedTab: SettingsTab = .history
}

/// The app's main window (Dock app). Hosts History + settings tabs.
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
        onRetryHotKey: @escaping () -> Void
    ) {
        let root = MainView(
            settings: settings,
            dictionary: dictionary,
            permissions: permissions,
            history: history,
            stats: stats,
            router: router,
            onRetryHotKey: onRetryHotKey
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Talkie"
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
    @ObservedObject var router: SettingsRouter
    let onRetryHotKey: () -> Void

    var body: some View {
        TabView(selection: $router.selectedTab) {
            HistorySettings(history: history)
                .tabItem { Label("History", systemImage: "clock") }
                .tag(SettingsTab.history)

            StatsSettings(stats: stats, history: history)
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag(SettingsTab.stats)

            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            DictionarySettings(dictionary: dictionary)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
                .tag(SettingsTab.dictionary)

            PermissionsSettings(permissions: permissions, onRetryHotKey: onRetryHotKey)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
        }
        .frame(minWidth: 680, minHeight: 620)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Dictation History")
                    .font(.headline)
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
                        .foregroundStyle(.tertiary)
                    Text("No dictations yet")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Hold your dictation key and speak — what you say will show up here.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(history.entries) { entry in
                        HistoryRow(entry: entry, formatter: Self.dateFormatter) {
                            copyToClipboard(entry.text)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { history.delete(history.entries[index]) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding()
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
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(formatter.string(from: entry.date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    onCopy()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy this dictation")
            }
            Text(entry.text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Stats (scoreboard)

private struct StatsSettings: View {
    @ObservedObject var stats: StatsStore
    @ObservedObject var history: HistoryStore

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your Dictation Stats")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 12) {
                StatCard(title: "Total words", value: stats.totalWords.formatted(), icon: "text.word.spacing")
                StatCard(title: "Dictations", value: stats.totalDictations.formatted(), icon: "mic.fill")
                StatCard(title: "Average speed",
                         value: stats.averageWPM > 0 ? "\(Int(stats.averageWPM.rounded())) wpm" : "—",
                         icon: "speedometer")
                StatCard(title: "Best speed",
                         value: stats.bestWPM > 0 ? "\(Int(stats.bestWPM.rounded())) wpm" : "—",
                         icon: "bolt.fill")
                StatCard(title: "Words (last 7 days)", value: history.wordsLast7Days.formatted(), icon: "calendar")
                StatCard(title: "Time spoken", value: formatDuration(stats.totalDurationSec), icon: "clock.fill")
            }

            Text("Fixes by Talkie")
                .font(.headline)
                .padding(.top, 4)
            LazyVGrid(columns: columns, spacing: 12) {
                StatCard(title: "Total fixes", value: stats.totalFixes.formatted(), icon: "wand.and.stars")
                StatCard(title: "Words polished", value: stats.wordsCorrected.formatted(), icon: "sparkles")
                StatCard(title: "Dictionary fixes", value: stats.dictionaryFixes.formatted(), icon: "character.book.closed")
            }

            HStack {
                Spacer()
                Button(role: .destructive) { stats.reset() } label: {
                    Label("Reset stats", systemImage: "arrow.counterclockwise")
                }
            }
            .padding(.top, 4)
        }
        .padding()
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.4)))
    }
}

// MARK: - General

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
                Picker("Cleanup level", selection: $settings.cleanupLevel) {
                    ForEach(CleanupLevel.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settings.cleanupLevel.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if settings.cleanupLevel != .none, let warning = CleanupEngine.unavailableMessage {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if settings.cleanupLevel != .none {
                    Text("Resolves spoken self-corrections and fixes grammar. Runs entirely on your Mac; nothing leaves the device.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Basic cleanup") {
                Toggle("Capitalize the first letter", isOn: $settings.autoCapitalize)
                Toggle("Remove filler words (um, uh, hmm…)", isOn: $settings.cleanupFillers)
                if settings.cleanupLevel != .none {
                    Text("Filler removal only applies when Smart cleanup is set to None.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
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
        .padding()
    }
}

// MARK: - Dictionary

private struct DictionarySettings: View {
    @ObservedObject var dictionary: DictionaryStore
    @State private var newTerm: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Vocabulary")
                .font(.headline)
            Text("Names, brands, and jargon Talkie should recognize and spell correctly.")
                .font(.callout)
                .foregroundStyle(.secondary)

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
                    .foregroundStyle(.tertiary)
            } else {
                List {
                    ForEach(dictionary.vocabulary, id: \.self) { term in
                        Text(term)
                    }
                    .onDelete { dictionary.removeVocabulary(at: $0) }
                }
                .frame(height: 110)
                .border(.quaternary)
            }

            Divider()

            HStack {
                Text("Replacements")
                    .font(.headline)
                Spacer()
                Button {
                    dictionary.addReplacement()
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            Text("Rewrite what was heard into what you meant — e.g. “correlate” → “Coralate”.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach($dictionary.replacements) { $rule in
                    ReplacementRow(rule: $rule)
                }
                .onDelete { dictionary.removeReplacements(at: $0) }
            }
            .border(.quaternary)
        }
        .padding()
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
                    .foregroundStyle(.purple)
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
            Text("Talkie needs three permissions to work.")
                .font(.headline)

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
                .foregroundStyle(.tertiary)

            HStack {
                Button("Re-check") { permissions.refresh() }
                Button("Quit & Reopen") { relaunch() }
                Spacer()
                if permissions.allGranted {
                    Label("All set", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .padding()
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
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
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
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }
}
