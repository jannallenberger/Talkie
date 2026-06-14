import SwiftUI
import AppKit

/// Settings pane for the vibe-coding feature: enable it, and point Talkie at a
/// project folder so spoken filenames snap to the real files.
struct VibeCodingView: View {
    @ObservedObject var projectIndex: ProjectIndexStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Vibe Coding",
                           subtitle: "Say a filename, get the real file — “exercise library dot t-s-x” becomes ExerciseLibrary.tsx.")

                // Enable toggle.
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $settings.vibeCoding) {
                        Text("Snap spoken filenames to my project files")
                            .font(.talkieHeading(14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.coral)
                    Text("When on, Talkie matches what you dictate against the files below and inserts the exact, correctly-cased name. It also biases recognition toward your project's vocabulary.")
                        .font(.callout)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .talkieCard()

                // Project folders.
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Eyebrow(text: "Project folders")
                        Spacer()
                        if projectIndex.isScanning { ProgressView().controlSize(.small) }
                    }

                    if projectIndex.hasFolders {
                        // The chosen roots, in a sunken well for a touch of depth.
                        VStack(spacing: 0) {
                            ForEach(Array(projectIndex.folders.enumerated()), id: \.element.id) { idx, folder in
                                if idx > 0 {
                                    Divider().overlay(Theme.hairline).padding(.leading, 48)
                                }
                                FolderRow(folder: folder) { projectIndex.removeFolder(folder.path) }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(Theme.surfaceSunken)
                        )

                        HStack(spacing: 10) {
                            Button(action: chooseFolders) {
                                Label("Add folder…", systemImage: "folder.badge.plus")
                            }
                            Button {
                                Task { await projectIndex.rescan() }
                            } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                                .disabled(projectIndex.isScanning)
                            Spacer()
                            Text(statusLine)
                                .font(.talkieHeading(12, weight: .regular))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    } else {
                        Button(action: chooseFolders) {
                            VStack(spacing: 10) {
                                ClayIcon(name: "IconFolderPlus", size: 42)
                                Text("Choose project folders…")
                                    .font(.talkieHeading(14, weight: .semibold))
                                    .foregroundStyle(Theme.coral)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 26)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                                    .foregroundStyle(Theme.coral.opacity(0.5))
                            )
                        }
                        .buttonStyle(.plain)
                        Text("Add one or more project roots — Talkie indexes them all. Everything stays on your Mac; it only reads filenames, never file contents.")
                            .font(.callout)
                            .foregroundStyle(Theme.inkTertiary)
                    }
                }
                .talkieCard()

                // How it sounds.
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "How it sounds")
                    ExampleRow(spoken: "“exercise library dot tsx”", result: "ExerciseLibrary.tsx")
                    ExampleRow(spoken: "“use auth hook dot ts”", result: "useAuthHook.ts")
                    ExampleRow(spoken: "“app delegate dot swift”", result: "AppDelegate.swift")
                }
                .talkieCard()
            }
            .padding(28)
        }
    }

    private var statusLine: String {
        let folders = projectIndex.folders.count
        var parts: [String] = ["\(projectIndex.fileCount) files"]
        if folders > 1 { parts[0] += " · \(folders) folders" }
        if let scanned = projectIndex.lastScanned {
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .full
            parts.append("scanned \(fmt.localizedString(for: scanned, relativeTo: Date()))")
        }
        return parts.joined(separator: " · ")
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Pick one or more project roots you're vibe coding in."
        if panel.runModal() == .OK {
            projectIndex.addFolders(panel.urls)
        }
    }
}

/// One chosen project root inside the folders well: folder glyph, name, the
/// abbreviated parent path, and a remove button that reddens on hover.
private struct FolderRow: View {
    let folder: ProjectFolder
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ClayIcon(name: "IconFolder", size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.talkieHeading(14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(folder.location)
                    .font(.talkieHeading(11.5, weight: .regular))
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(hovering ? Theme.danger : Theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove this folder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct ExampleRow: View {
    let spoken: String
    let result: String
    var body: some View {
        HStack(spacing: 10) {
            ClayIcon(name: "IconWaveform", size: 18)
            Text(spoken)
                .font(.talkieHeading(13, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.inkTertiary)
            Text(result)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.coral)
            Spacer()
        }
    }
}
