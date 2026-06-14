// Hand-rolled flag parser (zero dependencies, matching the app's "no
// ArgumentParser" posture). Parses the small set of flags the harness needs.

import Foundation

struct BenchArguments {
    var corpus: URL?
    var locale: String = "en-US"
    var warmup: Int = 3
    var limit: Int = 0          // 0 = no cap
    var jsonOutput: URL?
    var quiet: Bool = false
    var showHelp: Bool = false
    var selfTest: Bool = false

    static let usage = """
    talkie-bench — on-device speech-recognition benchmark (Apple SpeechAnalyzer)

    USAGE:
      talkie-bench --corpus <dir> [options]

    OPTIONS:
      --corpus <dir>    Folder scanned recursively for audio files + their
                        reference transcripts (LibriSpeech `*.trans.txt` index,
                        or a `<audiostem>.txt` sidecar). REQUIRED.
      --locale <id>     BCP-47 locale for recognition (default: en-US).
      --warmup <n>      Discard the first n files' timings to warm the model
                        (default: 3). Use 0 to include first-load cost.
      --limit <n>       Cap the number of files processed (default: 0 = all).
      --json <path>     Also write raw per-file results as JSON for re-scoring.
      --quiet           Print only the final summary table.
      --selftest        Run the built-in WER-scorer correctness checks and exit
                        (no corpus, model, or Python needed).
      -h, --help        Show this help.

    Reports WER, CER, RTFx (audio_seconds / wall_seconds), and median/p90
    per-file latency. Measures raw recognition only (no cleanup, no biasing).
    Default corpus: LibriSpeech test-clean (CC BY 4.0). See the top of main.swift.
    """

    static func parse(_ argv: [String]) -> BenchArguments {
        var out = BenchArguments()
        var i = 1 // argv[0] is the executable path
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

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
            case "--corpus":
                if let v = nextValue(arg) {
                    out.corpus = URL(fileURLWithPath: v, relativeTo: cwd).standardizedFileURL
                }
            case "--locale":
                if let v = nextValue(arg) { out.locale = v }
            case "--warmup":
                if let v = nextValue(arg), let n = Int(v), n >= 0 { out.warmup = n }
            case "--limit":
                if let v = nextValue(arg), let n = Int(v), n >= 0 { out.limit = n }
            case "--json":
                if let v = nextValue(arg) {
                    out.jsonOutput = URL(fileURLWithPath: v, relativeTo: cwd).standardizedFileURL
                }
            case "--quiet":
                out.quiet = true
            case "--selftest":
                out.selfTest = true
            case "-h", "--help":
                out.showHelp = true
            default:
                FileHandle.standardError.write(Data("warning: unknown argument '\(arg)' ignored.\n".utf8))
            }
            i += 1
        }
        return out
    }
}
