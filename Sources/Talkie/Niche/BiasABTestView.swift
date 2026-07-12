import SwiftUI
@preconcurrency import AVFoundation
import Speech

/// In-app **jargon auto-correct test** — the no-files way to see the niche feature
/// work. Type your jargon (the correct spellings), hit Record, say a sentence that
/// uses them, hit Stop. Talkie transcribes normally, then proofreads the result and
/// swaps your jargon back in wherever the recognizer produced a close-sounding
/// mistake — and shows you the raw transcript vs the corrected one.
///
/// NOTE: an earlier version A/B-tested recognizer biasing; that proved a no-op on
/// this stack (see `NicheCorrector` / the feature memo), so this panel now
/// demonstrates the post-hoc correction we pivoted to. Self-contained: its own
/// `BiasABProbe` + a reused `AudioCapture`; touches neither the live pipeline nor
/// the niche store. Lives in the Developer tab.
@MainActor
struct BiasABTestView: View {
    @State private var localeID = "en-US"
    @State private var words = "Kubernetes\nidempotent\nGitHub"
    @State private var phase: Phase = .idle
    @State private var rawText = ""
    @State private var correctedText = ""
    @State private var fixes: [NicheFix] = []

    @State private var capture: AudioCapture?
    @State private var probe: BiasABProbe?
    @State private var sink: AsyncStream<AnalyzerInput>.Continuation?

    enum Phase: Equatable { case idle, preparing, recording, transcribing, done, error(String) }

    private var phrases: [String] {
        words.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var isBusy: Bool {
        phase == .preparing || phase == .recording || phase == .transcribing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jargon auto-correct test")
                .font(.headline)
            Text("Type your jargon (the correct spellings), press Record, say a sentence that uses them, then Stop. Talkie transcribes normally, then fixes your jargon wherever it came out close-but-wrong. Nothing leaves your Mac.")
                .font(.subheadline)
                .foregroundStyle(Theme.inkSecondary)

            HStack(spacing: 8) {
                Text("Language").font(.subheadline)
                TextField("en-US", text: $localeID)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isBusy)
                Text("e.g. en-US, de-DE").font(.caption).foregroundStyle(Theme.inkTertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Your jargon words (one per line)").font(.subheadline)
                TextEditor(text: $words)
                    .font(.body.monospaced())
                    .frame(height: 88)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                    .disabled(isBusy)
            }

            controls

            if case .error(let message) = phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }

            if phase == .done {
                results
            }
        }
        .padding(18)
        .talkieSurface()
    }

    @ViewBuilder private var controls: some View {
        switch phase {
        case .recording:
            Button { Task { await stop() } } label: {
                Label("Stop & correct", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

        case .preparing, .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(phase == .preparing ? "Warming up the model…" : "Transcribing & correcting…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
            }

        default:
            Button { Task { await record() } } label: {
                Label("Record", systemImage: "mic.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.coral)
            .disabled(phrases.isEmpty)
        }
    }

    @ViewBuilder private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Theme.hairline)
            resultPane(title: "Raw transcript", text: rawText, accent: Theme.inkSecondary)
            resultPane(title: "After auto-correct", text: correctedText, accent: Theme.coral)

            if fixes.isEmpty {
                Label("No fixes applied. Try words the model garbles, or they may have come out right already.",
                      systemImage: "equal.circle")
                .font(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Auto-correct fixed \(fixes.count) \(fixes.count == 1 ? "word" : "words"):",
                          systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.coral)
                    ForEach(Array(fixes.enumerated()), id: \.offset) { _, fix in
                        Text("“\(fix.from)”  →  “\(fix.to)”")
                            .font(.callout.monospaced())
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
        }
    }

    private func resultPane(title: String, text: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
            Text(text.isEmpty ? "— (nothing recognized)" : text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Actions

    private func record() async {
        phase = .preparing
        rawText = ""; correctedText = ""; fixes = []

        guard await AudioCapture.requestMicrophoneAccess() else {
            phase = .error("Microphone access denied. Grant it in System Settings ▸ Privacy ▸ Microphone.")
            return
        }
        guard BiasABProbe.isAvailable else {
            phase = .error("On-device speech recognition isn't available on this Mac.")
            return
        }

        let p = BiasABProbe(localeIdentifier: localeID.isEmpty ? "en-US" : localeID)
        do {
            try await p.prepare()
            let format = try await p.preferredAudioFormat()
            let cap = AudioCapture()
            // The live stream is unused — we only want AudioCapture's buffered audio
            // (it appends to its internal buffer independently of this stream).
            let (_, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(1))
            try cap.start(targetFormat: format, continuation: continuation,
                          bufferAudio: true, bufferSeconds: 180)
            self.probe = p
            self.capture = cap
            self.sink = continuation
            phase = .recording
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func stop() async {
        guard let cap = capture, let p = probe else { phase = .idle; return }
        cap.stop()
        sink?.finish()
        sink = nil
        let buffers = cap.bufferedAudio()
        self.capture = nil
        guard !buffers.isEmpty else {
            self.probe = nil
            phase = .error("No audio was captured — try again and speak after pressing Record.")
            return
        }
        phase = .transcribing
        let raw = await p.transcribe(buffers: buffers)
        self.probe = nil
        let correction = NicheCorrector.correct(raw, terms: phrases)
        rawText = raw
        correctedText = correction.text
        fixes = correction.fixes
        phase = .done
    }
}
