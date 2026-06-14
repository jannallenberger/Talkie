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

                // Project folder.
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow(text: "Project folder")

                    if let folder = projectIndex.folderName {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Theme.coral)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder)
                                    .font(.talkieHeading(15, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                                Text(statusLine)
                                    .font(.talkieHeading(12, weight: .regular))
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                            Spacer()
                            if projectIndex.isScanning {
                                ProgressView().controlSize(.small)
                            }
                        }
                        HStack(spacing: 10) {
                            Button {
                                Task { await projectIndex.rescan() }
                            } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                                .disabled(projectIndex.isScanning)
                            Button("Change…", action: chooseFolder)
                            Spacer()
                            Button(role: .destructive) { projectIndex.clear() } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    } else {
                        Button(action: chooseFolder) {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Choose project folder…")
                                    .font(.talkieHeading(14, weight: .semibold))
                            }
                            .foregroundStyle(Theme.coral)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 22)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                                    .foregroundStyle(Theme.coral.opacity(0.5))
                            )
                        }
                        .buttonStyle(.plain)
                        Text("Everything stays on your Mac — Talkie only reads filenames, never file contents.")
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
        var parts: [String] = ["\(projectIndex.fileCount) files indexed"]
        if let scanned = projectIndex.lastScanned {
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .full
            parts.append("scanned \(fmt.localizedString(for: scanned, relativeTo: Date()))")
        }
        return parts.joined(separator: " · ")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Pick the root of the project you're vibe coding in."
        if panel.runModal() == .OK, let url = panel.url {
            projectIndex.setFolder(url)
        }
    }
}

private struct ExampleRow: View {
    let spoken: String
    let result: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
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
