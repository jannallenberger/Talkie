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
        /// A user-picked folder (e.g. an Obsidian vault) with optional
        /// front-matter / wikilinks / tags.
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
    /// Prepend a YAML front-matter block (title, date, participants, …).
    @Published var includeFrontMatter: Bool { didSet { save() } }
    /// Render extracted people/projects as `[[wikilinks]]` in a Related block.
    @Published var includeWikilinks: Bool { didSet { save() } }
    /// Append a `#tag` line built from the note's tags.
    @Published var includeTags: Bool { didSet { save() } }

    private let fileURL: URL

    private init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("export_prefs.json")
        // Zero-config defaults reproduce today's plain-folder behaviour exactly.
        destination = .talkieFolder
        folderPath = ""
        includeFrontMatter = true
        includeWikilinks = false
        includeTags = false
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

    /// The settings-index subtitle ("Talkie folder" / a folder name / "Pick a folder").
    var summary: String {
        switch destination {
        case .talkieFolder: return "Talkie folder"
        case .folder:
            guard !folderPath.isEmpty else { return "Pick a folder" }
            return URL(fileURLWithPath: folderPath).lastPathComponent
        }
    }

    /// The concrete `NoteDestination` the export writers should use. Falls back to
    /// the zero-config default when "A folder I choose" is selected but the folder
    /// is missing — a note is never lost to a bad path.
    func resolvedDestination() -> any NoteDestination {
        switch destination {
        case .talkieFolder:
            return TalkieFolderDestination()
        case .folder:
            guard folderIsAccessible else { return TalkieFolderDestination() }
            return ObsidianVaultDestination(
                vaultURL: URL(fileURLWithPath: folderPath),
                subfolder: "",
                fileNameTemplate: includeWikilinks ? "{date}-{title}" : "{datetime}-{kind}",
                extraTags: includeTags ? ["talkie"] : [],
                includeFrontMatter: includeFrontMatter,
                includeWikilinks: includeWikilinks,
                includeTags: includeTags
            )
        }
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var destination: Destination
        var folderPath: String
        var includeFrontMatter: Bool
        var includeWikilinks: Bool
        var includeTags: Bool
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        destination = s.destination
        folderPath = s.folderPath
        includeFrontMatter = s.includeFrontMatter
        includeWikilinks = s.includeWikilinks
        includeTags = s.includeTags
    }

    private func save() {
        let s = Snapshot(destination: destination, folderPath: folderPath,
                         includeFrontMatter: includeFrontMatter,
                         includeWikilinks: includeWikilinks, includeTags: includeTags)
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// "Export destinations" — choose where your meetings and dictations are saved,
/// and how the Markdown is shaped. Reuses the shared `SubPage` / `SettingsCard`
/// / `SettingsRow` vocabulary so it's indistinguishable from the other panes.
struct ExportDestinationsSettings: View {
    @ObservedObject private var prefs = ExportPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(
                header: "Destination",
                footer: prefs.destination == .talkieFolder
                    ? "Plain Markdown in ~/Talkie Meetings — a folder you own, easy to point any tool at. No third-party app needed."
                    : "Writes Markdown into the folder you pick. Great for an Obsidian, Logseq, or daily-note vault."
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
                        SettingsDivider(leadingInset: 0)
                        SettingsNote(text: "That folder isn't readable right now — notes will fall back to ~/Talkie Meetings until it's reachable.",
                                     tone: Theme.warning, icon: "exclamationmark.triangle.fill")
                    }
                }
            }

            SettingsCard(
                header: "Markdown format",
                footer: "Front-matter and tags help a vault organize your notes; wikilinks turn the people and projects Talkie extracted into navigable [[links]]. The plain folder ignores these — they shape the folder export."
            ) {
                SettingsToggleRow(
                    title: "Front-matter",
                    subtitle: "A YAML header with title, date, and participants.",
                    isOn: $prefs.includeFrontMatter
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Wikilinks",
                    subtitle: "Link people and projects as [[Name]] in a Related block.",
                    isOn: $prefs.includeWikilinks
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Tags",
                    subtitle: "Append a #tag line for vault search.",
                    isOn: $prefs.includeTags
                )
            }
            .opacity(prefs.destination == .folder ? 1 : 0.5)
            .disabled(prefs.destination != .folder)
        }
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
