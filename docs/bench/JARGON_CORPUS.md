# The jargon corpus — recording protocol (`jargon-v1`)

This is the recipe for building **your own voice, your own jargon** recognition
benchmark: a small private corpus of clips where you actually say the niche terms
Talkie has to get right (`claude.md`, `Higgsfield`, `worktree`, `SwiftPM`,
`Coralate`, `talkie-bench`, `NicheCorrector`, `SpeechAnalyzer`, …), each with a
reference transcript, so any recognizer or decoding trick can be scored against
the same bar with `talkie-bench`.

It is deliberately reproducible: follow the steps and you get a comparable corpus
every time, so a number you publish today can be re-earned tomorrow.

> **One speaker, by design.** `jargon-v1` is one person's voice (Jann's). The
> numbers it produces describe how well a system recognizes **this speaker's**
> jargon on **these mics**, and generalize to other voices/accents only loosely.
> That is the honest scope — never report a jargon-v1 number as a general
> accuracy claim. Widening to more speakers is a separate, later corpus.

---

## 0. Where the audio lives (NOT in this repo)

The clips are your voice — personal data. They stay **out of the public repo,
permanently.** Record into the private brain repo instead:

```
/Users/jann/talkie-brain/research/corpora/jargon-v1/
```

`talkie-brain` is private. This public repo carries only the *protocol* (this
file) and the *harness* (`Sources/TalkieBench/`) — never the recordings or the
references built from them. Corpus folders are **versioned** (`jargon-v1`,
`jargon-v2`, …); never mutate a published version in place — cut a new one, so an
old published number stays reproducible against the exact bytes that produced it.

---

## 1. What to record

- **60–120 clips**, **3–15 s each.** Enough to make per-term recall meaningful
  (each term said several times across clips) without turning recording into a
  chore. Aim for **each jargon term spoken in at least 3 different clips**, in
  different sentence positions (start / middle / end) — recognizers behave
  differently at utterance boundaries.
- **A mix of two styles:**
  - **Read sentences** — the templates in §3, which embed the jargon in natural
    phrasing. Reproducible; the reference is known exactly before you speak.
  - **Spontaneous** — talk for ~10 s about what you actually did today
    ("edited `claude.md`, spun up a `worktree`, ran `talkie-bench`…"). Closer to
    live dictation; you transcribe the reference by hand afterward.
  Roughly half and half.
- **On the mics you actually dictate through.** Record the same content on each:
  - the **built-in MacBook mic**, and
  - **AirPods** (the common wireless path — its own frequency response and codec).
  Keep them in separate subfolders (see §2) so you can compare per-mic recall;
  AirPods vs built-in is a real accuracy variable, not a rounding error.
- **A small DE/EN code-switch subset** (~10 clips) for later: sentences that
  switch between German and English mid-utterance the way you actually speak
  ("ich hab die `claude.md` editiert und dann `talkie-bench` laufen lassen").
  Tag these clearly; they stress the language-selection path, not just jargon.

Record in a normal working environment (some keyboard/room noise is fine and
realistic) — this is a live-dictation benchmark, not a studio WER floor.

---

## 2. Folder layout & file naming

`talkie-bench` pairs each audio file with a **sidecar reference** named after the
same stem (the `CorpusLoader` auto-detects `<stem>.txt`). Use a stable, sortable
stem per clip:

```
jargon-v1/
  builtin/
    read-001.wav        read-001.txt        # the reference transcript
    read-002.wav        read-002.txt
    spont-001.wav       spont-001.txt
    ...
  airpods/
    read-001.wav        read-001.txt
    ...
  codeswitch/
    cs-001.wav          cs-001.txt
    ...
```

- **Audio:** any format `AVAudioFile` decodes — `wav`, `flac`, `caf`, `aiff`,
  `m4a`, `mp3`. WAV/FLAC 16 kHz mono is plenty; the harness resamples to the
  analyzer's required format anyway.
- **Reference (`<stem>.txt`):** the whole file is the transcript for that one
  clip. Write **what you actually said**, spelled the way the term is really
  written (`claude.md`, not "claude dot md"; `SwiftPM`, not "swift PM"). The
  normalizer folds case and punctuation on both sides, so don't fuss over commas
  — but DO get the *word* right, because that is what recall measures.

You can run the harness against the whole `jargon-v1/` folder at once (it walks
recursively) or one mic subfolder at a time to get per-mic numbers.

---

## 3. Sentence templates (embed the real jargon list)

Read these aloud, one per clip, saving the matching reference. They embed the
jargon list in natural phrasing. Adjust to your real workflow — the point is that
the term is *spoken*, in context, and the reference matches word-for-word.

```
I edited claude.md and then opened a fresh worktree for the change.
Run talkie-bench against the corpus before you touch NicheCorrector.
Coralate is the product; the Context Graph is the moat.
I used SwiftPM to build it, no external dependencies at all.
Higgsfield generated the macaw, and I removed the background.
The SpeechAnalyzer path feeds contextualStrings into the recognizer.
Check the worktree first, then rebase onto origin main.
I bumped claude.md, re-ran talkie-bench, and the WER held steady.
NicheCorrector only catches close misses, not novel proper nouns.
SwiftPM has zero dependencies by design — that's a product claim.
The Context Graph is one brain fed by two mouths.
I pushed the branch, opened a PR, and let the ladder run.
contextualStrings biasing is a soft no-op on this stack.
Talkie stays provably zero-network by default.
Coralate, Higgsfield, and SpeechAnalyzer all showed up in that clip.
```

Keep a running **phrase file** of the exact terms you want per-term recall on
(one per line, `#` for comments) — this is what you pass to `--terms` and
`--bias`. Model it on `docs/niche-bias-phrases.sample.txt` (whose shipped ML
terms are explicit placeholders — replace them with YOUR jargon):

```
# jargon-v1 terms — the vocabulary this corpus exists to measure.
claude.md
talkie-bench
worktree
SwiftPM
Coralate
Context Graph
NicheCorrector
Higgsfield
SpeechAnalyzer
contextualStrings
```

Store that phrase file next to the corpus in `talkie-brain` (it's derived from
your jargon, not a public artifact).

---

## 4. Running the baseline & publishing numbers

Build the harness once (`swift build -c release`), then run the three passes and
record the results **to talkie-brain** (not here).

**a) Standard on-device run** — Apple SpeechAnalyzer's raw WER/CER on your voice:

```sh
.build/release/talkie-bench \
    --corpus /Users/jann/talkie-brain/research/corpora/jargon-v1 \
    --locale en-US \
    --terms  /Users/jann/talkie-brain/research/corpora/jargon-v1/jargon-terms.txt \
    --json   /Users/jann/talkie-brain/research/corpora/jargon-v1/baseline-apple.json
```

This prints WER, CER, and the **per-term recall** table (the number that actually
matters for jargon). `--json` saves the raw per-file rows for independent
re-scoring.

**b) Bias on/off delta (gate zero)** — does `contextualStrings` biasing move WER
on your jargon? Pass the SAME phrase list `--terms` scores, so "bias on" is
biasing with exactly the terms you're measuring recall on:

```sh
.build/release/talkie-bench \
    --corpus /Users/jann/talkie-brain/research/corpora/jargon-v1 \
    --locale en-US \
    --bias   /Users/jann/talkie-brain/research/corpora/jargon-v1/jargon-terms.txt
```

Record the absolute WER delta (± points) and the verdict the tool prints. This is
the retroactive, reproducible version of the gate-zero result the niche-vocabulary
plan lists as "TODO (needs your voice)".

**c) Any other system** — Whisper Large V3, a cloud API, or Apple's own output
re-scored after a post-hoc corrector: produce a `<stem>.hyp.txt` per clip in a
directory, then score it against the SAME references with no model run:

```sh
.build/release/talkie-bench \
    --corpus     /Users/jann/talkie-brain/research/corpora/jargon-v1 \
    --hypotheses /path/to/that-system/hyp \
    --terms      /Users/jann/talkie-brain/research/corpora/jargon-v1/jargon-terms.txt
```

Both sides are normalized identically (`TextNormalizer`), so every system's WER
and per-term recall are directly comparable on the same bar.

### What to publish (to talkie-brain, honestly)

For each system, record: **WER, CER, aggregate term recall, and the bias on/off
delta**, plus the provenance footer the tool prints (machine, macOS, date, corpus
version, locale). State plainly that this is **one speaker** and note the mic.
Never round a measurement into a marketing line; the number is only credible with
its footer attached.

---

## 5. Sanity-checking the harness itself

Before trusting a real number, confirm the scorer is honest: copy each reference
to a `<stem>.hyp.txt` (a perfect transcript) and score it. You must get **WER 0.0
and term recall 100%** — anything else means the harness, not the recognizer, is
wrong.

```sh
# fake "perfect" hypotheses = copies of the references
mkdir -p /tmp/jargon-fakehyp
for f in /Users/jann/talkie-brain/research/corpora/jargon-v1/**/*.txt; do
  cp "$f" "/tmp/jargon-fakehyp/$(basename "${f%.txt}").hyp.txt"
done
.build/release/talkie-bench \
    --corpus     /Users/jann/talkie-brain/research/corpora/jargon-v1 \
    --hypotheses /tmp/jargon-fakehyp \
    --terms      /Users/jann/talkie-brain/research/corpora/jargon-v1/jargon-terms.txt
# expect: WER 0.00%, aggregate term recall 100.00%
```

The harness ships with the same invariant checked in-process
(`talkie-bench --selftest`), covering the WER math, per-term recall, and the
hypothesis loader with no corpus or model needed.
```
