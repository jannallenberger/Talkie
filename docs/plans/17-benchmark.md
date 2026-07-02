# 17 — Reproducible benchmark harness

> Plan owner: feature 17. Built against `_CURRENT_STATE.md` (HEAD ground truth) and
> `_UNIFICATION.md` §2.1 (`TranscriptionBackend`) + §6 contract for 17.
> Floor: macOS 26.0, Apple Silicon, Swift 6 `.v6`. Researched June 2026.

## 1. Summary

A reproducible, documented harness — a separate SwiftPM executable target plus a thin
Python scorer — that runs a licensed speech corpus (LibriSpeech `test-clean`) through
**Talkie's own `SpeechAnalyzer`/`SpeechTranscriber` pipeline** and a **Whisper Large V3
baseline** on the *same* Apple Silicon machine, measuring **WER** (accuracy) and
**RTFx / median latency** (speed), and emitting a results JSON + an on-brand SwiftUI
chart. It exists to make the README's "~55% faster than Whisper Large V3" claim
*honest, qualified, and re-runnable* rather than an inherited marketing line.

## 2. Why it matters

The README (`/Users/jann/Talkie/README.md:9`) asserts Talkie is "**~55% faster than
Whisper Large V3**." **That number is currently unverifiable from anything in this
repo and is, on investigation, imprecise** — it traces to a June 2025 MacStories/MacRumors
hands-on where the CLI tool *Yap* transcribed one 34-minute 7 GB video in 0:45 vs
MacWhisper's **Large V3 _Turbo_** at 1:41 (≈2.2× / "55% faster") — a *wall-clock speed*
test on a *single file*, against the *distilled Turbo* variant (not standard Large V3),
with **no WER / accuracy measured at all** ([MacStories](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/),
[MacRumors](https://www.macrumors.com/2025/06/18/apple-transcription-api-faster-than-whisper/)).
Shipping an open-source app whose headline benchmark is borrowed, mis-attributed (Turbo
≠ Large V3), and untested is exactly the kind of "invented metric" `BRAND.md §9` and the
honesty invariant forbid. This feature replaces the borrowed line with a number *we
generated, on our hardware, with our pipeline*, and tells the reader precisely what was
and wasn't measured.

Strategically it serves the thesis three ways: (a) **provable, not asserted** — the same
posture as "provably private," now applied to performance, which a cloud incumbent
(Wispr Flow, Granola) cannot match because they can't run on your machine and show you
the numbers; (b) it is the **regression harness for feature 20** (the pluggable
`TranscriptionBackend`) — every new backend (whisper.cpp, Parakeet-CoreML) is validated
by re-running this; (c) it doubles as the credibility artifact for launch ("here's the
script, run it yourself"). The honest framing — *Apple's model wins on speed/latency and
is competitive, not necessarily superior, on accuracy* — is more defensible and more
on-brand than the inflated claim.

## 3. Current state in the code

**Nothing benchmark-related exists today.** Confirmed: no test target, no `Tests/`,
no benchmark script, no second executable target (`Package.swift:9-17` — one
`executableTarget`; `_CURRENT_STATE.md §8` "No tests in the repo").

What *exists* that this harness must reuse or generalize:

- **`TranscriptionEngine.swift`** (`actor`, `Sources/Talkie/TranscriptionEngine.swift`)
  — the system under test. Critical fact for the harness: it is **live/streaming-only**
  today. `beginSession` (`:196-259`) returns an `AsyncStream<AnalyzerInput>.Continuation`
  the caller feeds buffers into; there is **no file-input path**. The one file-shaped
  method, `transcribeBuffered(_:localeIdentifier:)` (`:141-190`), takes `[AVAudioPCMBuffer]`
  (not a URL), **bails rather than downloading a model inline** (`:148-149`), and requires
  the buffer format to exactly match `SpeechAnalyzer.bestAvailableAudioFormat`
  (`:152-156`). So the harness needs a *file → `[AVAudioPCMBuffer]` (converted to the
  analyzer's format)* loader — which is what `AudioCapture.swift` does for the mic
  (`AVAudioConverter` to the analyzer format, `:95`), reusable as pure conversion code.
- `makeTranscriber` (`:113-120`) requests `.volatileResults` but **no `.audioTimeRange`**
  (`attributeOptions: []`) — fine for WER (we only need final text), relevant only if we
  ever want per-segment latency.
- **`AppPaths.swift`** (`:7-13`) — `supportDirectory()` is the model for where results
  land; the harness adds nothing to the app's runtime paths (it writes under the repo).
- **`DesignSystem.swift`** — `Theme.featherBlue`/`featherCoral`/`featherGold`, `talkieCard`,
  `Eyebrow`, `talkieMetric`, `Theme.heat` — the chart tokens (`§8`).
- The **`TranscriptionBackend` protocol does not exist yet** (`_UNIFICATION.md §2.1`);
  it's a Tier-0 refactor. This plan is written so the harness works *today* against the
  concrete `TranscriptionEngine` and **slots onto `TranscriptionBackend` for free** once
  that lands (§7).

External anchors verified June 2026:
- **LibriSpeech** `test-clean`: **346 MB, 5.4 h, 2,620 utterances, 40 speakers (20F/20M)**,
  16 kHz **FLAC**, transcripts in `<chapter>.trans.txt` (`<utt-id> TEXT` per line),
  **CC BY 4.0** ([OpenSLR-12](https://www.openslr.org/12), [HF dataset card](https://huggingface.co/datasets/openslr/librispeech_asr)).
- **`SpeechAnalyzer` does support offline file transcription** — `AVAudioFile` →
  `analyzeSequence`; Argmax ships an **MIT-licensed** `apple-speechanalyzer-cli-example`
  that takes `.flac`/`.wav` and runs offline on macOS 26 ([repo](https://github.com/argmaxinc/apple-speechanalyzer-cli-example),
  [WWDC25 277](https://developer.apple.com/videos/play/wwdc2025/277/)). This is the template.
- **Whisper Large V3 reference WER on `test-clean` ≈ 2.4%** (WhisperKit/Argmax, matching
  the PyTorch model) ([Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)).
- **`jiwer`** (MIT) computes WER/CER via RapidFuzz ([jiwer](https://jitsi.github.io/jiwer/)).
- **OpenAI `EnglishTextNormalizer`** is the standard pre-WER normalizer (lowercase, strip
  punctuation, expand contractions, spell out / digitize numbers) — used so formatting
  differences don't inflate WER ([Whisper §normalization](https://github.com/openai/whisper/discussions/702),
  [HF audio course](https://huggingface.co/learn/audio-course/en/chapter5/evaluation)).

## 4. Design & approach

### 4.1 Shape: a separate executable + an optional Python scorer

A new **SwiftPM executable target `TalkieBench`** in the same package (sibling to `Talkie`,
sharing source via a tiny internal library — see §5/§3 layout). Swift owns the
load-bearing measurement (it must drive the *real* Apple pipeline and the Whisper baseline
*on the same machine*); Python owns only scoring (`jiwer` + `EnglishTextNormalizer`),
because re-implementing the Whisper normalizer in Swift would be a fidelity risk and the
Python tooling is the field-standard, auditable reference. The Swift tool writes a JSON
of `{utterance_id, reference, hypothesis, audio_seconds, wall_seconds}` per system; the
Python scorer reads that JSON and emits the WER/RTF table. **No Python is required to
*run* the systems** — only to *score* — so a reviewer who distrusts our WER math can
re-score our raw hypotheses independently. (A pure-Swift WER fallback ships too, §13.)

### 4.2 The two systems under test

**System A — Talkie (Apple `SpeechAnalyzer`).** The harness must exercise *Talkie's
actual recognition*, not a parallel reimplementation, or the benchmark proves nothing
about the app. Approach: add a **file-input method to `TranscriptionEngine`** (the only
production change, §5.1) — `transcribeFile(_ url: URL, localeIdentifier:) async throws ->
String` — that opens the FLAC via `AVAudioFile`, converts to the analyzer's
`bestAvailableAudioFormat` with `AVAudioConverter` (the same conversion `AudioCapture`
already does), feeds it through the *same* `SpeechAnalyzer`/`SpeechTranscriber` config as
live dictation, and returns the final transcript. This is also independently useful
(drag-a-file-to-transcribe is a plausible future feature) and is the natural
`TranscriptionBackend.transcribe(file:)` once §7 lands. The harness times *only* the
recognize call (model already warmed — see cold/warm, §4.4); cleanup/dictionary/vibe-coding
are **excluded** (we benchmark raw recognition, not post-processing — stated in the docs).

**System B — Whisper Large V3 baseline.** Run **on the same Mac, on-device, same audio**.
Two supported baselines, picked by the operator, both documented:
- **`whisper.cpp` Large V3** with Core ML ANE encoder (the apples-to-apples on-device
  C/C++ baseline; the README's named competitor). The harness shells out to a
  user-built `whisper-cli -m ggml-large-v3.bin` (Core ML model placed alongside) and
  parses its output + timing ([ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp)).
  whisper.cpp/Core ML gives the ANE-accelerated number the original claim implied.
- **Optional: WhisperKit (Argmax)** `openai_whisper-large-v3` — Swift-native, CoreML/ANE,
  the most rigorous published Apple-Silicon Whisper, with a known `test-clean` WER ≈2.4%
  to sanity-check our pipeline against ([Argmax blog](https://www.argmaxinc.com/blog/apple-and-argmax)).
  WhisperKit is added behind a SwiftPM trait/flag so the *default* `TalkieBench` build
  keeps zero third-party deps (genericity, §11); if absent the harness runs Talkie-only
  or whisper.cpp-only and says so.

**We deliberately label the baseline "Whisper Large V3" (full), not Turbo** — the harness
runs full Large V3 so the README claim is tested against the model it *names*, and the
docs explicitly note the original viral number used Turbo (a faster, distilled model),
which is *why* our honestly-measured speed margin may be smaller.

### 4.3 Metrics (what "honest" means here)

- **WER** — primary accuracy metric. Both systems' hypotheses pass through the **same
  `EnglishTextNormalizer`** before scoring (lowercase, strip punctuation, expand
  contractions, digit/number canonicalization) so we penalize mistranscription, not
  formatting. Report WER per system + the delta, with a 95% bootstrap CI over utterances.
  Also report **CER** (jiwer gives it free) as a secondary view.
- **Speed** — report **RTFx = audio_seconds / wall_seconds** (audio processed per wall
  second; higher = faster), plus **median per-utterance latency** and total corpus
  wall-time. RTFx is the honest cross-machine-comparable speed number; the README's
  "55% faster" becomes a *derived, reproduced* figure: `speed_delta = (RTFx_Talkie −
  RTFx_Whisper) / RTFx_Whisper`, printed with the machine + OS + model versions.
- **Provenance of the number** — every result row records: machine (`sysctl
  machdep.cpu.brand_string`), macOS version, Talkie commit, Whisper model + build flags,
  corpus subset + checksum, date. No number is reported without this footer.

### 4.4 Cold vs warm (the methodology trap)

This is where benchmarks lie, so it's pinned explicitly:
- **Warm (default, headline):** for *each* system, run a discard warm-up pass (first N
  utterances or a fixed clip) to trigger model load / ANE compile / asset reservation,
  then time the measured run. Talkie's `warmUp` (`TranscriptionEngine.swift:124-136`) is
  called first; whisper.cpp's Core ML model is JIT-compiled on first run (the harness
  warms it identically). Warm is the fair, repeatable headline.
- **Cold:** an optional `--cold` mode that times *including* first-load (model download
  excluded — the corpus model must be pre-installed; we measure compute, not network).
  Cold is reported separately, never blended into the headline.
- **Determinism:** Talkie's analyzer is effectively deterministic for a given audio;
  Whisper greedy decode (`temperature 0`, `beam_size` fixed and recorded). Run each
  system **3×**, report median + spread, to expose thermal throttling / scheduler noise.
- **Single corpus, identical audio bytes** to both systems (same decoded FLAC). No
  per-system audio massaging beyond each engine's required resample.

### 4.5 Flow

```
test-clean.tar.gz (CC BY 4.0, checksummed)
   │  scripts/bench/fetch_corpus.sh  (download + verify sha256 + extract)
   ▼
manifest.json  [{ id, flacPath, referenceText }]   ← built from *.trans.txt
   │
   ▼  TalkieBench run --systems talkie,whispercpp --runs 3 --warm
   ├─ System A: TranscriptionEngine.transcribeFile(flac) ── time ──┐
   ├─ System B: whisper.cpp / WhisperKit transcribe(flac) ─ time ──┤
   ▼                                                                ▼
results/raw-<system>-<date>.json  [{id, reference, hypothesis, audio_s, wall_s}]
   │
   ├─ scripts/bench/score.py  (jiwer + EnglishTextNormalizer) → results/scored.json
   │                                                            (WER, CER, RTFx, CIs)
   ▼
results/scored.json  ──►  TalkieBench chart   ──►  docs/benchmark/results.svg/.png
                          (on-brand SwiftUI → image)   + a Markdown table for README
```

## 5. New & changed files/types

### 5.1 The one production change (kept minimal, independently useful)

`TranscriptionEngine.swift` — add an offline file path that reuses the existing config:

```swift
extension TranscriptionEngine {
    /// Offline one-shot file transcription (benchmark + future drag-to-transcribe).
    /// Opens `url` (FLAC/WAV/CAF), converts to the analyzer's bestAvailableAudioFormat,
    /// runs the SAME SpeechTranscriber config as live dictation, returns final text.
    /// Mirrors transcribeBuffered but takes a URL and (unlike it) WILL install the
    /// model if asked, since the benchmark wants a guaranteed run.
    func transcribeFile(_ url: URL,
                        localeIdentifier id: String,
                        installIfNeeded: Bool = true) async throws -> String
}
```

It shares `resolvedLocale()`/`makeTranscriber()`/`ensureModelInstalled()`; the
file→buffer conversion is factored into a small pure helper so the harness (and a future
feature) can reuse it:

```swift
// Sources/Talkie/AudioFileLoader.swift  (NEW, in core — pure, Sendable)
enum AudioFileLoader {
    /// Decode `url` and resample to `target`, returning chunked PCM buffers.
    static func buffers(from url: URL, target: AVAudioFormat,
                        chunkFrames: AVAudioFrameCount = 16_000) throws -> [AVAudioPCMBuffer]
}
```

### 5.2 New `TalkieBench` target (`Sources/TalkieBench/`)

```swift
// BenchManifest.swift
struct BenchItem: Codable, Sendable { let id: String; let flacPath: String; let reference: String }
struct BenchManifest: Codable, Sendable { let subset: String; let sha256: String; let items: [BenchItem] }

// BenchSystem.swift — the seam every baseline implements
protocol BenchSystem: Sendable {
    var name: String { get }                       // "talkie", "whispercpp", "whisperkit"
    var version: String { get }                    // model id / commit / build flags
    func warmUp() async throws
    func transcribe(_ item: BenchItem) async throws -> String
}

struct TalkieBenchSystem: BenchSystem   { /* wraps TranscriptionEngine.transcribeFile */ }
struct WhisperCppBenchSystem: BenchSystem { /* Process → whisper-cli, parse stdout + timing */ }
#if canImport(WhisperKit)
struct WhisperKitBenchSystem: BenchSystem { /* WhisperKit on-device */ }
#endif

// BenchRunner.swift
struct RawResult: Codable, Sendable {
    let id, reference, hypothesis: String
    let audioSeconds, wallSeconds: Double
}
struct RunMeta: Codable, Sendable {           // the honesty footer
    let machine, macOSVersion, talkieCommit, date: String
    let warm: Bool; let runs: Int
}
actor BenchRunner {
    func run(_ system: BenchSystem, _ manifest: BenchManifest,
             warm: Bool, runs: Int) async throws -> (meta: RunMeta, results: [RawResult])
}

// main.swift — ArgumentParser-free hand-rolled flag parse (zero-dep, like the app):
//   talkiebench fetch | run --systems a,b --runs 3 [--warm|--cold] | chart
```

### 5.3 Chart renderer (on-brand)

```swift
// BenchChart.swift — a SwiftUI view rendered headless to PNG/SVG via ImageRenderer.
struct BenchChartView: View { let scored: ScoredResults; /* §8 */ }
```

### 5.4 Scripts & docs

- `scripts/bench/fetch_corpus.sh` — curl `test-clean.tar.gz` from OpenSLR (+ EU/CN mirror
  fallback), verify sha256, extract, build `manifest.json` from `*.trans.txt`.
- `scripts/bench/score.py` — `jiwer` + `whisper_normalizer.english.EnglishTextNormalizer`;
  reads `raw-*.json`, writes `scored.json`. `requirements.txt` pins `jiwer`,
  `whisper-normalizer`.
- `scripts/bench/build_whispercpp.sh` — optional, documents the exact whisper.cpp +
  Core ML build the baseline expects (so "Whisper Large V3" is a *named, reproducible*
  build, not a vague label).
- `docs/BENCHMARK.md` — the reproduce-it-yourself doc (methodology, licensing, exact
  commands, how to read the result, what is NOT measured).

## 6. Data model & persistence

Nothing touches the app's runtime stores or `~/Library/Application Support/Talkie/`. All
artifacts live **under the repo, git-ignored except the published result**:

| Artifact | Path | Format | Notes |
|---|---|---|---|
| Corpus | `bench/corpus/LibriSpeech/test-clean/…` | FLAC + `.trans.txt` | git-ignored; fetched by script; sha256-verified |
| Manifest | `bench/corpus/manifest.json` | JSON | `{subset, sha256, items[]}` |
| Raw hypotheses | `bench/results/raw-<system>-<iso8601>.json` | JSON | `[RawResult]` + `RunMeta` footer |
| Scored | `bench/results/scored-<iso8601>.json` | JSON | WER/CER/RTFx + bootstrap CIs |
| Published chart | `docs/benchmark/results.png` + `.svg` | image | **committed** — the README embed |
| Published table | `docs/benchmark/results.md` | Markdown | **committed** — pasted into README |

`.gitignore` adds `bench/corpus/` and `bench/results/raw-*` (large / machine-specific);
the *scored* summary, chart, and table are committed so the repo carries a dated,
attributed result without the 346 MB corpus. Decoding is failure-tolerant
(`decodeIfPresent`, optional fields) per house style so an old result JSON still parses.
No migration concerns — net-new, no back-compat surface.

## 7. Unification contract

Per `_UNIFICATION.md §6 / feature 17`:

- **Exposes:** the benchmark target/script (WER + RTFx/latency for Talkie's pipeline vs
  Whisper Large V3 on the same Apple Silicon machine) + an on-brand results chart, and a
  reusable **`BenchSystem`** seam + `RawResult`/scoring pipeline that any backend plugs
  into. It exposes **`docs/benchmark/results.{md,png,svg}`** as the canonical,
  regenerable performance artifact the README links to.
- **Consumes:** the **`TranscriptionBackend` protocol** (`§2.1`) — "run the same corpus
  through any backend, also validates 20." Concretely: today `TalkieBenchSystem` wraps the
  concrete `TranscriptionEngine.transcribeFile`; the *instant* `TranscriptionBackend`
  lands (`backend.transcribe(file:)` / a file-shaped session), `BenchSystem` becomes a
  one-line adapter over **any** `TranscriptionBackend` (`AppleSpeechBackend`,
  feature-20's `WhisperCppBackend`/`Parakeet-CoreML`), so the harness becomes the
  acceptance gate for feature 20. It also consumes a **licensed corpus** (LibriSpeech
  `test-clean`, CC BY 4.0).
- **Note (honored):** "keep it honest (cold vs warm model, on-device, documented method).
  Doubles as the regression harness for 20's backends." → §4.4 (cold/warm), §4.2
  (on-device, same machine), `docs/BENCHMARK.md` (method), §2 (corrects the inflated
  README claim instead of certifying it).
- **Does NOT consume the Context Graph (05).** 17 is a pure recognition-quality harness;
  it reads no entities, biases nothing (it runs the recognizer *without* the
  `biasPhrases` union so the WER reflects baseline model quality, not Talkie's vocabulary
  advantage — biasing would be a *separate, clearly-labeled* "Talkie-with-context" row if
  ever added, never folded into the headline). It therefore neither blocks nor is blocked
  by the keystone; it depends only on the `TranscriptionBackend` seam being clean.

## 8. UI / UX

The benchmark is **not** a runtime app surface — it's a developer/CI artifact. The only
UI is the **rendered results chart**, generated headless via SwiftUI `ImageRenderer` so it
matches the app's look exactly (no second design language), and embedded in the README +
`docs/BENCHMARK.md`.

On-brand per `BRAND.md` / `DesignSystem.swift`:
- A small **grouped bar chart**: two metric panels (Accuracy: WER% lower-is-better;
  Speed: RTFx higher-is-better), Talkie vs Whisper Large V3.
- **Feathers for data only** (`BRAND.md §3.3`): Talkie bars in `Theme.featherBlue`,
  Whisper in `Theme.featherGold` (a categorical pair, not the brand accent). The single
  brand accent (`Theme.coral`, now blue) is reserved for the title rule, used once.
- **Serif for the hero numbers** (`Font.talkieMetric`) — the WER% and RTFx values; SF Pro
  for labels; an **`Eyebrow`** ("WORD ERROR RATE", "REAL-TIME FACTOR") above each panel.
- **Surfaces & shape:** `talkieCard()` container, `Theme.surfaceSunken` bar tracks,
  squircle corners, the whisper shadow — no outlines, no gradients (`BRAND.md §5`,
  `§10 Don't`).
- **Honest copy** (`BRAND.md §9`): a footer line states the machine, macOS version,
  Talkie commit, Whisper build, corpus, date, run count, and "warm model; raw recognition
  only (no cleanup/biasing)." If the measured speed delta is e.g. 18%, the chart says 18%
  — and the README sentence becomes *"On an M-series Mac, Talkie's Apple-Speech pipeline
  transcribed LibriSpeech test-clean at N× real-time, ~X% faster than whisper.cpp Large V3,
  at comparable accuracy (WER A% vs B%). Re-run it: `./scripts/bench/run.sh`."* No invented
  percentile, no "blow past."

## 9. Permissions / entitlements / Info.plist

**None.** This is the cleanest feature in the set on this axis:
- `TalkieBench` is a CLI run from a terminal — **no microphone, no Input Monitoring, no
  Accessibility** (it reads files, not a live mic or the focused app). `SpeechAnalyzer`
  file transcription needs no TCC prompt for file input (the corpus lives in the repo,
  not a TCC-protected folder like `~/Documents`).
- **No new entitlement.** It does not even need `com.apple.security.device.audio-input`
  (no capture). It is a separate target, so the shipped `Talkie.app` entitlement set is
  untouched.
- The one model download (`SpeechTranscriber` en-US asset) is the same on-device asset the
  app already uses, gated by `AssetInventory` — no new plist key. whisper.cpp/WhisperKit
  models are downloaded by their own tooling outside the app sandbox entirely.

## 10. Privacy posture

**Zero-network preserved for the app; the harness's only network is an explicit, manual
corpus download.** Specifics:
- The transcription itself is **100% on-device** for both systems (Apple `SpeechAnalyzer`
  and on-device whisper.cpp/WhisperKit) — the benchmark *demonstrates* the privacy thesis,
  it doesn't dent it.
- `TalkieBench` is a **separate target** and adds **no `URLSession` to the app**. The
  `grep` invariant (`_CURRENT_STATE.md §0`) over the shipped `Talkie` target stays clean
  — the corpus fetch is a shell `curl` in `scripts/bench/`, run deliberately by a
  developer, never by the app at runtime.
- LibriSpeech audio is public-domain LibriVox; downloading it leaks nothing personal. The
  Python scorer runs locally; no result is uploaded by the harness (publishing the chart
  is a manual `git commit`).
- Stated plainly in `docs/BENCHMARK.md`: "Running the benchmark downloads a public speech
  corpus once. Transcription is on-device. Nothing about you is involved or sent."

## 11. Open-source genericity

- **No hardcoded personal stack.** The default `TalkieBench` build has **zero third-party
  Swift deps** (matches `Package.swift`): Talkie pipeline + whisper.cpp-via-`Process` +
  pure-Swift WER fallback all work with nothing installed but a built whisper.cpp binary
  the user points at. WhisperKit and the Python `jiwer` scorer are **optional
  enhancements**, behind a build trait / not required to get a number.
- **Zero-config default:** `./scripts/bench/run.sh` fetches the corpus, runs Talkie-only,
  and prints WER + RTFx with the pure-Swift scorer — no Python, no Whisper needed — so a
  newcomer can verify *Talkie's* numbers on a fresh checkout. Adding a Whisper baseline is
  one documented build step.
- **Extensible by the community via one protocol:** a new baseline = one `BenchSystem`
  conformer (or, post-§7, any `TranscriptionBackend`). Swapping the corpus = a new
  manifest builder (the harness is corpus-agnostic; LibriSpeech is the documented default,
  but Common Voice / TED-LIUM drop in by writing a different `fetch`+`manifest` step). The
  scorer is the field-standard `jiwer`, not a bespoke metric, so results are comparable to
  published literature.
- Licensing is documented and clean: corpus **CC BY 4.0** (attribution line in
  `docs/BENCHMARK.md` + the chart footer), `jiwer`/Argmax CLI/whisper.cpp all permissive
  (MIT/Apache-class). We attribute LibriSpeech (Panayotov et al.) as CC BY 4.0 requires.

## 12. Risks, edge cases, failure modes

- **The honest number may be unflattering** (the headline risk). The viral "55%" used
  Turbo + wall-clock on one file; full Large V3 on whisper.cpp/Core ML may be much closer,
  and on **WER Whisper Large V3 (~2.4%) may *beat* Apple's model**. *Graceful degradation:*
  the plan's whole point is to report whatever is true and reword the README accordingly
  (§2/§8). Mitigation isn't to inflate — it's framing: lead with *latency/streaming +
  privacy + $0 + on-device*, present accuracy as "competitive," cite the CI.
- **`SpeechAnalyzer` file path differs from live mic enough to bias results.** We
  deliberately route through the *same* transcriber config; documented caveat: file-mode
  has no real-time pressure, so its WER may be *better* than the live experience — we label
  it "batch/file recognition," not "your live dictation accuracy."
- **whisper.cpp build variance** (quantization, threads, Core ML on/off) changes the number
  wildly. *Mitigation:* `build_whispercpp.sh` pins the exact build; `version` records flags;
  the chart footer names them. We compare full `ggml-large-v3` (fp16) + Core ML by default.
- **Thermal throttling / background load** skews speed. *Mitigation:* 3× runs + median +
  spread; doc says "plug in, quit other apps, let it cool."
- **Model not installed** → Talkie's en-US asset downloads on first run (network, one-time);
  whisper.cpp model must be pre-fetched. *Mitigation:* `fetch_corpus.sh` companion step
  pre-installs; cold-mode explicitly excludes download time.
- **LibriSpeech reference is clean read speech** — not representative of meetings/noisy
  dictation. Stated as a known limitation; a future row could add a noisier corpus
  (Common Voice). We never claim test-clean WER == real-world WER.
- **Normalizer mismatch** between the two systems would be cheating. *Mitigation:* the
  *same* `EnglishTextNormalizer` is applied to both before scoring; documented.
- **`AVAudioConverter` FLAC→analyzer-format edge cases** (sample-rate mismatch). The
  `transcribeBuffered` format-guard pattern (`TranscriptionEngine.swift:152-156`) shows the
  failure mode; `AudioFileLoader` resamples explicitly to `bestAvailableAudioFormat` so it
  can't silently no-op.

## 13. Testing & verification

- **Self-consistency unit (Swift, in `TalkieBench`):** feed three known LibriSpeech
  utterances with hand-checked references; assert the pure-Swift WER scorer matches `jiwer`
  on the same pair within rounding (cross-checks the two scorers), and that WER of a string
  against itself is 0 and against an empty hypothesis is 1.0.
- **Sanity gate against published baselines:** our WhisperKit/whisper.cpp Large V3 WER on
  `test-clean` must land near the published **~2.4%** (±a small band); if it's wildly off,
  the harness (audio decode, normalizer, or parse) is broken, not the model. This is the
  single most important correctness check and is asserted in CI.
- **Manual `/run` path:** `./scripts/bench/run.sh` end-to-end on the author's Mac →
  produces `scored.json` + `results.png`; eyeball the chart renders on-brand and the footer
  carries machine/commit/date.
- **Determinism check:** same audio twice through Talkie → identical hypothesis (analyzer
  is effectively deterministic); flag if not.
- **CI (feature 16 pipeline, when it exists):** a *smoke* job runs a **10-utterance subset**
  (fast, no 346 MB download — a tiny vendored clip set) on every PR to catch regressions in
  `transcribeFile`/`AudioFileLoader`; the **full** `test-clean` run is a manual/nightly job
  on a self-hosted Apple-Silicon runner (mirrors how Argmax runs theirs). The full run
  regenerates `docs/benchmark/results.*` and the diff is reviewed before commit.
- **No app behavior change to verify** beyond the new `transcribeFile` method, which is
  covered by the self-consistency test and is dead code in the shipping app until a
  drag-to-transcribe feature uses it.

## 14. Effort & phasing

- **MVP slice (S–M): "honest single-number" — Talkie-only, no Whisper, no Python.**
  `transcribeFile` + `AudioFileLoader` (S), `fetch_corpus.sh` + manifest builder (S),
  `TalkieBench run --systems talkie` with pure-Swift WER + RTFx (M), printed table. This
  alone lets us replace the README's borrowed claim with *"WER X% / N× real-time on
  test-clean, on an M-series Mac"* — defensible immediately. **This is the must-ship.**
- **Phase 2 (M): the comparison.** `WhisperCppBenchSystem` + `build_whispercpp.sh` (M),
  `score.py` with `jiwer`+`EnglishTextNormalizer` + bootstrap CIs (S), cold/warm + 3×
  median (S). Now "vs Whisper Large V3" is real and reproduced.
- **Phase 3 (S–M): the artifact.** `BenchChartView` → PNG/SVG via `ImageRenderer` (M),
  `docs/BENCHMARK.md` + committed `results.*`, README rewrite (S).
- **Phase 4 (S, deferred): polish & breadth.** Optional WhisperKit baseline behind a trait;
  CI smoke job; a second (noisier) corpus row.
- **Total: M.** Biggest single cost is getting `transcribeFile` faithful to the live
  pipeline and the whisper.cpp build pinned; everything else is plumbing.

## 15. Dependencies & interactions

- **Needs (soft):** **`TranscriptionBackend` (§2.1, Tier-0)** — works today against
  concrete `TranscriptionEngine`, but is *meant* to consume the protocol; sequence the
  protocol refactor first if it's already in flight, else ship the MVP against the actor
  and adapt later (one-line change). Needs a built **whisper.cpp** for the comparison
  phase (external, documented).
- **Enables / validates:** **feature 20 (pluggable transcription backend)** — this *is*
  20's acceptance/regression gate; every new backend (`WhisperCppBackend`,
  `Parakeet-CoreML`) is signed off by re-running this harness. Also the credibility input
  for **feature 16 (install/update)** launch materials and **feature 15 (privacy proof)**
  ("on-device *and* fast — here's the data").
- **Overlaps (share code, don't fork):** the file→buffer loader (`AudioFileLoader`) and
  `transcribeFile` are reusable by any future "transcribe a dropped file" feature; the
  `BenchChartView` reuses `DesignSystem.swift` tokens (no new chart lib). It must **not**
  pull in the Context Graph (05) or biasing — keeping the WER a clean model-quality
  measurement (§7).
- **No interaction** with meetings (01/far-end), commands (08/12), export (10), MCP (06/07),
  or the bridge (18) — it is a leaf feature that quietly underwrites the product's central
  speed claim.
```

---

## G4 correction note (2026-07-03) — shared file-kit extraction + `talkie` CLI

Work package **G4** delivered the "transcribe a dropped file" reuse this plan
anticipated (see the *Overlaps* bullet above: `AudioFileLoader` + `transcribeFile`
"reusable by any future transcribe-a-dropped-file feature"). What landed:

- `AudioFileLoader` and the file transcriber were **moved out of `Sources/TalkieBench`
  into a new shared library target `TalkieFileKit`** (`Sources/TalkieFileKit/`), and
  `talkie-bench` now depends on it. The transcriber was renamed `BenchTranscriber` →
  **`FileTranscriber`**. Bench behavior is unchanged — `talkie-bench --selftest` is
  byte-identical before/after, verified.
- `FileTranscriber` gained an **additive** `transcribeTimed(...)` returning
  `(text, [TimedSegment])` from `SpeechTranscriber.Result.range`; the bench keeps using
  the text-only `transcribe(...)` and never pays for it.
- A new executable **`talkie-cli`** (`Sources/TalkieCLI/`) provides `talkie transcribe`
  (plain / `--md` / `--srt` / `--vtt` / `--json`, `--locale`) and `talkie last [-n N]`.
  Hand-rolled arg parsing, zero dependencies, on-device only.

**Spec deviation (case-insensitive APFS):** the G4 spec said to copy the CLI to
`Talkie.app/Contents/MacOS/talkie`. That is **impossible** — the app's main executable
is `Contents/MacOS/Talkie`, and macOS ships on case-INSENSITIVE APFS, so `talkie` and
`Talkie` are the SAME path; the copy silently overwrote the 7.9 MB app binary with the
~280 KB CLI (the bundle then launched the CLI instead of the app). Fixed by bundling the
CLI at **`Contents/Helpers/talkie`** instead (a standard nested-tool location that keeps
the exact `talkie` basename). The SwiftPM product stays `talkie-cli` for the same reason.
README's PATH symlink is therefore
`ln -s /Applications/Talkie.app/Contents/Helpers/talkie /usr/local/bin/talkie`.
`check-no-network.sh` now also scans `Sources/TalkieFileKit` + `Sources/TalkieCLI`.
