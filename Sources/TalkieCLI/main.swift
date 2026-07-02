// =============================================================================
// talkie — the local, on-device speech CLI (work package G4)
// =============================================================================
//
// Two verbs, both 100% on-device (Apple SpeechAnalyzer / SpeechTranscriber,
// macOS 26+, Apple Silicon), no network, no third-party dependencies:
//
//   talkie transcribe <file> [--md|--srt|--vtt|--json] [--locale <id>]
//       MacWhisper-Pro-style batch file transcription, free. Decodes + resamples
//       the audio (TalkieFileKit.AudioFileLoader), runs it through the SAME
//       recognition path the app uses (TalkieFileKit.FileTranscriber — a faithful
//       standalone mirror, no import of the app target), and prints a transcript.
//       Plain text is the default; --srt/--vtt/--json/--md render timed cues from
//       the recognizer's own segment ranges. The transcript goes to STDOUT and
//       progress/errors to STDERR, so `talkie transcribe x.m4a > out.txt` is clean.
//
//   talkie last [-n <count>]
//       Prints your most recent dictation(s) from Talkie's local history
//       (~/Library/Application Support/Talkie/history.json), newest first —
//       exactly the text the History tab shows. Exits 1 with a friendly message
//       when the history file is absent.
//
// The executable TARGET is named `talkie-cli` (the app binary is `Talkie` and
// APFS is case-insensitive); build_app.sh installs it as Contents/MacOS/talkie.
//
// PRIVACY: nothing about you, and nothing you transcribe or have dictated, leaves
// this Mac. The one-time SpeechTranscriber model download is Apple's on-device
// asset install (AssetInventory), the same one the app uses.

import Foundation
import TalkieFileKit

// MARK: - stderr helper (progress + errors never pollute stdout)

func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Entry

let args = CLIArguments.parse(CommandLine.arguments)

if args.showHelp {
    print(CLIArguments.usage)
    exit(0)
}

switch args.verb {
case .help:
    print(CLIArguments.usage)
    exit(0)

case .none:
    warn("error: no command given.\n")
    print(CLIArguments.usage)
    exit(2)

case .last:
    runLast(count: args.lastCount)

case .transcribe:
    await runTranscribe(args)
}

// MARK: - `talkie last`

/// Print the newest `count` dictations, newest first, as the History tab shows
/// them (the raw `text`). Friendly, distinct exits for the three "nothing to
/// show" cases: file absent (exit 1), file unreadable/corrupt (exit 1), and file
/// present but empty (exit 0 — that's a valid, if unhelpful, state).
func runLast(count: Int) {
    guard HistoryReader.historyExists() else {
        warn("""
        No dictation history yet.
          Expected \(HistoryReader.historyURL().path)
          Talkie writes it after your first dictation — start Talkie and dictate something, then try again.
        """)
        exit(1)
    }

    guard let entries = HistoryReader.load() else {
        warn("error: could not read \(HistoryReader.historyURL().path) (unreadable or corrupt).")
        exit(1)
    }

    guard !entries.isEmpty else {
        warn("Your dictation history is empty.")
        exit(0)
    }

    // Newest first; blank line between multiple entries so they're distinguishable.
    let slice = entries.prefix(max(1, count))
    let block = slice.map(\.text).joined(separator: "\n\n")
    print(block)
    exit(0)
}

// MARK: - `talkie transcribe <file>`

func runTranscribe(_ args: CLIArguments) async {
    guard let input = args.inputFile else {
        warn("error: `talkie transcribe` needs an audio file path.\n")
        print(CLIArguments.usage)
        exit(2)
    }

    guard FileManager.default.fileExists(atPath: input.path) else {
        warn("error: no such file: \(input.path)")
        exit(1)
    }

    guard FileTranscriber.isAvailable else {
        warn("error: on-device speech recognition (SpeechTranscriber) is not available on this Mac.")
        exit(1)
    }

    let engine = FileTranscriber(localeIdentifier: args.locale)

    // Resolve locale + install/reserve the model. A fresh locale may trigger a
    // one-time on-device asset download; surface that on stderr so a long first
    // run isn't mistaken for a hang. (Per spec: model download progress on stderr.)
    warn("Preparing on-device model for \(args.locale) (first run may download it)…")
    do {
        try await engine.prepare()
    } catch {
        warn("error: \(error.localizedDescription)")
        exit(1)
    }

    // Decode + resample to the analyzer's format (not timed here — this is a CLI,
    // not the benchmark), then recognize. Collect timed segments so any timed
    // format can render cues; the plain/text path just uses the joined transcript.
    do {
        let format = try await engine.preferredAudioFormat()
        let loaded = try AudioFileLoader.buffers(from: input, target: format)
        guard !loaded.buffers.isEmpty else {
            warn("error: decoded no audio from \(input.lastPathComponent) — is it a valid audio file?")
            exit(1)
        }
        warn("Transcribing \(input.lastPathComponent) (\(String(format: "%.1f", loaded.durationSeconds))s of audio)…")

        let result = try await engine.transcribeTimed(buffers: loaded.buffers)
        emit(transcript: result.text, segments: result.segments, format: args.format)
        exit(result.text.isEmpty && result.segments.isEmpty ? 1 : 0)
    } catch {
        warn("error: \(error.localizedDescription)")
        exit(1)
    }
}

/// Print the requested format to stdout.
func emit(transcript: String, segments: [TimedSegment], format: OutputFormat) {
    switch format {
    case .text:
        print(OutputFormats.plainText(transcript: transcript, segments: segments))
    case .md:
        print(OutputFormats.markdown(transcript: transcript, segments: segments))
    case .srt:
        print(OutputFormats.srt(segments: segments), terminator: "")
    case .vtt:
        print(OutputFormats.vtt(segments: segments), terminator: "")
    case .json:
        print(OutputFormats.json(transcript: transcript, segments: segments))
    }
}
