import AppKit
import SwiftUI

/// Where exported notes land, and how they're formatted — persisted for the
/// `NoteDestination` layer (`TalkieFolderDestination` / `ObsidianVaultDestination`).
///
/// House style: a tiny `@MainActor` `ObservableObject` with an atomic JSON write
/// to Application Support, failure-tolerant decode (a missing/corrupt file starts
/// at the zero-config default — the plain `~/Talkie Meetings/` folder, exactly
/// today's behaviour). The dictation/meeting writers read `resolvedDestination()`
/// to pick where a note goes; this is the single place that choice lives.
@MainActor
final class ExportPreferences: ObservableObject {
    /// One shared instance so the Settings index subtitle and the pane agree, and
    /// so the export writers read the same choice without re-decoding.
    static let shared = ExportPreferences()

    /// Which destination kind notes are written to.
    enum Destination: String, Codable, CaseIterable, Identifiable {
        /// The zero-config default: plain Markdown in `~/Talkie Meetings/`.
        case talkieFolder
        /// A user-picked folder. If it's an Obsidian vault (`.obsidian` present)
        /// Talkie formats for Obsidian automatically; otherwise it writes plain
        /// Markdown there. No format toggles — the folder decides. (See
        /// `resolvedDestination()`.)
        case folder

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .talkieFolder: return "Talkie Meetings folder".loc
            case .folder:       return "A folder I choose".loc
            }
        }
    }

    @Published var destination: Destination { didSet { save() } }
    /// The chosen folder when `destination == .folder` (absolute path).
    @Published var folderPath: String { didSet { save() } }
    /// The exact name of a macOS Shortcut to run after a meeting note is saved, or
    /// nil = off (the default). When set, the meeting writer runs it via
    /// `ShortcutsRunner`, feeding the saved note's path as input. nil keeps today's
    /// behaviour byte-identical — nothing runs. (G8.)
    @Published var postSaveShortcutName: String? { didSet { save() } }

    private let fileURL: URL

    private init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("export_prefs.json")
        // Zero-config defaults reproduce today's plain-folder behaviour exactly.
        destination = .talkieFolder
        folderPath = ""
        postSaveShortcutName = nil   // off by default → finishing a meeting runs nothing
        load()
    }

    /// Whether the picked folder exists and is writable (so the pane can warn).
    var folderIsAccessible: Bool {
        guard !folderPath.isEmpty else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir),
              isDir.boolValue else { return false }
        return FileManager.default.isWritableFile(atPath: folderPath)
    }

    /// True when `path` looks like an Obsidian vault — i.e. it contains a
    /// `.obsidian` config directory. Pure and cheap (one `stat`); evaluated FRESH
    /// inside `resolvedDestination()` on every export rather than cached, so a
    /// vault the user creates *after* picking the folder (or converts a plain
    /// folder into) is honoured on the very next note with zero settings change.
    ///
    /// `nonisolated` because it reads no `@Published` state — just the filesystem —
    /// so `resolvedDestination()` and the tests can call it directly (the pure
    /// helper it is, per the house idiom).
    nonisolated static func isObsidianVault(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let dotObsidian = URL(fileURLWithPath: path)
            .appendingPathComponent(".obsidian", isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dotObsidian.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// True when the currently-picked folder is a vault — drives the status note
    /// in the pane. Same fresh check the resolver uses, so the UI and the actual
    /// export never disagree.
    var pickedFolderIsVault: Bool {
        folderIsAccessible && Self.isObsidianVault(folderPath)
    }

    /// The settings-index subtitle ("Talkie folder" / a folder name / "Pick a folder").
    var summary: String {
        switch destination {
        case .talkieFolder: return "Talkie folder"
        case .folder:
            guard !folderPath.isEmpty else { return "Pick a folder" }
            return URL(fileURLWithPath: folderPath).lastPathComponent
        }
    }

    /// The concrete `NoteDestination` the export writers should use. Export is one
    /// question — *where* — and the vault case configures itself:
    ///
    /// - `.talkieFolder` → the zero-config plain-Markdown default in `~/Talkie Meetings/`.
    /// - `.folder` + a `.obsidian` directory present → full Obsidian formatting
    ///   (front-matter, `[[wikilinks]]`, a `#talkie` tag, human-titled filenames).
    /// - `.folder` with no `.obsidian` → plain Markdown written into *that* folder
    ///   (no front-matter / wikilinks / tags, timestamped `{datetime}-{kind}` names).
    /// - `.folder` that's missing or unwritable → falls back to the zero-config
    ///   default so a note is never lost to a bad path.
    ///
    /// The vault check is run FRESH here (not cached at pick time), so a vault
    /// created after the folder was chosen upgrades the next export automatically.
    func resolvedDestination() -> any NoteDestination {
        switch destination {
        case .talkieFolder:
            return TalkieFolderDestination()
        case .folder:
            guard folderIsAccessible else { return TalkieFolderDestination() }
            let isVault = Self.isObsidianVault(folderPath)
            return ObsidianVaultDestination(
                vaultURL: URL(fileURLWithPath: folderPath),
                subfolder: "",
                fileNameTemplate: isVault ? "{date}-{title}" : "{datetime}-{kind}",
                extraTags: isVault ? ["talkie"] : [],
                includeFrontMatter: isVault,
                includeWikilinks: isVault,
                includeTags: isVault
            )
        }
    }

    // MARK: Persistence

    /// Only `destination` + `folderPath` persist now — formatting is derived from
    /// `.obsidian` detection, not stored. Old `export_prefs.json` files that still
    /// carry `includeFrontMatter` / `includeWikilinks` / `includeTags` decode fine:
    /// `JSONDecoder` ignores keys absent from the struct, so those extra fields are
    /// simply dropped on the next save.
    private struct Snapshot: Codable {
        var destination: Destination
        var folderPath: String
        /// Optional so an `export_prefs.json` written before G8 (no key) decodes with
        /// the shortcut off, and an older app build simply ignores the newer key.
        var postSaveShortcutName: String?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        destination = s.destination
        folderPath = s.folderPath
        postSaveShortcutName = s.postSaveShortcutName
    }

    private func save() {
        let s = Snapshot(destination: destination, folderPath: folderPath,
                         postSaveShortcutName: postSaveShortcutName)
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// "Export destinations" — choose where your meetings and dictations are saved,
/// and how the Markdown is shaped. Reuses the shared `SubPage` / `SettingsCard`
/// / `SettingsRow` vocabulary so it's indistinguishable from the other panes.
struct ExportDestinationsSettings: View {
    @ObservedObject private var prefs = ExportPreferences.shared
    /// The installed Shortcuts, loaded once when the pane appears (off-main, via
    /// `ShortcutsRunner.list()`). Empty until it loads, or if the user has none —
    /// the picker then shows only "None". A stable tag (`String?`) drives the Picker.
    @State private var shortcutNames: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(
                header: "Destination",
                footer: prefs.destination == .talkieFolder
                    ? "Plain Markdown in ~/Talkie Meetings — a folder you own, easy to point any tool at. No third-party app needed."
                    : "Writes Markdown into the folder you pick. Point it at an Obsidian vault and Talkie formats for Obsidian automatically."
            ) {
                SettingsRow(title: "Save notes to") {
                    Picker("", selection: $prefs.destination) {
                        ForEach(ExportPreferences.Destination.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if prefs.destination == .folder {
                    SettingsDivider()
                    SettingsRow(
                        title: "Folder",
                        subtitle: prefs.folderPath.isEmpty
                            ? "No folder chosen yet"
                            : prefs.folderPath
                    ) {
                        Button(prefs.folderPath.isEmpty ? "Choose…" : "Change…", action: pickFolder)
                    }
                    if !prefs.folderPath.isEmpty, !prefs.folderIsAccessible {
                        // Bad path takes priority: say why, and that nothing is lost.
                        SettingsDivider(leadingInset: 0)
                        SettingsNote(text: "That folder isn't readable right now — notes will fall back to ~/Talkie Meetings until it's reachable.".loc,
                                     tone: Theme.warning, icon: "exclamationmark.triangle.fill")
                    } else if prefs.folderIsAccessible {
                        // Reachable folder: tell the user, honestly, what shape the
                        // notes will take — decided by whether it's a vault, with no
                        // knob to set. This is the whole feature, made visible.
                        SettingsDivider(leadingInset: 0)
                        if prefs.pickedFolderIsVault {
                            SettingsNote(text: "Obsidian vault detected — notes will include front-matter, [[wikilinks]] and #tags.".loc,
                                         tone: Theme.inkTertiary, icon: "sparkles")
                        } else {
                            SettingsNote(text: "Plain Markdown. (Tip: pick a vault folder and Talkie formats for Obsidian automatically.)".loc,
                                         tone: Theme.inkTertiary)
                        }
                    }
                }
            }

            // The one declared on-save automation row (G8): after a meeting note is
            // saved, optionally run a macOS Shortcut with the note's path as input.
            // Default "None" = byte-identical to today (nothing runs). Exact-name only;
            // the list is whatever `shortcuts list` reports on this Mac.
            SettingsCard(
                header: "After saving",
                footer: "Runs one of your macOS Shortcuts when a meeting note finishes saving, handing it the note's file. Stays on your Mac — no network."
            ) {
                SettingsRow(title: "After saving a meeting note, run") {
                    Picker("", selection: postSaveBinding) {
                        Text("None".loc).tag(String?.none)
                        ForEach(shortcutNames, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
        .task {
            // Load the installed Shortcuts once when the pane appears — off-main, and
            // tolerant of none/failure (an empty list just leaves "None" selectable).
            shortcutNames = await ShortcutsRunner.list()
        }
    }

    /// Binding for the on-save Picker. A previously-chosen shortcut that is no longer
    /// installed still shows as selected (its tag isn't in `shortcutNames`, so SwiftUI
    /// renders it blank until re-picked) — we don't silently clear the saved choice on
    /// a transient empty list (e.g. the tool was slow), only when the user changes it.
    private var postSaveBinding: Binding<String?> {
        Binding(
            get: { prefs.postSaveShortcutName },
            set: { prefs.postSaveShortcutName = $0 }
        )
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick the folder Talkie should write your notes into."
        if !prefs.folderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: prefs.folderPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            prefs.folderPath = url.path
        }
    }
}
