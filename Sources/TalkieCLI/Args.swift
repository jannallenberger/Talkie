// Hand-rolled flag parser (zero dependencies, matching the app's + bench's "no
// ArgumentParser" posture — see Sources/TalkieBench/BenchArguments.swift). Parses
// the small verb + flag set the `talkie` CLI needs. Adding swift-argument-parser
// would trip the package's zero-dependency policy, so this stays hand-rolled.

import Foundation

/// Which subcommand the user invoked. `transcribe <file>` batch-transcribes an
/// audio file; `dictate` records the mic to stdout; `last` prints recent dictation
/// history. `none` covers a bare or unrecognized invocation (we print usage).
enum Verb {
    case transcribe
    case dictate
    case last
    case help
    case none
}

/// The output format for `transcribe`. Plain text (the default) goes to stdout as
/// one transcript; the timed formats render cues from the recognizer's segments.
enum OutputFormat: String {
    case text
    case md
    case srt
    case vtt
    case json
}

struct CLIArguments {
    var verb: Verb = .none
    var showHelp: Bool = false

    // transcribe
    var inputFile: URL?
    var format: OutputFormat = .text
    var locale: String = "en-US"

    // last
    var lastCount: Int = 1

    static let usage = """
    talkie — local, on-device speech tools (Apple SpeechAnalyzer, no network)

    USAGE:
      talkie transcribe <file> [--md | --srt | --vtt | --json] [--locale <id>]
      talkie dictate [--locale <id>]
      talkie last [-n <count>]

    COMMANDS:
      transcribe <file>   Transcribe an audio file (m4a, wav, caf, aiff, mp3,
                          flac — anything AVFoundation decodes) entirely on-device.
                          Default: plain transcript to stdout. Progress + errors
                          go to stderr, so `talkie transcribe x.m4a > out.txt` is
                          clean. MacWhisper-Pro-style batch transcription, free.
      dictate             Record from the mic until you press Enter, then print the
                          raw transcript to stdout. Voice as a shell primitive:
                            git commit -m "$(talkie dictate)"
                          Progress + errors go to stderr, so command substitution
                          captures only the words. Ctrl-C also finalizes (prints
                          whatever was captured). Raw recognizer output — no cleanup,
                          no styles, no history write; that all stays in the app.
                          NOTE: macOS attributes the microphone permission prompt to
                          your TERMINAL app (iTerm/Terminal/VS Code), not to `talkie`
                          — grant Microphone to the terminal in System Settings if
                          it's denied.
      last [-n <count>]   Print your most recent dictation(s) from Talkie's local
                          history (~/Library/Application Support/Talkie/history.json),
                          newest first — exactly the text the History tab shows.

    DICTATE OPTIONS:
      --locale <id>       BCP-47 locale for recognition (default: en-US). A fresh
                          locale may trigger a one-time on-device model download
                          (progress on stderr).

    TRANSCRIBE OPTIONS:
      --md                Markdown: a titled block per timed segment.
      --srt               SubRip subtitles with monotonic HH:MM:SS,mmm cue times.
      --vtt               WebVTT subtitles (HH:MM:SS.mmm cue times).
      --json              {"text": ..., "segments": [{start, end, text}, ...]}.
      --locale <id>       BCP-47 locale for recognition (default: en-US). A fresh
                          locale may trigger a one-time on-device model download
                          (progress on stderr).

    LAST OPTIONS:
      -n, --count <n>     How many recent dictations to print (default: 1).

    OTHER:
      -h, --help          Show this help.

    Everything runs on-device. No audio and no text ever leaves this Mac.
    """

    static func parse(_ argv: [String]) -> CLIArguments {
        var out = CLIArguments()
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // argv[0] is the executable path; argv[1] (if present) is the verb.
        guard argv.count >= 2 else { return out }

        var i = 1
        switch argv[1] {
        case "transcribe": out.verb = .transcribe; i = 2
        case "dictate": out.verb = .dictate; i = 2
        case "last": out.verb = .last; i = 2
        case "-h", "--help": out.verb = .help; out.showHelp = true; return out
        default:
            // No recognized verb — leave `.none`, which prints usage. (A bare
            // unknown token is almost always a typo'd command.)
            out.verb = .none
            return out
        }

        func nextValue(_ flag: String) -> String? {
            guard i + 1 < argv.count else {
                FileHandle.standardError.write(Data("warning: \(flag) needs a value; ignored.\n".utf8))
                return nil
            }
            i += 1
            return argv[i]
        }

        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "--md": out.format = .md
            case "--srt": out.format = .srt
            case "--vtt": out.format = .vtt
            case "--json": out.format = .json
            case "--text": out.format = .text
            case "--locale":
                if let v = nextValue(arg) { out.locale = v }
            case "-n", "--count":
                if let v = nextValue(arg), let n = Int(v), n >= 1 { out.lastCount = n }
            case "-h", "--help":
                out.showHelp = true
            default:
                if arg.hasPrefix("-") {
                    FileHandle.standardError.write(Data("warning: unknown option '\(arg)' ignored.\n".utf8))
                } else if out.verb == .transcribe && out.inputFile == nil {
                    // The first non-flag positional for `transcribe` is the file.
                    out.inputFile = URL(fileURLWithPath: arg, relativeTo: cwd).standardizedFileURL
                } else {
                    FileHandle.standardError.write(Data("warning: unexpected argument '\(arg)' ignored.\n".utf8))
                }
            }
            i += 1
        }
        return out
    }
}
