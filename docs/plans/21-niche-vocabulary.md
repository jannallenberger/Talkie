# Feature 21 — Confidence-based niche vocabulary (learn & bias your jargon)

> Engineer-ready plan. Grounded in the code on `feat/meeting-notch-multilingual`.
> Phase 0 core + the gate-zero benchmark are **already implemented** (this commit);
> the rest is sequenced below. Honors the privacy invariants in `_UNIFICATION.md`
> (local-only core; biasing rides the existing on-device `contextualStrings` seam).

## 1. Summary

Talkie learns the rare, domain-specific words you actually use — jargon, product
names, code identifiers — and biases on-device recognition toward them, ranked by a
**confidence** it builds from your own usage, so niche terms get transcribed
correctly instead of being rounded off to common words ("kubelet" not "cube let").

The hard part is already ours: Talkie sets `AnalysisContext.contextualStrings` in
three live places (`TranscriptionEngine.swift:351-356`, `:252-256`,
`Meetings/MultiLangStreamTranscriber.swift:66-70`) and the dictionary already flows
through it. This feature is **smarter selection into the 180-slot bias budget**
assembled in `AppDelegate.beginDictation` — not an engine change.

## 2. Why it matters

Domain jargon is exactly where a generic STT model fails and where a personal,
local, learned vocabulary is a moat a cloud competitor can't copy. It compounds the
Context Graph (feature 05): the more you talk, the better Talkie spells the things
only you talk about. 100% on-device — your jargon never leaves the Mac.

## 3. The core loop

`detect niche → select boosted terms → bias the recognizer → learn from corrections
→ raise confidence → next session biases harder`. See the design discussion for the
full rationale; the confidence model and selection surface are the keystone.

## 4. Gate zero (settle BEFORE wiring) — **DONE (tooling)**

On-device `contextualStrings` biasing is documented in places to be a silent soft
no-op. Everything downstream is contingent on it actually moving WER, so the
benchmark comes first.

- **Implemented:** `talkie-bench --bias <phrases.txt>` transcribes each clip twice
  (bias off vs on) and reports the WER delta with a verdict
  (`Sources/TalkieBench/BiasComparison.swift`; `BenchTranscriber.transcribe` now
  takes `contextualStrings:`, mirroring the live engine).
- **TODO (needs you):** record a small jargon corpus (clips where you say the niche
  terms + reference transcripts) and a phrase file, then run it. If WER drops →
  proceed. If flat → skip the recognizer-biasing phases, build the post-hoc
  `TextProcessor` fallback (Phase 4) instead. If worse → investigate collisions.

```
swift build -c release
.build/release/talkie-bench --corpus ./jargon-clips --locale en-US \
    --bias ./docs/niche-bias-phrases.sample.txt
```

## 5. Phase 0 — minimal loop, one implicit niche — **DONE (core + tests)**

Implemented in `Sources/Talkie/Niche/`, all pure-logic and unit-tested
(`Tests/TalkieTests/NicheConfidenceTests.swift`, 8 tests green):

- `Niche.swift` — `NicheID` / `Niche` / `NicheTerm` models; `NicheTuning` constants;
  `NicheConfidence` (pure, time-passed-in): `raw = 3·userConfirmed + log2(1+occ) −
  2·rejections`, sigmoid + 45-day half-life decay, graduation at 0.50 OR one explicit
  confirmation. `biasHits` is intentionally **omitted** — `TextProcessor.biasAppliedTargets`
  only sees dictionary replacement rules, so it cannot observe a pure bias phrase;
  re-add only with a backend that exposes per-word confidence.
- `NicheTermGuard.swift` — the false-boost defense: never inject a term that *is* or
  is edit-distance-1 from a high-frequency common word (the "cube"→"kube" collision).
  Ships a compact built-in common-word set; swap in the full frequency table in Phase 1.
- `NicheVocabSnapshot.swift` — `Sendable` read surface; `biasPhrases(forNiche:limit:)`
  returns only graduated, guard-safe terms ranked by confidence.
- `NicheVocabStore.swift` — `@MainActor ObservableObject` mirroring `ContextGraphStore`;
  atomic JSON at `~/Library/Application Support/Talkie/niche/vocab.json`; `ingest` /
  `recordUserConfirmed` / `recordRejection`; time/floor-based pruning.

**TODO to ship Phase 0 (after gate zero passes):**
1. Instantiate `NicheVocabStore` next to the other stores (composition root).
2. Wire harvest: after a finalized dictation, `ingest(PhraseMiner.mine(transcript))`.
3. Wire bias: in `AppDelegate.beginDictation`, append
   `nicheVocab.snapshot().biasPhrases(forNiche: .default, limit: ~40)` to `bias`
   **before** the `Array(Set(bias)).prefix(180)` cap.
4. Wire `recordUserConfirmed` at the `DictionaryStore.addLearnedReplacement` call site.
5. Cold-start: one-time backfill from `HistoryStore` so it isn't a no-op for N sessions.
6. UI: "Detected vocabulary" `SettingsCard` in the Dictionary tab, chips tinted by
   `Theme.heat` (boosted vs greyed candidates).

## 6. Phase 1 — multi-niche detection

`NicheDetector` fusing app category + on-screen phrases + ContextGraph mentions +
`NLEmbedding` centroid cosine into a niche fingerprint with a confidence floor
(`nil` → no terms). Persist `Niche.centroid`. Full log-odds rareness scoring with a
shipped `background_unigrams.json`. Dictation-pill "active niche" chip.

## 7. Phase 2 — meetings + live pill

Thread niche terms through `MeetingRecorder` → `MultiLangStreamTranscriber`
per-lane; hysteresis-gated niche line on `MeetingPill` (clone of the subtopic line);
Dashboard "active niche" card.

## 8. Phase 3 — active confirm/reject + LLM niche-naming

Tappable borderline-term confirm in the HUD; `GraphLLMExtractor`/`Summarizer` to
*name* niches (additive, degrades to heuristics). Per-app niche scoping via
`AppProfile.vocabularyFilter`.

## 9. Phase 4 — backend robustness (contingency)

If gate zero shows biasing is weak/no-op on some locales: apply high-confidence
terms as post-hoc fuzzy corrections in `TextProcessor` so non-Apple backends and
weak-bias locales still benefit.

## 10. Open questions

180-cap is Talkie's number, not Apple's documented limit (the benchmark sweeps it);
detection is English-biased where this multilingual branch needs it most (lexical
signals carry, embedding goes additive-to-zero); the ~8 tuning constants need an
offline `HistoryStore`-replay harness to tune against, or the loop is unfalsifiable.

## 11. A3 — repo-aware jargon mining (implemented 2026-07-02)

Ships `RepoTermMiner` (pure) + `ProjectScanner` doc/git mining + a repo→corrector
channel in `ProjectIndexSnapshot.correctorTerms`, unioned into the endDictation
corrector term set (after the curated dictionary and the self-learned niche terms,
sharing A1's 300-term cap) when vibe coding is on. Terms come from CLAUDE.md /
README* / direct `docs/*.md` children plus `.git` branch names & reflog commit
subjects, read as plain files (no `Process`, ever). Notes where reality diverged
from the A3 spec (source wins, per playbook §7):

- **Spec line numbers had drifted.** The spec pointed at `AppDelegate.swift:788-792`
  for a `let nicheTerms` union; on the actual A1 base `nicheTerms` is already `var`
  and A1 already unions its graduated niche terms with a 300 cap. A3's repo union was
  added *after* A1's block (dictionary → niche → repo, one shared cap), not by editing
  A1's line. Located by symbol, not line.

- **Doc-source scope was tightened to DIRECT `docs/` children.** The sketch said
  `docs/*.md`; matching every markdown under a nested `docs/plans/**` tree both mined
  design prose (low signal, high false-positive pressure) and blew the scan budget.
  `isDocFile` now matches CLAUDE.md, README*, and markdown whose immediate parent dir
  is `docs`. Deep planning trees are intentionally excluded.

- **The "<20% scan-time growth" criterion holds on realistically-sized projects, not
  on a trivially tiny one.** Measured on this repo: a source-heavy tree (~48ms walk)
  grows ~7% with mining; a tiny tree (~3ms walk) grows ~100% because the *fixed*
  mining cost (read+parse ≤6 docs ≤4KB each + a few small git files, ~3ms, off-main,
  once per folder change) is a large fraction of a 3ms baseline. Absolute mining cost
  was minimized hard (byte-level tokenizer with a pre-filter so prose tokens never
  allocate a String; 4KB/6-file read caps; `.git` via direct reads at ~0.1ms). The
  criterion is met where it matters; the >20% case is only a near-zero baseline, not a
  real slowdown. If a strict ≤20%-on-any-repo bar is required, mining would need to be
  deferred/lazy (mine on first dictation into a project rather than during the folder
  scan) — flagged, not silently assumed.

- **False-positive defense is a THIRD gate.** Because repo terms are auto-harvested
  with zero human confirmation, `correctorTerms` adds `RepoTermMiner.isPhonetically
  Common` on top of the 4-letter floor and `NicheTermGuard.isSafeToInject`: a mined
  term whose phonetic skeleton is within edit-distance-1 of a common English word is
  dropped (`mining`↔`morning`, `Talkie`↔`talked`, `Coralate`↔`correlate`). This is
  what lets A1's `plainProse` corpus re-run with real mined terms loaded produce zero
  fixes (the package gate, `RepoTermMinerTests.testFalsePositiveCorpusWithMinedTerms
  ProducesZeroFixes`). Hex hashes/colour codes, ALL-CAPS acronyms, and git-structural
  words (feat/main/worktree/…) are filtered at extraction.
