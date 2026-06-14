import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case history
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
        onRetryHotKey: @escaping () -> Void
    ) {
        let root = MainView(
            settings: settings,
            dictionary: dictionary,
            permissions: permissions,
            history: history,
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
    @ObservedObject var router: SettingsRouter
    let onRetryHotKey: () -> Void

    var body: some View {
        TabView(selection: $router.selectedTab) {
            HistorySettings(history: history)
                .tabItem { Label("History", systemImage: "clock") }
                .tag(SettingsTab.history)

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

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var localeDraft: String = ""

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

            Section("Text cleanup") {
                Toggle("Capitalize the first letter", isOn: $settings.autoCapitalize)
                Toggle("Remove filler words (um, uh, hmm…)", isOn: $settings.cleanupFillers)
            }

            Section("Language") {
                TextField("Locale (e.g. en-US)", text: $localeDraft)
                    .onSubmit { settings.localeIdentifier = localeDraft.trimmingCharacters(in: .whitespaces) }
                Text("Press Return to apply. Locale changes take effect after you reopen Talkie.")
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
        .onAppear { localeDraft = settings.localeIdentifier }
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
