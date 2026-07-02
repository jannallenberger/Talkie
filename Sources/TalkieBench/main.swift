// =============================================================================
// TalkieBench — a reproducible, on-device speech-recognition benchmark
// =============================================================================
//
// WHAT THIS IS
// ------------
// A self-contained command-line harness that runs a folder of audio files plus
// their reference transcripts through Apple's on-device `SpeechAnalyzer` /
// `SpeechTranscriber` pipeline (macOS 26+, Apple Silicon) and reports, on the
// machine you run it on:
//
//   • WER  — Word Error Rate, a Levenshtein edit distance over words
//            (lower is better; 0.0 = a perfect transcript)
//   • CER  — Character Error Rate, the same metric over characters
//   • RTFx — Real-Time Factor, audio_seconds / wall_seconds
//            (higher is better; 10× means it transcribed 10 s of audio per
//            wall-clock second)
//   • median / p90 per-file latency, and total corpus wall-time
//
// It exists so Talkie's performance claims are numbers *we generated, on our
// hardware, with our actual pipeline* — measured, not borrowed. The harness
// deliberately measures **raw recognition only**: no cleanup, no dictionary
// biasing, no vibe-coding. That keeps the WER a clean measure of the model's
// quality rather than Talkie's vocabulary advantage.
//
// It is a SEPARATE executable target (`talkie-bench`). It does NOT import the
// Talkie app target — the SpeechAnalyzer usage here is a faithful, standalone
// copy of the pattern in `Sources/Talkie/TranscriptionEngine.swift`, so the
// benchmark and the app cannot drift apart silently, yet the harness builds and
// runs on its own. It is 100% on-device: no network, no third-party deps.
//
// PRIVACY
// -------
// Transcription is entirely on-device. The harness opens NO network connection.
// The one-time `SpeechTranscriber` model download (an Apple on-device asset,
// same one the app uses) is handled by macOS's `AssetInventory`, not by this
// tool. Nothing about you, and nothing you transcribe, leaves the machine.
//
// -----------------------------------------------------------------------------
// DATASET & LICENSING
// -----------------------------------------------------------------------------
// The documented default corpus is **LibriSpeech `test-clean`**: ~5.4 h of clean
// read English speech, 2,620 utterances, 40 speakers, 16 kHz FLAC. It ships with
// per-chapter transcript files (`<chapter>.trans.txt`, one `<utt-id> TEXT` per
// line). LibriSpeech is licensed **CC BY 4.0** — you must attribute it:
//
//     LibriSpeech (Panayotov, Chen, Povey, Khudanpur, 2015), OpenSLR-12,
//     https://www.openslr.org/12 — licensed CC BY 4.0.
//
// The harness is corpus-agnostic: any folder of audio files (FLAC / WAV / CAF /
// AIFF / m4a — anything AVAudioFile decodes) with matching reference text works.
// See "REFERENCE TRANSCRIPT FORMATS" below.
//
// A Whisper Large V3 baseline can be run *separately* (e.g. whisper.cpp with the
// Core ML ANE encoder, or WhisperKit) on the SAME files; point this harness at
// that tool's output to compare. Note for honesty: the often-quoted "~55% faster
// than Whisper" figure came from a wall-clock test of Whisper Large V3 **Turbo**
// (a distilled, faster model) on a single file with no accuracy measured — so a
// fair full-Large-V3 comparison may show a smaller speed margin and competitive
// (not necessarily superior) accuracy. Label the baseline as what it actually is.
//
// -----------------------------------------------------------------------------
// HOW TO RUN
// -----------------------------------------------------------------------------
// 1) Build (the orchestrator wires the `talkie-bench` target into Package.swift):
//
//        swift build -c release
//
// 2) Get a corpus. For LibriSpeech test-clean:
//
//        curl -LO https://www.openslr.org/resources/12/test-clean.tar.gz
//        tar xzf test-clean.tar.gz          # → LibriSpeech/test-clean/...
//
// 3) Run the benchmark over that folder:
//
//        .build/release/talkie-bench \
//            --corpus ./LibriSpeech/test-clean \
//            --locale en-US \
//            --warmup 3 \
//            --limit 0            # 0 = all files; set e.g. 50 for a quick pass
//
//    Useful flags:
//        --corpus  <dir>     folder to scan recursively for audio + references
//        --locale  <id>      BCP-47 locale, default en-US
//        --warmup  <n>       discard the first n files' timings (model warm-up)
//        --limit   <n>       cap the number of files (0 = no cap)
//        --json    <path>    also write per-file raw results as JSON
//        --quiet             only print the final summary table
//
// METHODOLOGY (kept honest)
// -------------------------
//   • Warm, not cold: a warm-up pass triggers model load / ANE compile so the
//     measured timings reflect steady-state recognition. (Use --warmup 0 to
//     include first-load cost, which is reported but never blended in silently.)
//   • Timed window = only the recognize call (decode + analyze + finalize),
//     not file discovery, not WER scoring.
//   • Same audio bytes, one resample to the analyzer's required format.
//   • test-clean is clean read speech — its WER is a floor, not your live
//     dictation accuracy. We never claim test-clean WER == real-world WER.
//
// REFERENCE TRANSCRIPT FORMATS (auto-detected per file)
// -----------------------------------------------------
//   1. LibriSpeech: a `<chapter>.trans.txt` in the same folder with a line
//      `<utt-id> THE REFERENCE TEXT` whose id matches the audio file stem.
//   2. Sidecar: a `<audiostem>.txt` (or `.ref`/`.lab`) next to the audio file.
//      The whole file is the reference for that one clip.
//
// =============================================================================

import Foundation

// MARK: - Entry point

let args = BenchArguments.parse(CommandLine.arguments)

if args.showHelp {
    print(BenchArguments.usage)
    exit(0)
}

if args.selfTest {
    print("talkie-bench — WER scorer self-test\n")
    exit(SelfTest.run() ? 0 : 1)
}

guard let corpus = args.corpus else {
    FileHandle.standardError.write(Data("error: --corpus <dir> is required.\n\n".utf8))
    print(BenchArguments.usage)
    exit(2)
}

// Discover audio files + their reference transcripts.
let items: [CorpusItem]
do {
    items = try CorpusLoader.load(corpusDirectory: corpus, limit: args.limit)
} catch {
    FileHandle.standardError.write(Data("error: could not read corpus: \(error.localizedDescription)\n".utf8))
    exit(1)
}

guard !items.isEmpty else {
    FileHandle.standardError.write(Data("""
        error: found no audio files with matching reference transcripts under
               \(corpus.path)

        Expected either a LibriSpeech-style `*.trans.txt` index, or a sidecar
        `<audiostem>.txt` next to each audio file. See the top-of-file comment.
        \n
        """.utf8))
    exit(1)
}

// Gate-zero bias comparison: transcribe each clip twice (bias off vs on) and
// report the WER delta, then exit. Settles whether on-device contextualStrings
// biasing actually works before any of the niche-vocabulary feature is wired in.
if let biasURL = args.biasFile {
    let phrases = BiasComparison.loadPhrases(biasURL)
    guard !phrases.isEmpty else {
        FileHandle.standardError.write(Data("error: bias file \(biasURL.path) had no usable phrases (one per line, # for comments).\n".utf8))
        exit(2)
    }
    if !args.quiet {
        print(Banner.header(corpus: corpus, locale: args.locale, items: items.count, warmup: 0))
        print("Bias comparison mode: \(phrases.count) phrases, each clip transcribed twice.\n")
    }
    let comparison = await BiasComparison.run(items: items,
                                              localeIdentifier: args.locale,
                                              phrases: phrases,
                                              quiet: args.quiet)
    print(BiasComparison.render(comparison))
    exit(comparison.rows.isEmpty ? 1 : 0)
}

// --terms: a phrase file whose per-term recall is appended after any run. Loaded
// once here (reuses the --bias loader's format: one phrase per line, # comments).
// An empty/malformed file is a hard error — a --terms flag that scores nothing is
// almost certainly a mistake the user wants to know about.
let terms: [String]
if let termsURL = args.termsFile {
    terms = BiasComparison.loadPhrases(termsURL)
    guard !terms.isEmpty else {
        FileHandle.standardError.write(Data("error: terms file \(termsURL.path) had no usable phrases (one per line, # for comments).\n".utf8))
        exit(2)
    }
} else {
    terms = []
}

// Hypotheses mode: score externally-produced `<stem>.hyp.txt` transcripts against
// the corpus references — no model run, no timing. Optionally append --terms recall
// over those same hypotheses, then exit.
if let hypDir = args.hypothesesDir {
    if !args.quiet {
        print(Banner.header(corpus: corpus, locale: args.locale, items: items.count, warmup: 0))
        print("Hypotheses mode: scoring <stem>.hyp.txt sidecars in \(hypDir.path)\n")
    }
    let hyp = HypothesisScoring.run(items: items, hypothesesDirectory: hypDir)
    print(HypothesisScoring.render(hyp, corpus: corpus, locale: args.locale))

    if !terms.isEmpty {
        let pairs = hyp.scored.map { TermRecallPair(reference: $0.reference, hypothesis: $0.hypothesis) }
        print(TermRecall.render(TermRecall.score(terms: terms, pairs: pairs)))
    }

    // Nonzero if zero corpus items had a matching hypothesis (nothing scored).
    exit(hyp.scored.isEmpty ? 1 : 0)
}

if !args.quiet {
    print(Banner.header(corpus: corpus, locale: args.locale, items: items.count,
                        warmup: args.warmup))
}

// Run the benchmark. This is the only async hop — everything else is sync.
let outcome = await BenchRunner.run(items: items,
                                    localeIdentifier: args.locale,
                                    warmupCount: args.warmup,
                                    quiet: args.quiet)

// Print the results table + the honesty footer.
print(ResultsTable.render(outcome, corpus: corpus, locale: args.locale))

// Per-term recall over the live transcripts, if --terms was supplied. Scored on
// the same measured rows the WER above used, so the two numbers can't disagree.
if !terms.isEmpty {
    let pairs = outcome.measured.map { TermRecallPair(reference: $0.reference, hypothesis: $0.hypothesis) }
    print(TermRecall.render(TermRecall.score(terms: terms, pairs: pairs)))
}

// Optionally emit raw per-file JSON for independent re-scoring.
if let jsonPath = args.jsonOutput {
    do {
        try outcome.writeRawJSON(to: jsonPath)
        if !args.quiet { print("\nRaw per-file results written to \(jsonPath.path)") }
    } catch {
        FileHandle.standardError.write(Data("warning: could not write JSON: \(error.localizedDescription)\n".utf8))
    }
}

exit(outcome.measured.isEmpty ? 1 : 0)
