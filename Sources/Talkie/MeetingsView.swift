import AppKit
import SwiftUI

struct MeetingsView: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var store: MeetingStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meetings")
                        .font(.talkieDisplay(26))
                        .foregroundStyle(Theme.ink)
                    Text("Record a meeting; Talkie transcribes and summarizes it on-device, and saves a note you can point Claude at.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.inkSecondary)
                }

                recordCard
                if recorder.isRecording { notesCard }
                folderRow

                if store.meetings.isEmpty {
                    emptyState
                } else {
                    ForEach(store.meetings) { meeting in
                        MeetingRow(
                            meeting: meeting,
                            onReveal: { reveal(meeting) },
                            onCopy: { copy(meeting) },
                            onDelete: { store.delete(meeting) }
                        )
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Record card

    @ViewBuilder
    private var recordCard: some View {
        HStack(spacing: 16) {
            if recorder.isRecording {
                RecordingDot()
                VStack(alignment: .leading, spacing: 2) {
                    Text(recorder.capturingFarEnd ? "Recording you + the call…" : "Recording (mic only)…")
                        .font(.talkieHeading(15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(timeString(recorder.elapsed))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                Button("Stop & summarize") { Task { await recorder.stop() } }
                    .controlSize(.large)
            } else if recorder.isFinishing {
                ProgressView().controlSize(.small)
                Text("Transcribing & summarizing…")
                    .font(.talkieHeading(14, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                Spacer()
            } else {
                ClayIcon(name: "IconMic", size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record a meeting")
                        .font(.talkieHeading(15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Captures you and the other participants on the call (Zoom, Meet, Teams) — labeled Me / Them.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.inkTertiary)
                }
                Spacer()
                Button("Start recording") { Task { await recorder.start() } }
                    .controlSize(.large)
                    .disabled(!MeetingSummarizer.isAvailable && !TranscriptionEngine.isAvailable)
            }
        }
        .talkieCard()
        .frame(maxWidth: .infinity)
    }

    // Live notes during a recording — fused with the transcript on stop (the
    // "Granola magic"). Jot sparse points; Talkie expands them from what was said.
    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkTertiary)
                Text("Your notes")
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text("Fused with the transcript when you stop")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
            }
            TextEditor(text: $recorder.notes)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 88, maxHeight: 170)
                .padding(8)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if recorder.notes.isEmpty {
                        Text("Jot key points — Talkie expands them with the transcript…")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.inkTertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
        }
        .talkieCard()
        .frame(maxWidth: .infinity)
    }

    private var folderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkTertiary)
            Text("Saved to ~/Talkie Meetings/ as markdown")
                .font(.talkieEyebrow)
                .foregroundStyle(Theme.inkTertiary)
            Spacer()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.folderURL])
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 28))
                .foregroundStyle(Theme.inkTertiary)
            Text("No meetings yet")
                .font(.talkieHeading(15, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            Text("Hit Start recording before your next call.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func reveal(_ meeting: Meeting) {
        let url = store.folderURL.appendingPathComponent(meeting.fileName)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copy(_ meeting: Meeting) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(meeting.transcript, forType: .string)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

private struct RecordingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 12, height: 12)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let onReveal: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var expanded = false
    @State private var hovering = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.dateFormatter.string(from: meeting.date))
                        .font(.talkieHeading(14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("\(Int((meeting.durationSec / 60).rounded())) min · \(WordCounter.count(meeting.transcript)) words")
                        .font(.talkieEyebrow)
                        .foregroundStyle(Theme.inkTertiary)
                }
                Spacer()
                if hovering {
                    Button(action: onCopy) { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy transcript")
                    Button(action: onReveal) { Image(systemName: "folder") }.buttonStyle(.plain).help("Reveal note in Finder")
                }
            }

            if !meeting.summary.isEmpty {
                MarkdownText(markdown: meeting.summary, bulletColor: Theme.coral)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
            }

            DisclosureGroup(isExpanded: $expanded) {
                Text(meeting.transcript)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.inkSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } label: {
                Text(expanded ? "Hide transcript" : "Show transcript")
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.coral)
            }
        }
        .talkieCard(padding: 14)
        .onHover { hovering = $0 }
    }
}
