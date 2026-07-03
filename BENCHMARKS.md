# Talkie benchmarks

Every number here came from a real [`talkie-bench`](Sources/TalkieBench/) run on
named hardware — **measured, not inherited.** Talkie's recognition is Apple's
on-device `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+, Apple Silicon); this
file is how we hold its published speed and accuracy honest.

## Method

`talkie-bench` runs a folder of audio files plus their reference transcripts
through the same on-device pipeline the app uses, and reports, **on the machine
you run it on**:

- **WER** — Word Error Rate (Levenshtein edit distance over words; lower is better,
  0% is a perfect transcript). Corpus WER is micro-averaged: total word errors ÷
  total reference words.
- **CER** — Character Error Rate, the same metric over characters.
- **RTFx** — Real-Time Factor, `audio_seconds / wall_seconds` (higher is better;
  40× means 40 seconds of audio transcribed per wall-clock second).
- **median / p90 per-file latency** — the wall time to transcribe one file.

It measures **RAW recognition only** — no cleanup, no dictionary biasing, no
vibe-coding. That keeps WER a clean measure of the model's quality rather than
Talkie's vocabulary advantage. The timed window is only the recognize call; file
discovery, audio decode/resample, and WER scoring are excluded. A warm-up pass
(default 3 files, discarded) triggers model load / ANE compile so timings reflect
steady state.

**Corpus:** the documented default is **LibriSpeech `test-clean`** — ~5.4 h of
clean read English, 2,620 utterances, 40 speakers, 16 kHz. It is clean read
speech, so its WER is a **floor, not your live dictation accuracy**. LibriSpeech
is licensed **CC BY 4.0** and must be attributed:

> LibriSpeech (Panayotov, Chen, Povey, Khudanpur, 2015), OpenSLR-12,
> <https://www.openslr.org/12> — licensed CC BY 4.0.

(The harness is corpus-agnostic — any folder of audio with matching reference
text works. See the header of [`main.swift`](Sources/TalkieBench/main.swift).)

**Privacy note (the one download caveat):** the app and the harness open **no**
network connection. The very first transcription for a language asks *macOS* to
fetch Apple's on-device speech model — a system-mediated `AssetInventory`
download, not an in-process request by Talkie. That is why the zero-network gate
(`scripts/check-no-network.sh`) stays green: nothing about you, and nothing you
transcribe, leaves the machine.

## Honesty rules

1. **A row must come from a real run.** No number is hand-entered, estimated, or
   carried over from another tool. If it is not from a `talkie-bench` run on the
   listed machine, it does not go in the table.
2. **Every row carries its exact command** (below the table), so anyone can
   reproduce it. The `--markdown` flag emits the row straight from the run, using
   the *same* aggregation the on-screen table prints, so the row can never drift
   from the report it summarises.
3. **No relative engine claim without a measured comparison.** There is **no
   Whisper (or any other engine) comparison in this file** — we have not run one
   on the same files, so Talkie makes **no relative speed or accuracy claim**. The
   old README line ("~55% faster than Whisper Large V3") was a borrowed wall-clock
   test of Whisper Large V3 *Turbo* on a single file with no accuracy measured; it
   has been retired. If we ever publish a comparison, it will be a Whisper run on
   *these exact files*, labelled as what it is.
4. **test-clean WER ≠ real-world WER.** It is a clean-read-speech floor. We never
   present it as live dictation accuracy.

## Results

| date | machine | macOS | locale | corpus (files/min) | WER | CER | RTFx | median lat | p90 lat |
|---|---|---|---|---|---|---|---|---|---|
| 2026-07-03 | Apple M3 | macOS 26.5 | en-US | test-clean 87f/13.0m | 2.05% | 0.50% | 40.3× | 0.192 s | 0.397 s |

Exact command for the row above (a 90-file slice of test-clean, 3 warm-up files
discarded → 87 measured, run from the repo root):

```bash
swift build -c release
.build/release/talkie-bench \
    --corpus ./LibriSpeech/test-clean \
    --locale en-US \
    --warmup 3 \
    --limit 90 \
    --markdown
```

The `13.0m` in the corpus cell is the audio minutes actually measured (the 87
warm files), not the whole corpus. `--limit 0` (the default) runs all 2,620
utterances; the 90-file slice is a fast, representative pass.

## Run recipe (reproduce or extend the table)

1. **Build the harness:**

   ```bash
   swift build -c release
   ```

2. **Get the corpus** (LibriSpeech test-clean, ~346 MB; this is the one network
   step, and it is *your* download of a CC BY 4.0 dataset — the app never fetches
   it):

   ```bash
   curl -LO https://www.openslr.org/resources/12/test-clean.tar.gz
   tar xzf test-clean.tar.gz          # → LibriSpeech/test-clean/...
   ```

3. **Run it** (the first run also triggers the one-time macOS speech-model
   download described above):

   ```bash
   .build/release/talkie-bench --corpus ./LibriSpeech/test-clean --markdown
   ```

   The `--markdown` flag prints one pipe-delimited row after the human-readable
   table — copy it into the **Results** table with your machine's numbers, then
   add the exact command you ran beneath it.

**Scorer self-check** (no corpus, model, or network needed — always green):

```bash
.build/release/talkie-bench --selftest
```

---

Scope note: this file is deliberately narrow — measured on-device recognition
accuracy/speed, and how to reproduce it. A cross-engine leaderboard and any
Whisper/other-engine numbers are explicitly out of scope until such a run is
actually performed on these files.
