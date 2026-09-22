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
    /// When set, print ONE pipe-delimited Markdown table row (the whole-run
    /// summary) to stdout after the human table, ready to paste into BENCHMARKS.md.
    /// The row's numbers come from the same aggregation the table prints, so they
    /// cannot drift. No value — a bare `--markdown` flag.
    var markdown: Bool = false
    /// A file of newline-separated bias phrases. When set, the harness runs the
    /// **bias comparison** (gate zero): each clip is transcribed twice — bias off
    /// vs on — and the WER delta is reported, instead of the standard timing run.
    var biasFile: URL?
    /// A directory of `<stem>.hyp.txt` sidecars. When set, the harness scores
    /// those externally-produced transcripts against the corpus references
    /// (no model run, no timing) instead of transcribing the audio itself.
    var hypothesesDir: URL?
    /// A phrase file (same one-per-line format as `--bias`). When set, the harness
    /// appends a per-term recall table after any run (live OR hypotheses).
    var termsFile: URL?
    /// Milliseconds to drop from the HEAD of every clip before recognition (C3b).
    /// Simulates the warm-up window live dictation loses before its analyzer is
    /// ready, so the first-word-error-rate (FWER) column shows the first-phoneme
    /// cost the hotkey-down pre-roll (C3a) is meant to recover. 0 = no trim (the
    /// standard, unmodified corpus run).
    var leadTrimMs: Int = 0
    /// `speech` (default, SpeechTranscriber) or `dictation` (DictationTranscriber,
    /// the system-Dictation model the app offers under Settings → Speech model).
    var model: String = "speech"
    /// `--repair`: confidence-gated repair experiment (see RepairComparison).
    var repair: Bool = false
    var repairThreshold: Double = 0.75
    /// One term per line: the speaker's vocabulary, offered to the repair model.
    var vocabFile: URL?

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
      --bias <path>     Gate-zero bias comparison: a file of newline-separated
                        jargon phrases. Each clip is transcribed twice (bias off
                        vs on) and the WER delta is reported. Answers the only
                        question that gates the niche-vocabulary feature: does
                        on-device contextualStrings biasing actually move WER?
      --hypotheses <dir> Score EXTERNAL transcripts instead of transcribing here.
                        For each corpus item <stem>, reads <dir>/<stem>.hyp.txt
                        and scores it against the reference with the same WER
                        metric (no model run, no timing). Use it to score a
                        Whisper/cloud run, or a re-scored post-corrector output,
                        against the same corpus. Exits nonzero if none match.
      --terms <path>    A phrase file (one term per line, # comments — same format
                        as --bias). Appends a per-term recall table (reference
                        occurrences vs normalized hypothesis hits, recall %) after
                        any run — live transcription OR --hypotheses.
      --lead-trim-ms <n> Drop the first n milliseconds of every clip before
                        recognition (default: 0 = no trim). Simulates the warm-up
                        window live dictation loses before its analyzer is ready.
                        The results table then reports a first-word error rate
                        (FWER): the fraction of clips whose first reference word is
                        missing from the transcript head. Run it at 0 vs e.g. 350
                        on a leading-plosive corpus to measure the first-phoneme
                        loss the hotkey-down pre-roll is meant to recover.
      --model <name>    Recognizer: `speech` (default, the long-form
                        SpeechTranscriber) or `dictation` (DictationTranscriber,
                        the system-Dictation model). Run both on one corpus to
                        compare them.
      --repair          Confidence-gated repair experiment: transcribe with
                        per-word confidence, let the on-device model replace
                        ONLY words below --threshold, report raw vs repaired
                        WER and every individual change.
      --threshold <x>   Confidence cutoff for --repair (default 0.75).
      --vocab <path>    Terms (one per line) offered to the --repair model.
      --markdown        After the human table, print ONE pipe-delimited Markdown
                        row summarising the run (date, machine, macOS, locale,
                        corpus, WER, CER, RTFx, median/p90 latency) for pasting
                        into BENCHMARKS.md. Same numbers as the table.
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
            case "--bias":
                if let v = nextValue(arg) {
                    out.biasFile = URL(fileURLWithPath: v, relativeTo: cwd).standardizedFileURL
                }
            case "--hypotheses":
                if let v = nextValue(arg) {
                    out.hypothesesDir = URL(fileURLWithPath: v, relativeTo: cwd).standardizedFileURL
                }
            case "--terms":
                if let v = nextValue(arg) {
                    out.termsFile = URL(fileURLWithPath: v, relativeTo: cwd).standardizedFileURL
                }
            case "--lead-trim-ms":
                if let v = nextValue(arg), let n = Int(v), n >= 0 { out.leadTrimMs = n }
            case "--repair":
                out.repair = true
            case "--threshold":
                if let v = nextValue(arg), let x = Double(v), x > 0, x <= 1 { out.repairThreshold = x }
                else { out.showHelp = true }
            case "--vocab":
                if let v = nextValue(arg) { out.vocabFile = URL(fileURLWithPath: v) }
            case "--model":
                // An unknown model name shows usage rather than silently
                // benchmarking the wrong recognizer.
                if let v = nextValue(arg), v == "speech" || v == "dictation" { out.model = v }
                else { out.showHelp = true }
            case "--markdown":
                out.markdown = true
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
