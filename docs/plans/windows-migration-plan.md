# Talkie → Windows: The Committed Migration Plan

> **Status:** COMMITTED (pending the M0 gates and the open questions in §7).
> **Input:** [windows-port-possibility-map.md](windows-port-possibility-map.md) (breadth document, researched-but-unverified).
> **Method:** ultracode session 2026-07-02 — 6 code-verification agents against the real codebase, 16 adversarial
> web-research skeptics, 3 independent end-to-end rival plans, 3-judge comparative panel, 4-critic completeness
> pass (2 blockers found and fixed in this revision). The possibility map's claims were verified before anything
> was built on them; §8 records where reality disagreed.
> **Decision provenance:** the committed strategy ("Native Ears, One Brain") won 2 of 3 judge lenses and the
> aggregate score (172 vs 171 vs 149) against a shared-engine-daemon plan and a C#-beachhead plan; the
> judge-mandated grafts from the losing plans are folded in and marked ⤷graft.

---

## 1. Executive summary

**Talkie's moat is not the recognizer — it is the text-side brain wrapped around whatever recognizer each OS
offers.** That is not a slogan; it is what the code verification found: Apple's decode-time biasing is a proven
no-op, sherpa-onnx hotword biasing on Parakeet hallucinates ~20 % of the time (fix unmerged), the stock streaming
Zipformer cannot even emit the string `claude.md` — and meanwhile Talkie's *shipped, working* jargon lever
(NicheCorrector + dictionary post-processing) is pure, portable Swift. So the plan is:

> **Commit: keep Apple SpeechAnalyzer as the macOS recognizer; give Windows the best Windows-native engine
> (sherpa-onnx + Parakeet-TDT 0.6B v3 int8, CPU, finalize-after-release); extract the verified Foundation-only
> brain (~64 files) into a cross-platform Swift package (`TalkieCore`) that both OSes share; clear the jargon
> bar text-side (lexicon + NicheCorrector + a new SpokenFormNormalizer); and converge both OSes on an owned,
> fine-tuned Parakeet model later — adopted per-OS only when it beats that OS's incumbent-plus-text-stack on
> the TalkieBench harness.** Everything is gated by M0: recording Jann's jargon corpus and the first-ever Apple
> baseline WER number, which do not exist today.

**Week-one actions** (M0 only — nothing else starts before its gates): procure or borrow the target-class
Windows test laptop (i5-1235U/Ryzen 5, doubles as the M2 dev machine), record the jargon corpus (§7 Q2 — the
only task agents cannot do), run the three M0 spikes, and answer §7 Q3 (signing identity — do **not** buy a
cert before that decision; the reputation strategy depends on never churning the identity).

### Hard constraints (the plan is checked against these; cited as HC1–HC7 below)

1. **HC1 — Recognition quality is #1:** the plan must clear "as good or better than Apple on Jann's actual
   jargon" via the TalkieBench harness, or it is not worth doing.
2. **HC2 — The jargon moat is lexicon + corrector + (eventually) owned model.** Do not bet v1 on decode-time
   hotword biasing (verified unreliable everywhere today); do not foreclose it either.
3. **HC3 — The owned/fine-tuned model ships only after clearing the WER harness** against the incumbent
   baseline on the user's own audio.
4. **HC4 — Reuse what is real; never rewrite the moat twice.** Prefer dedupe over duplicate.
5. **HC5 — Local-first privacy is DNA.** Cloud STT opt-in/confidence-gated only; the PrivacyWall
   (`requiresNetwork`) survives on Windows as a mechanical guarantee.
6. **HC6 — Plan for Windows' mirrored walls:** UIPI silently swallows injection into elevated windows;
   SmartScreen warns until reputation accrues.
7. **HC7 — The UI shell is low-stakes** and must never gate recognition work.

### Why not the possibility map's default (shared engine as daemon on both OSes)?

It lost on engineering risk, not ambition: it routes *all* new code — engine host, WASAPI/COM edges, injector,
a novel PCM-over-stdio transport — through the still-caveated Swift-on-Windows toolchain while simultaneously
re-validating the mac recognition stack (multilingual self-consistency, German, latency, battery) that is
verified working today, to chase decode-time biasing that is verifiably broken on every engine. We keep its two
best ideas (⤷graft: the separately-versioned "recognition brain" artifact; opt-in shadow-mode dual transcription
on mac) without betting the port on them. The "one engine" dream is deferred, not killed: the fine-tuned model
is the convergence path, entered only through the WER gate (HC3).

### The dictation UX commitment

Finalize-after-release push-to-talk, no live partials in v1. Every current local open-model dictation utility
(Chirp, Handy, OpenWhispr, Whispering) finalizes after stop — none ship live local partials — and Wispr Flow,
the cloud market leader, ships the same UX. (The exceptions that do stream — Dragon, Windows Voice Access — are
respectively legacy-pro and jargon-weak; neither sets the bar for this ICP.) Live partials on the local stack
today would force either a jargon-incapable engine or a 20 %-hallucination decoder; the HUD level meter + fast
finalization is the honest, competitive choice. A streaming preview layer is a designed, additive M4+ upgrade.

### What Windows v1 does NOT do — and exactly when each arrives (see §2b, the bring-up roadmap)

Every cut has a committed, adversarially-verified bring-up design in §2b. The v1 statement is honest scoping,
not a roadmap hole:

- **No LLM cleanup/style tier in v1** — output is verbatim-ish (SpokenFormNormalizer + dictionary +
  NicheCorrector still run). **Arrives: wave v1.1 as B1** (llama.cpp + Qwen3-1.7B behind the Summarizer seam;
  also delivers feature 20's Tier B to pre-Apple-Intelligence Macs).
- **No voice commands/macros in v1** — **except the macro slice, which is pulled INTO M2/M3** (B2 slice 1 needs
  only the injector). Selection-based commands arrive v1.1 (B2); RewriteIntent flips on when B1 lands.
- **No meetings / system-audio capture in v1** — capture spike runs during M3's soak; the wave ships ~4–5 wks
  after v1 public (B3).
- **No dashboard in v1 — briefly:** the history/stats/streak dashboard (B4 Stage A) is cheap enough to ride the
  M3 window; semantic search (B4 Stage B) is v1.1/v1.2. Dictations land in the shared HistoryStore from day one.
- **No live partials in v1** — arrives v1.1 as B5, a single-engine display-only preview (no second model).
- **No GPU/NPU path for ASR — permanently, by posture (B6/D20)**; GPU (Vulkan) arrives only for the B1 LLM
  tier; NPU is trigger-gated with no date.

---

## 2. Spike-gated phase plan

Effort assumes one developer + AI-agent workforce. **Totals are the gates-all-green path (~23 wks); priced
fallback branches are listed at each gate.** Phases are gates, not dates; nothing advances past a red gate.
(These M-numbers are the Windows-migration track — distinct from the Context-Graph roadmap milestones in
[00-ROADMAP.md](00-ROADMAP.md).)

**The comparator, defined once (used by every quality gate):** both sides get the identical shared text stack.
"Apple+stack" = the M0 Apple hypotheses re-scored through SpokenFormNormalizer + dictionary + NicheCorrector via
`talkie-bench --hypotheses`; "Windows+stack" = Parakeet output through the same stack. Gates compare
**Windows+stack ≥ Apple+stack** — never Windows-with-corrector vs raw Apple, which would be a weaker bar than
the shipping mac product. Additionally a **per-term floor**: no term where Apple+stack recall is > 50 % may sit
at 0 % on Windows+stack.

### M0 — Corpus, baseline, and the three kill-switches (~2 wks; corpus recording is Jann-hours)

The whole plan hinges on numbers that do not exist yet. **The jargon corpus was never recorded and no Apple
baseline WER was ever measured** — the famous "biasing is a no-op" verdict rests on an in-app A/B, not a corpus
run. TalkieBench itself is verified working today (builds in ~7 s, selftest passes — 17 checks, verified
2026-07-02 — end-to-end bias run reproduced on macOS 26.5).

- **Entry:** target-class Windows laptop procured/borrowed (i5-1235U/Ryzen 5 class, 8–16 GB).
- **Work:**
  1. **Record `jargon-v1`** per [docs/bench/JARGON_CORPUS.md](../bench/JARGON_CORPUS.md) (60–120 clips incl. the
     code-switch subset, built-in mic + AirPods, EN + DE) into `talkie-brain/research/corpora/jargon-v1/`.
  2. **Apple baseline:** WER + per-term recall via `talkie-bench --corpus … --terms … --json baseline-apple.json`,
     published to talkie-brain. Retroactively also produces the reproducible gate-zero record for the
     contextualStrings no-op.
  3. **Seed the lexicon** (the production NicheVocabStore is literally empty): load jargon-v1's terms file into
     NicheVocabStore/DictionaryStore (minutes, per JARGON_CORPUS.md §3) — G2 is unmeasurable otherwise.
  4. **Throwaway SpokenFormNormalizer prototype** (scripted ITN rules for the corpus terms) used only for
     `--hypotheses` scoring — so G2 measures the text stack M1 will build, without M1 existing yet.
  5. **Engine quality probe:** decode the same clips (incl. the code-switch subset) with Parakeet-TDT 0.6B v3
     int8 (sherpa-onnx, greedy, `--dither=0.00003`) on the Windows laptop; score on mac via `--hypotheses`.
     **Model provenance:** the int8 bundle comes from k2-fsa releases or is converted from
     `nvidia/parakeet-tdt-0.6b-v3` directly — third-party conversions (e.g. NexaAI) carry NC licenses and are
     banned.
  6. **Latency probe** on the target laptop, plugged in AND on battery: cold-load, RAM, finalize latency for
     5 s/**10 s**/15 s/30 s utterances. Field RTF spreads 0.03–0.33 across CPUs — the budget is per-device.
  7. **Swift-on-Windows compile spike (1 wk):** extract the candidate `TalkieCore` file set, compile + run the
     scorer selftest on a `windows-latest` GitHub runner via `compnerd/gha-setup-swift`.
  8. **Reproduce and park the hotword bug** (sherpa-onnx issue #3267) as documented upside; record a
     BiasingProbe bench config for later re-runs. ⤷graft
- **Exit gates (quantified ⤷graft):**
  - **G1:** corpus + Apple baseline (raw AND Apple+stack) recorded and published.
  - **G2:** raw Parakeet WER within **20 % relative** of raw Apple on jargon-v1, **AND Windows+stack jargon
    term-recall ≥ Apple+stack** (comparator above), incl. the code-switch subset scored.
  - **G3:** 10 s utterance finalizes in **≤ 1.5 s** on the target laptop; cold load ≤ 3 s or hidden by
    pre-warm; RSS ≤ 1.5 GB.
  - **G4:** `TalkieCore` compiles + scorer selftest passes on Windows CI with < 5 % of core LOC modified.
- **Go/No-go:**
  - G2 red → swap Moonshine v2 medium (MIT) into the identical harness (**+1 wk**); both miss → pull the
    TTS-only fine-tune forward (**+2–3 wks**, needs zero consented audio ⤷graft) — run in parallel with M1,
    which is not gated on G2 (see below). Exit artifact either way: a **named, bounded per-term rule-gap
    list**, not a vibe. ⤷graft
  - G3 red → fallback chain: smaller/faster model (Moonshine already staged) → raise the stated hardware floor
    and route below-floor CPUs to the degraded tier (M3) → last, revisit finalize-UX expectations.
  - G4 red → **priced fallback: contracts + C# OS edges** (the beachhead shape, **+4–6 wks**, golden vectors as
    the rewrite spec ⤷graft) — cheaper and better-evidenced than a Rust core rewrite.
- **Top risk:** Parakeet+stack misses the jargon bar — which is exactly what M0 exists to discover for the cost
  of a corpus and two spikes.
- **macOS win captured:** the corpus + the first Apple baseline numbers — the measurement foundation all future
  recognition work on both OSes was missing.

### M1 — TalkieCore extraction + seam re-typing (~4 wks, agent-heavy)

- **Entry:** **G1 + G4 green.** (Deliberately NOT gated on G2/G3: M1 is justified by mac alone — §6 lists it as
  pure mac wins — and D3 keeps Apple default regardless of any Windows engine outcome. G2/G3 gate M2 entry,
  where the Windows engine bet is actually placed.)
- **Work:**
  - Carve the verified Foundation-only brain into a `TalkieCore` SwiftPM target
    (FoundationEssentials-pure: **no SwiftNIO, no Combine, no os.log**), with the per-folder exclusions the
    census demands: `Commands/` **minus AXSelection.swift** (mac edge), `ContextGraph/`, `Niche/` **minus
    BiasABProbe/BiasABTestView** (Speech/SwiftUI, stay app-side), `Export/`, `Profiles/`, `Search/` = SearchEngine
    only (**SemanticIndex behind an embedding seam; semantic search is absent on Windows v1**), `SentenceFlow`,
    `StreamingCleanup`, all stores, the TalkieBench scorer — plus the promoted pure policy cores:
    `FarEndWatchdog`, `AudioDevices.resolveSwap`, the InsertionVerifier decision core, the rolling-PCM-ring
    policy, and **the LearningEngine diff/decision core** (CorrectionExtractor — the AX field-watcher half stays
    a mac edge; Windows gets its UIA counterpart in M3). The 3 URLSession-using files are **excluded from the
    Windows default build target** (not `#if canImport`-guarded — FoundationNetworking exists on Windows and
    would silently compile network code in).
  - **Re-type the recognizer seam** (the honest new work — today's `TranscriptionBackend` protocol has zero call
    sites and leaks `AnalyzerInput`/`AVAudioFormat`): `TranscriptionBackend` v2 over neutral
    `PCMChunk`/`AudioFormatSpec`; absorb the four concrete methods the live path actually uses — `warmUp`,
    `setUpdateHandler`, `finishSessionDetailed`, and `transcribeCandidates` as an **optional
    `CandidateTranscribing` capability** ⤷graft. **SherpaBackend will NOT adopt CandidateTranscribing** — the
    per-locale re-decode is Apple-specific (one model per locale); Parakeet v3 is a single natively multilingual
    model (see M2 gate + R14). Add a `BackendResolver` in `Backends/`.
  - Adopt v2 in the mac live path **behavior-preservingly**; **enforce the Summarizer seam**
    (CleanupEngine/MeetingSummarizer/ContextSummary stop calling FoundationModels directly). ⤷graft
  - Land **SpokenFormNormalizer** (pure Swift ITN: "claude dot md"→`claude.md`, "R T K"→`RTK`,
    "A X U I element"→`AXUIElement`), replacing the M0 prototype, seeded from DictionaryStore + NicheVocabStore.
  - **Golden vectors in CI** (`corrector-golden.jsonl`, `normalizer-golden.jsonl`) pinning
    NicheCorrector/SpokenFormNormalizer/normalizer semantics — and doubling as the rewrite spec if the fallback
    is ever exercised. ⤷graft **Public-repo goldens use sanitized/representative terms; personal-term goldens
    live in talkie-brain** (per JARGON_CORPUS.md §3 privacy split).
  - **Where things land:** `Sources/TalkieCore/` (new SwiftPM target, this repo); OS edges stay/land in
    `Sources/Talkie/…` (mac) and `Sources/TalkieWin/…` (M2); doctrine doc at `docs/contracts/injection.md`;
    goldens under `Tests/TalkieCoreTests/goldens/`.
- **Exit gates:**
  - Mac runs entirely on `TranscriptionBackend` v2 with a **statistically honest A/B**: pre-refactor baseline
    run N ≥ 3 times on a pinned macOS/model version to establish the noise band; post-refactor WER delta within
    ±1 σ of that band; **byte-identical golden-vector output for every deterministic stage**; p50/p95 finalize
    latency delta ≤ 50 ms over the same corpus (incl. the multilingual `transcribeCandidates` path).
  - Windows CI builds TalkieCore + scorer green on every PR **within a stated wall-time budget** (set it here,
    under the known 10–20× Windows SPM slowdown; budget overruns are a red gate, not an annoyance to absorb).
  - SpokenFormNormalizer shows measured jargon-recall gains on jargon-v1 **on Apple's own output** (this number
    becomes the Apple+stack side of every later comparator).
- **Go/No-go:** a red A/B blocks merge and iterates — no strategic fallback needed; nothing downstream starts.
- **Top risk:** Swift 6 strict-concurrency friction + slow Windows SPM builds grinding CI — mitigated by a small
  module graph, caching, mac-side debugging (Windows lldb is the toolchain's weak point), and the CI budget gate.
- **macOS win:** Feature 20's pluggable-backend seam becomes *real* (call sites!); SpokenFormNormalizer improves
  "claude dot md"-class errors on the shipping mac app immediately, before any engine work.

### M2 — Windows dictation v1, private beta (~6 wks — the OS-edge fork is the honest bulk)

- **Entry:** M1 green **+ G2/G3 green** (the Windows engine bet is placed here) + signing identity decided
  (§7 Q3) and cert acquired.
- **Work:** the Windows OS edges, all Swift over direct WinSDK C imports (the Arc-proven path; swift-winrt not
  needed for a headless shell):
  - `WinAudio`: WASAPI shared-mode mic (exclusive mode banned — must coexist with Zoom/Teams),
    `IMMNotificationClient` device-change events feeding the ported `resolveSwap` policy; the 90 s PCM ring
    reinstantiated over `PCMChunk` in TalkieCore — **ring capture is unconditional whenever ClipVault consent
    is on, and reads are non-destructive `snapshot()`** (see M3 blocker fix; the mac ring gets the same change).
  - `SherpaBackend`: sherpa-onnx C API in-process, Parakeet-TDT v3 int8, greedy, pre-warmed at launch; hotwords
    compiled but **default-off** behind `experimental.hotwords`. Multilingual: Parakeet v3 decodes 25 languages
    natively in one model — no per-locale re-decode, no CandidateTranscribing (R14).
  - **`SherpaBackend` also built for macOS as a dev-only target** ⤷graft-fix: this is what makes the shadow-mode
    dev toggle runnable in M2 (Apple vs Parakeet diffed in-memory on real dictation, nothing persisted) *and*
    pre-validates the M4 mac fallback runtime. Budgeted here, not assumed.
  - `WinTextInjector` per the **written injection doctrine** (`docs/contracts/injection.md` ⤷graft): Tier P
    clipboard-paste (Ctrl+V via SendInput) with the mac-hardened semantics translated —
    `GetClipboardSequenceNumber` as the changeCount guard, generation counter,
    `ExcludeClipboardContentFromMonitorProcessing` transient marker, ~120 ms delayed restore, leave-on-clipboard
    + toast as the guaranteed floor; Tier T `SendInput` KEYEVENTF_UNICODE typing; **Shift+Insert per-app
    variant** for Electron-IDE terminals (Wispr Flow's shipped answer). **The inherited law: never gate
    injection on focus detection** — focus is only a clipboard-restore confidence signal. **UIPI
    detect-and-warn** (HC6): elevation check on the foreground window → skip injection, leave on clipboard,
    honest toast.
  - `WinHotkeys`: `WH_KEYBOARD_LL` push-to-talk (key-up + suppression) with a **RegisterHotKey fallback switch**
    for AV-paranoid environments; `WinTray` (`Shell_NotifyIcon` + the Win11 "drag the parrot to the taskbar"
    onboarding step); HKCU Run-key autostart; named-mutex single instance.
  - Shell: headless-first — tray + minimal Win32 layered-window HUD (level meter + state) + a WebView2 settings
    window over a **local static bundle** (no network; WebView2 is a system component, not Electron). Installer
    performs a WebView2-runtime presence check with Evergreen bootstrap for Win10 (D13).
  - Packaging: **signed Inno Setup per-user installer, distributed to the beta via GitHub pre-release with
    published SHA256s** (winget publication is M3 — it doesn't exist as a channel yet); optional per-machine
    Program Files install keeps the future `uiAccess=true` door open (elevated-window dictation is only ever
    possible unpackaged — MSIX cannot do it).
  - **CI binary scan** asserting zero network/socket/WinHTTP imports in the default Windows build — the
    mechanical PrivacyWall (HC5), same guarantee as mac's zero-network grep. ⤷graft
- **Exit gates:**
  - Dictation verified into a **10-app matrix** ⤷graft (Claude Desktop, VS Code, Windows Terminal, Chrome,
    Slack, Cursor, PowerShell/conhost, Notepad, Word or Outlook, one **elevated** terminal → must produce the
    UIPI warn path).
  - **Windows+stack term-recall ≥ Apple+stack** on jargon-v1 (the comparator; per-term floor applies), incl.
    the code-switch subset — **this replaces the unimplementable "self-consistency check ported" gate**; the
    runtime language check is Apple-specific and N/A on Windows (R14).
  - **Windows-recorded validation subset:** ~20–30 clips re-recorded on the target laptop's built-in mic + one
    common headset per the same corpus protocol, scored via `--hypotheses` — closing the only unmeasured link
    (all other gates decode mac-recorded audio; capture-path differences — mic arrays, vendor DSP, WASAPI
    resampling — would otherwise never be inside any gate).
  - Zero clipboard-loss defects across the beta cohort (§7 Q6 names it) over two consecutive weeks.
- **Go/No-go:** recall gate red → re-enter the M0 fallback ladder (Moonshine → TTS-tune-forward); injection
  matrix red → add per-app rules until green before any public step.
- **Top risk:** Electron/terminal injection edge cases — the mac autopaste scar replayed on Win32. Mitigated by
  the focus-gate-free design from day one, per-app rules, and the leave-on-clipboard floor.
- **macOS win:** engine-tagged LearningEngine rule packs ⤷graft (rules mined against Apple's error shape never
  regress Parakeet output, and vice versa); `docs/contracts/injection.md` becomes the spec any future mac
  TextInjector change merges against; the shadow-mode dev toggle starts accumulating engine-vs-Apple evidence.

### M3 — Public release, reputation, and the data flywheel (~4 wks)

- **Entry:** M2 green.
- **Work:**
  - Sparse "external location" package added for identity (toasts, StartupTask, per-app mic toggle) — **not**
    because a container would break the injector (verified: runFullTrust MSIX does *not* break LL
    hooks/SendInput/clipboard) but because **`uiAccess` is unsupported in MSIX** (would permanently close the
    elevated-window door) and unsigned-MSIX behavior is harsher; winget publication + GitHub releases with
    published SHA256s; honest onboarding copy ("Windows will warn until we've earned reputation — here's why").
  - **InsertionVerifier wired on both OSes** as a fail-open UIA/AX read-back *confidence signal* (never a gate).
  - **`WinFieldWatcher`** — the UIA counterpart of the mac AX field watcher, feeding the shared
    CorrectionExtractor core: without it there is no Windows correction mining, no engine-tagged rule packs on
    Windows, and nothing for ClipVault to reconcile against (same Electron/UIA caveats as R13; fail-soft).
  - **ClipVault** — the opt-in consented audio capture, on BOTH OSes, with the **blocker fixes**:
    (1) ring capture becomes **unconditional when consent is on** (`bufferAudio: multiLang || clipVaultConsented`
    — today the ring exists only in multilingual mode, so single-language users would capture nothing);
    (2) the multilingual path's destructive `drain()` is replaced by / preceded by a non-destructive
    `snapshot()` so the clip survives `transcribeCandidates` (today the ring is emptied *before* insertion);
    (3) memory cost of the always-on 90 s ring (~a few MB of 16 kHz float) documented. Persist at insertion
    time keyed by insertion ID; reconcile when the (up to ~60 s late) correction lands; local-only store,
    visible ledger in Settings, one-click purge.
  - **Diagnostics for the crash gate, zero-network:** Windows Error Reporting LocalDumps (registry key,
    local-only) + a local session counter in the existing stats store, surfaced in Settings; the named beta
    cohort submits dumps manually/opt-in. No telemetry — HC5 is not negotiable for a gate metric.
  - **Degraded pre-AVX2 tier** ⤷graft: on CPUs without AVX2/FMA3, offer OS speech via **SAPI 5.4 (legacy COM,
    reachable over C imports — deliberately not the WinRT `Windows.Media.SpeechRecognition` surface, which
    would reintroduce the swift-winrt dependency M2 avoids)** feeding the same text pipeline, explicitly
    labeled degraded. Note: on Win11-supported hardware AVX2 is universal — this tier only matters if Win10 is
    in scope (D13).
  - **BiasingProbe** becomes a standing bench job: re-test sherpa-onnx hotwords automatically on every release
    past PR #3657; the flag flips only on a clean win over corrector-only. ⤷graft
- **Exit gates:**
  - Public release live on winget; SmartScreen behavior documented honestly.
  - ClipVault operational on both OSes with the consent ledger; **clip count is a tracked metric with a target
    (~200 correction-reconciled clips), not a hard gate** — a consent veto or slow accrual re-scopes M4 to
    TTS-only (recorded decision), it does not stall the plan (fixes the veto contradiction with §7 Q1).
  - Zero unexplained crash dumps across ≥ N user-days on the beta fleet (from the LocalDumps mechanism above).
- **Go/No-go:** reputation/crash gates red → hold public release on the private cohort; nothing else blocks.
- **Top risk:** EDR/SmartScreen misclassification — an unknown publisher with an LL keyboard hook + clipboard
  automation is keylogger-shaped. Mitigations: one stable identity never churned, winget volume, the
  RegisterHotKey fallback mode, open-source auditability. Residual risk accepted.
- **macOS win:** InsertionVerifier finally earns its keep against the recurring paste-bug class; ClipVault on
  mac is the *only* path to fine-tune data in Jann's real voice.

### M4 — The owned model: shared asset, per-OS gated (~7 wks; training iterates in the background)

- **Entry:** **R6 fine-tune round-trip pilot green** (see §5/R6) + ClipVault operational **or** a recorded
  TTS-only decision; both incumbents' Apple+stack / Windows+stack baselines on file (M0/M2).
- **Work:** NeMo fine-tune (adapter/LoRA-style where supported — adapters keep the tokenizer unchanged, so the
  sherpa-onnx runtime stack needs zero changes) of Parakeet-TDT v3 on provenance-tracked streams:
  - (a) **TTS synthesis of the full lexicon** in LLM-generated carrier phrases using ONLY the safe-list —
    Kokoro-82M (Apache-2.0), Piper `en_US-libritts_r` (CC-BY-4.0, ~904 speakers), `en_US-ljspeech` (public
    domain); ElevenLabs / Azure (incl. Edge-TTS) / Coqui-XTTS / macOS-`say` / Piper-lessac are BANNED and
    enforced in code via the per-clip provenance manifest; augmentation: speed-perturb 0.9–1.1, additive noise
    SNR 10–25 dB, room IR.
  - (b) ClipVault consented real clips (if the flywheel ran); (c) mined correction pairs as carrier templates.
  - **One recipe, stated once:** the *jargon* audio may be TTS-majority (the maritime 75 %-synthetic precedent);
    the overall ≈ 1:2 synthetic:real ratio is achieved by padding with LibriSpeech + own-dictation replay — so
    scarce ClipVault data never blocks M4 (this is R7's mitigation, now consistent with the recipe).
  - **Training environment (decided, was a gap):** rented single-GPU Linux box (RTX 4090 / A100 spot; ~$5–30
    per run, < 1 GPU-day for 1–10 h of audio). TTS/LibriSpeech-only runs may use any cloud GPU freely.
    **Runs that include ClipVault clips require the §7 Q1 consent to explicitly cover "clips used for training
    on rented infrastructure (encrypted transfer, deleted after the run)" — or they run only on Jann-controlled
    hardware.** Runner-up: local-only training on a purchased GPU box (reversal cost: money + time, zero legal).
  - Export **ONNX int8 → sherpa-onnx** (Windows; scripts currently need `torch==2.8.0` pinned — R6) and
    **CoreML** (mac, FluidAudio-style per [20-pluggable-backend.md](20-pluggable-backend.md) §4.5).
  - Ship the model + lexicon + rule packs as a **separately versioned "recognition brain" artifact** ⤷graft:
    on mac over the existing TalkieUpdater dev channel (routing intelligence updates around the
    notarization-blocked shell); **on Windows via an in-app brain updater consuming the same GitHub-releases
    artifact feed** (explicit opt-in check — the TalkieUpdater pattern, not a new mechanism; without this the
    "separately versioned" point would be dead on the OS it matters most for).
- **Exit gates (HC3, per-OS):**
  - Windows: tuned ONNX beats **base-Parakeet+stack** on jargon-v1 term-recall, **zero regression** on a
    general-English control set → ships as default Windows model.
  - Mac: tuned CoreML beats **Apple+stack** on jargon-v1 AND passes the mac-flip checklist — general WER,
    latency, battery, multilingual behavior on-device ⤷graft → ships as a *selectable* backend, Apple stays the
    fallback. If the CoreML conversion disappoints, the named fallback runtime is **sherpa-onnx in-process on
    mac** — already built and validated as the M2 dev-only shadow target. ⤷graft
  - Either gate failing → that OS keeps its incumbent; nothing ships; the plan remains whole (the corrector
    stack already cleared the bar at M0/M2).
- **Top risk:** single-speaker overfit / TTS-voice domain gap — mitigated by the 904-speaker TTS spread,
  held-out clip splits, and the general-English regression gate making overfit self-disqualifying.
- **macOS win:** **the payoff** — the first mac recognizer that actually knows `claude.md`, the upgrade Apple
  structurally cannot deliver, shipped as an owned, versioned, cross-OS asset that was never on the port's
  critical path.

## 2b. Bring-up roadmap — making the v1 cuts work

> Designed 2026-07-03 (6 workstream designers + 3 adversarial verifiers; 9 agents). Sequencing law: **nothing
> here touches the M0–M3 critical path** (HC7 discipline). Pull-ins happen only where they ride deliverables
> M2/M3 already build. Verifier verdicts: B3-capture and B4-embedding **SUPPORTED (high)**; B5's license
> question **SUPPORTED (high)** — the committed preview path needs no NVIDIA-OML weights at all; B1's latency
> claim **UNRESOLVED** → its gates were tightened as recorded below.

| # | Capability | Committed design (one line) | Slot | Effort | Headline gates |
|---|------------|-----------------------------|------|--------|----------------|
| B1 | LLM cleanup/style (+ old-Mac Tier B) | llama.cpp (vendored pinned, MIT) + **Qwen3-1.7B Q4_K_M** (Apache-2.0, ~1.1 GB) as `LocalLLMSummarizer` behind the M1-enforced Summarizer seam; ModelManager opt-in download (HC5); reuses CleanupEngine's prompt strings verbatim | mac-first during M3; Windows flip = **v1.1** | ~5 wk | G-C1…C5 below (verifier-adjusted) |
| B2 | Voice commands/macros | Three slices: **macros pull-in (~1 wk, M2/M3** — MacroIntent needs only the injector); `WinSelectionEdge` (UIA `TextPattern::GetSelection` → clipboard-probe fallback with terminal-category ban → paste-over-selection replace) in **v1.1**; RewriteIntent flips on when B1 is green | macros M2/M3; selection v1.1 | 4–6 wk staged | read OK in ≥6/8 matrix apps; **0 probe firings in terminal apps**; 0 command false-positives over ≥200 dictations |
| B3 | Meetings / system-audio | WASAPI process-loopback **EXCLUDE_TARGET_PROCESS_TREE(self)** — verified directly expressible and endpoint-independent (MS docs + ApplicationLoopback sample; floor build 20348, runtime probe + mic-only degrade); Swift COM vtable handler (C-shim fallback); **ONE shared Parakeet instance, two logical streams** (RAM stays ~1.2 GB, dictation preempts meeting chunks); `IAudioSessionManager2` detect-and-offer; ships **calendar-less** (NullProvider; ICS later; Graph only ever opt-in) | 1-wk spike in M3 soak; wave ~4 wk post-v1 | ~5 wk | exclude-self proof (Talkie's own sound absent); Me/Them ≥ 99 % on scripted call; RSS ≤ 1.6 GB; loopback-path WER ≤ 15 % rel. of direct |
| B4 | Dashboard + semantic search | **Stage A (pullable into M3):** WebView2 local dashboard (history/stats/streak, vendored JS, read-only postMessage bridge). **Stage B:** `multilingual-e5-small` int8 (MIT, ~118 MB, 384-d, DE+EN) on **both OSes** behind an `EmbeddingProvider` seam via the already-shipped ONNX Runtime; first **persisted** index (vectors.bin, embedderID-keyed rebuild); talkie-mcp gets a Windows build sharing it | A in M3; B v1.1/v1.2 | 6–8 wk staged | retrieval bench: beats NLEmbedding+lexical (EN) AND keyword-only (DE), else DE stays keyword-only; tokenizer goldens byte-identical; embed p95 ≤ 50 ms |
| B5 | Live partials | **Single-engine IncrementalPreview — the two-model premise is dead:** the already-resident Parakeet decodes silero-VAD-closed segments (≥600 ms pause, 6 s force-cut) on one lowest-priority thread during capture; volatile dimmed tail-anchored line in the HUD; cancelled at key-release; **the v1 finalize path is untouched → display-only, zero WER risk (HC1), zero new resident weights** (silero-VAD: MIT, ~2 MB, bundled) | v1.1 | 2–3 wk | byte-identical finals preview-on/off (proven, not asserted); CPU +≤ 20 pp during capture; finalize p95 delta ≤ 50 ms; RSS +≤ 200 MB; first text ≤ 2.5 s |
| B6 | GPU/NPU | **Posture:** CPU-only ASR permanently (no onnxruntime-gpu ever — ~2 GB pinned payload for a minority's 1–2 s); **Vulkan-only GPU, only for the B1 LLM tier** (llama.cpp official backend, probe → offload → silent CPU fallback; mac Tier B gets Metal from the same dependency); **NPU trigger-gated** (T1–T4 in `docs/plans/22-gpu-npu-posture.md`), no date | posture doc M1; Vulkan rides B1 | ~1–1.5 wk | Vulkan ≥ 3× CPU tok/s dGPU / ≥ 1.5× iGPU else default-off; CPU-vs-GPU output semantically equivalent; installer scan: zero CUDA/QNN DLLs |

### Waves

- **Pull-ins (inside M2/M3, zero critical-path risk):** B2 macro slice (+ Macros page in the settings bundle);
  B4 Stage A dashboard; B6 posture doc; B3 capture spike (runs during M3's reputation-soak weeks); B1 starts
  mac-first (old-Mac Tier B justifies it alone).
- **Wave v1.1 (first fast-follow, ~6–8 wks of parallelizable work after v1 public):** B1 Windows flip,
  B5 preview, B2 selection slices. When B1 is green it also unlocks: B2 RewriteIntent, B4's Brief card, and the
  mac Tier-B opt-in.
- **Wave v1.2/v2:** B3 meetings, B4 Stage B search + talkie-mcp-on-Windows, B6 Vulkan increment.
- **Standing/named-deferred:** Nemotron streaming preview as a 16 GB+ opt-in (V2+ only; NVIDIA Open Model
  License **cleared** for commercial bundling — perpetual royalty-free incl. distribution, NOTICE + Agreement
  copy required; recorded caveats: guardrail-bypass auto-termination, litigation-termination,
  indemnify-NVIDIA); hotword biasing (BiasingProbe decides, unchanged); cloud keyterm opt-in tier behind
  PrivacyWall (designed, unscheduled); multi-speaker diarization (deferred on both OSes alike).

### B1 gates (verifier-adjusted — the latency claim was UNRESOLVED as originally stated)

The skeptic's finding: the original tok/s anchor was a 12-core desktop CPU; the honest numbers (LFM2 tech
report, bandwidth-scaled) are ~22–26 tok/s on a dual-channel i5-1235U-class laptop but **~11–13 tok/s on
single-channel 1×8 GB machines** — the modal cheap Windows laptop. Committed adjustments:

- **G-C1 compliance** (CleanupBench-300: 150 EN/100 DE/50 code-switch, all levels+styles): zero translation
  flips, zero refusal insertions, zero `<think>`-leaks, content-word recall ≥ 97 % (runtime guard reverts to
  raw per-dictation).
- **G-C2 parity:** blinded judge prefers-or-ties LocalLLM vs mac FoundationModels on ≥ 60 % of identical
  transcripts and vs raw on ≥ 85 %; a red DE subset flips the default to SmolLM3-3B (one bench rerun) before
  any user sees it.
- **G-C3 latency** with **output-token caps committed for ALL levels/styles** (≤ ~60 output tokens p50 for a
  60-word dictation — without caps the math fails even in the best case): cleanup adds p50 ≤ 3 s / p95 ≤ 6 s
  warm on the reference laptop **on battery**; the gate matrix includes a **single-channel 1×8 GB
  configuration**, and a **runtime memory-bandwidth/channel probe** feeds the auto Tier-A-skip hardware floor.
- **G-C4 RAM coexistence:** combined ASR+LLM peak ≤ 3.4 GB; sherpa finalize RTF regression < 10 % with the LLM
  resident; **warm-hit-rate under memory pressure tested** (dictate → 10 min browser load → dictate; mmap
  re-page-in ≤ the 4 s cold budget on SATA-class storage).
- **G-C5 HC5:** CI network scan stays zero-import; weights only via ModelManager opt-in, SHA256-pinned,
  `requiresNetwork == false` after.

Model decision (D15): default **Qwen3-1.7B Q4_K_M** (thinking hard-disabled — we own the prompt template;
strip-guard + bench assertion); runner-up default **SmolLM3-3B** (Apache, DE-instruct-tuned) one manifest entry
away; "better" opt-in **Qwen3-4B-Instruct-2507** (≥ 16 GB machines). Rejected on license: LFM2 ($10 M revenue
cap), Gemma-3 (downstream-obligation terms). Runtime runner-up onnxruntime-genai rejected on ORT
version-coupling with sherpa-onnx in one process + int4-CPU slowness reports; reversal ~1–2 wks behind the
unchanged Summarizer seam.

---

## 3. Target architecture

### The seam

```
┌────────────────────────── SHARED: TalkieCore (Swift, FoundationEssentials-pure) ─────────────────────────┐
│ Niche/ (NicheCorrector, NicheVocabStore)   SpokenFormNormalizer (NEW)   SentenceFlow   StreamingCleanup  │
│ Commands/ᵃ + CommandRouter   ContextGraph/   Export/   Profiles/ (per-app rules)   Search/ᵃ   stores     │
│ TalkieBench scorer (WER/TermRecall/normalizer)   CorrectionExtractor (learning decision core)            │
│ policy cores: FarEndWatchdog · AudioDevices.resolveSwap · InsertionVerifier core · PCM-ring policy       │
│ seams: TranscriptionBackend v2 (PCMChunk/AudioFormatSpec; CandidateTranscribing optional) · Summarizer   │
│        · NoteDestination · CommandIntent · PrivacyWall (requiresNetwork; zero-network default builds)    │
│ ᵃ minus OS-edge files: Commands/AXSelection (mac), Search/SemanticIndex (embedding seam, no Win v1 shim) │
└───────────────────────────────────────────────────────────────────────────────────────────────────────────┘
        ▲ macOS edges (Swift, existing)                  ▲ Windows edges (Swift over WinSDK C imports)
  AppleSpeechBackend (SpeechAnalyzer — stays default)   SherpaBackend (sherpa-onnx C API, Parakeet v3 int8)
  SherpaBackend-mac (M2 dev-only: shadow + M4 fallback) WinAudio (WASAPI shared-mode; loopback seam stubbed)
  AudioCapture/SystemAudioCapture (AVF/CoreAudio)       WinTextInjector (Ctrl+V/SendInput doctrine + UIPI probe)
  TextInjector (⌘V doctrine) · AX field watcher         WinHotkeys (WH_KEYBOARD_LL + RegisterHotKey fallback)
  HotKeyMonitor (CGEventTap)                            WinFieldWatcher (UIA, M3) · WinTray · Win32 HUD
  SwiftUI app + HUD (untouched)                         WebView2 local settings · DPAPI shim
  MacParakeetBackend (M4, CoreML, gated)                NL/FoundationModels/EventKit → no-op shims (v1)
```

**Language:** Swift everywhere (core and both edges); C# edges are the priced M0 fallback, golden vectors are
the spec. **Recognizer host:** in-process library — no daemon, no sockets, no firewall prompts (matches the
repo's own precedent: TalkieMCP is a stdio child process, not a network service). Pre-designed escape hatch: if
the ~1.2 GB engine ever needs crash isolation, `SherpaBackend` moves behind the same protocol into a stdio child
process, zero call-site changes.

### Data flow (diagram-ready)

The text brain is identical on both OSes **except the Summarizer seam (LLM cleanup), which is a no-op on
Windows v1**, and the learn-side field watcher, which is per-OS (AX / UIA).

```
hotkey ▶ WinHotkeys/HotKeyMonitor
  ▶ audio: WinAudio | AudioCapture  ──PCMChunk──▶  rolling ring (TalkieCore policy; snapshot(), not drain();
                                                    always-on when ClipVault consent is on — M3)
  ▶ recognize: SherpaBackend (finalize-after-release; natively multilingual)
             | AppleSpeechBackend (streaming; CandidateTranscribing for per-locale re-decode — Apple-only)
  ▶ text brain (SHARED):
       StreamingCleanup/SentenceFlow ▶ SpokenFormNormalizer(ITN) ▶ dictionary ▶ NicheCorrector
       (candidates ranked by context: focused app, window title, per-app profile vocabulary)
       [mac only in v1: Summarizer/LLM cleanup]
  ▶ inject: WinTextInjector | TextInjector  (per-app profile tier; UIPI probe; never gated on focus)
  ▶ verify: InsertionVerifier (fail-open read-back, confidence only — M3)
  ▶ learn: AX watcher | WinFieldWatcher(M3) ▶ CorrectionExtractor (≤60 s) ▶ engine-tagged rule packs
                                        └▶ ClipVault reconciliation (consented) ▶ M4 fine-tune corpus
```

---

## 4. Decisions register

| # | Decision | Committed choice | Why | Runner-up | Reversal cost |
|---|----------|------------------|-----|-----------|---------------|
| D1 | Windows engine | sherpa-onnx (Apache-2.0, C API) + Parakeet-TDT 0.6B v3 int8, CPU, offline/greedy, pre-warmed; int8 bundle from k2-fsa or converted from the NVIDIA upstream (third-party NC conversions banned) | Convergent choice of the current local open-model Windows dictation apps (Chirp is exactly this stack; Whispering dropped whisper.cpp on Windows for Parakeet-only); CC-BY-4.0 clean; RTF evidence favorable **but spreads 0.03–0.33 across CPUs — hence the per-device G3 gate before commitment** | Moonshine v2 medium (MIT) — named M0 swap (+1 wk) | LOW — engines are data + config behind `SherpaBackend`; swap = new bundle + one bench run |
| D2 | Dictation UX | Finalize-after-release push-to-talk; HUD level meter; no live partials in v1 | No current local open-model utility ships live partials; Wispr Flow (cloud leader) also finalizes after release; all live-partials paths today forfeit jargon (Zipformer vocab) or reliability (TDT beam-search bug) | Two-stage preview (Nemotron greedy streaming) | LOW, additive — `setUpdateHandler`/partials survive in the v2 seam; preview engine drops in later (~2–3 wks) |
| D3 | macOS engine | **Apple SpeechAnalyzer stays default indefinitely**; owned fine-tune becomes a selectable backend only through the M4 gate + mac-flip checklist; sherpa-onnx-on-mac exists from M2 as a dev-only shadow/fallback target | Mac recognition (multilingual fix, German, latency, battery) is verified working; swapping it re-validates everything to gain biasing that is broken everywhere; Apple's ceiling is attacked text-side now and acoustically at M4 | Immediate shared-engine cutover (the rival Plan A) — lost on engineering risk | TRIVIAL to hold, LOW to advance — backend selector + `--hypotheses` scoring lets any challenger be measured before any user sees it |
| D4 | Jargon strategy v1 | 100 % text-side, shared, engine-agnostic: seeded lexicon (M0 — the production store is empty today) + NicheCorrector + **SpokenFormNormalizer (new ITN)** + context-ranked candidates + engine-tagged learned rule packs (HC2) | Decode-time biasing is verifiably unreliable on every engine today (Apple no-op; sherpa TDT ~20 % hallucination, fix unmerged; Zipformer can't emit `claude.md`); spoken-form mismatch ("claude dot md", "R-T-K") is unfixable by hotwords *even in principle* | Decode-time hotwords — parked behind `experimental.hotwords` + standing BiasingProbe; flips only on a clean bench win post-#3657 | NONE — all layers are additive post-passes |
| D5 | Fine-tune roadmap | Parakeet-TDT v3 base; NeMo adapters (tokenizer unchanged); data = safe-list TTS (Kokoro, Piper libritts_r/ljspeech) + ClipVault clips + mined pairs; jargon audio may be TTS-majority, padded to ≈1:2 synthetic:real with LibriSpeech/own-dictation replay; per-clip provenance; **training on rented single-GPU Linux (~$5–30/run), ClipVault clips only with explicit transfer consent or on owned hardware**; ONNX→Windows, CoreML→mac; ships per-OS only via the comparator gates (HC3) | Direct precedent: Amazon RNN-T TTS-OOV fine-tune ≈ 57 % rel. OOV-WER cut (general-set impact small — re-verify at R6); NVIDIA/AWS ship the exact Parakeet-jargon recipe; icefall adapters (~1.15 % of params, base frozen) make the tune **revertible by construction** — general regression is still gated by bench | Zipformer/icefall base (cleanest adapter recipe, murky weight licensing); Moonshine (MIT) | NEAR-ZERO — pipeline is engine-agnostic data; switching bases re-runs training, not collection |
| D6 | Injection design | Two tiers as per-app **setting** (paste w/ hardened save-restore; SendInput Unicode typing; Shift+Insert terminal variant), per-app profiles day one, UIPI detect-and-warn (HC6), leave-on-clipboard floor; InsertionVerifier read-back (fail-open) in M3; doctrine codified in `docs/contracts/injection.md` | Mirrors the *verified* mac design (not the map's imagined auto-cascade); matches Wispr Flow's shipped Windows answer; never-gate-on-focus is the law that ended the mac autopaste bug | UIA-SetValue insert tier / TSF in-process TIP — both rejected (whole-field replace unreliable on ProseMirror; Dragon-tier COM + EDR flag) | LOW — tiers are strategy objects; profiles already carry the knob |
| D7 | Audio layer | Per-OS native (WASAPI / AVFoundation) behind the narrow shared contract (PCMChunk + ring + levels + liveness + health); policy cores shared; **no Rust audio lib in v1** | The real contract is wider than PCM (verified); two thin working edges don't justify a Swift↔Rust FFI seam and a second language | cpal/miniaudio shared lib | LOW — the PCMChunk contract is exactly what cpal would slot behind later |
| D8 | Meetings on Windows | **Deferred to v2**; loopback seam stubbed, policy cores ported in M1 | Most platform-divergent subsystem; doesn't gate the #1 priority; would ~double the v1 fork surface | Whole-endpoint "meetings lite" in v1 — rejected: mixed-speaker transcripts undercut the quality bar | LOW — purely additive on reserved seams |
| D9 | UI shell | Headless-first: tray + minimal Win32 HUD + WebView2 local settings (Evergreen bootstrap for Win10); dashboard deferred; mac SwiftUI untouched (HC7) | Shell is low-stakes by constraint; keeps 100 % of shell effort off the recognition critical path | Tauri (adds Rust runtime + IPC seam for zero recognition benefit) | LOW — swap is a contained rewrite of ~3 modules |
| D10 | Recognition host | In-process library (no daemon) | No sockets/firewall prompts/EDR socket heuristics/second lifecycle; matches TalkieMCP's stdio precedent | Localhost daemon (map Path D) | LOW-MOD — protocol-contained: ~1–2 wks to stdio child, ~3–4 wks to daemon if multi-surface ever justifies it |
| D11 | Packaging + signing | Signed **Inno per-user installer** (GitHub pre-release for the M2 beta) **+ winget from M3**; **Certum Open Source cert** (~€104 yr1, EU-individual-viable) pending §7 Q3; sparse package for identity in M3; optional per-machine install keeps the `uiAccess` door open; reputation strategy = stable identity + winget volume + published SHA256s + honest onboarding (HC6) | Azure Trusted Signing still excludes EU individuals (verified 2026-05 doc); PowerToys itself ships unpackaged; **MSIX runFullTrust verified NOT to break LL hooks/SendInput/clipboard — rejected instead because `uiAccess` is unsupported in MSIX (permanently closes the elevated-window door) and unsigned-MSIX install behavior is harsher**; winget installs carry no MotW → no SmartScreen prompt | MSIX-full | MODERATE (installer rework) if revisited |
| D12 | Share-vs-fork seam | One repo, three layers: TalkieCore (shared Swift) / re-typed protocol seams / per-OS Swift edges; golden vectors + CI binary network scan as mechanical guarantees (HC4, HC5) | The Foundation-only core is real (verified, bigger than the map claimed); the moat must not fork (HC4 — this is what disqualified the C# beachhead) | C# edges + contracts (the beachhead) — retained as the **priced M0 fallback (+4–6 wks)** | The fallback IS the reversal path; golden vectors are its spec |
| D13 | Minimum Windows version | **Windows 11 primary; Windows 10 22H2 best-effort** (WebView2 Evergreen bootstrap in the installer; sparse package + toasts are Win11-clean; v2 meetings loopback needs Win10 2004+ anyway). The pre-AVX2 degraded tier only exists because of the Win10 tail — on Win11-supported hardware AVX2 is universal | Win11 is where the ICP lives and where packaging/toasts/loopback are clean; cutting Win10 entirely would cost little today but the best-effort tier is nearly free once SAPI degraded mode exists | Win11-only (delete the degraded tier) | LOW — tightening the floor later is a support-matrix note, not code |
| D14 | Hotkeys / tray / autostart | `WH_KEYBOARD_LL` push-to-talk (key-up + suppression — the only real push-to-talk) with **RegisterHotKey fallback switch**; `Shell_NotifyIcon` tray; HKCU Run-key autostart in v1, MSIX StartupTask arriving free with the M3 sparse-package identity | LL hook is the only API giving key-up + suppression for hold-to-talk; Run key needs no identity; tray API is the only stable unpackaged option | Hotkeys: RegisterHotKey-only (toggle-mode only); autostart: Task Scheduler (delayed/elevated start) or Startup folder | LOW — all three are contained inside `WinHotkeys`/`WinTray`/`WinAutostart` modules |
| D15 | Local LLM tier (B1) | llama.cpp (vendored pinned, MIT, CPU default) + Qwen3-1.7B Q4_K_M (Apache-2.0) as `LocalLLMSummarizer`; opt-in "better" Qwen3-4B-2507 on ≥16 GB; output-token caps committed for all styles; serves feature 20 Tier B on old Macs (Metal) from the same module | Same Swift-over-C pattern M2 proves with sherpa-onnx; avoids a second onnxruntime.dll colliding with sherpa's pinned ORT; GGUF quants day-one; licenses commercially clean (LFM2/Gemma rejected on terms) | Runtime: onnxruntime-genai; model: SmolLM3-3B (DE-tuned) as flip-ready default | ~1–2 wks behind the unchanged Summarizer seam; model swap = one manifest entry + bench rerun |
| D16 | Selection edge (B2) | UIA `TextPattern::GetSelection` read → clipboard-probe fallback (save/Ctrl+C/read/restore, sequence-number-guarded) with a **terminal-category ban** → paste-over-selection replace via the existing injector; per-app capability cache in Profiles; preview-before-replace UX | Probe is the only read that works in Electron/legacy apps; the ban prevents SIGINT in terminals; replace reuses the proven paste tier | UIA-only (fails exactly where users dictate) | LOW — tiers are strategy objects; probe policy is a TalkieCore core (mac wants it too, plan 12 §4.2) |
| D17 | Meetings capture (B3) | Process-loopback `EXCLUDE_TARGET_PROCESS_TREE`(self PID) — verified expressible + endpoint-independent; Swift COM vtable (IAgileObject, MTA thread, C-shim fallback); **one shared Parakeet instance, two logical streams** with dictation-preempts-meetings queue; `IAudioSessionManager2` detect-and-offer; calendar-less at ship; **self-imposed consent UX** (Windows has no OS prompt for system audio) | Exact analog of mac's exclude-self tap; second engine instance would cost 2×1.2 GB and kill the 8 GB tier | Full-endpoint loopback + "Talkie emits no sound while recording"; second recognizer instance | LOW — both runner-ups are config/file-level swaps |
| D18 | Embedding model (B4) | `multilingual-e5-small` int8 (MIT, ~118 MB, 384-d, DE+EN) on **both OSes** behind `EmbeddingProvider`, via the already-shipped ONNX Runtime; query:/passage: prefixes inside the provider; first persisted index; embedderID mismatch → rebuild (indexes are derived caches, never synced) | One bench, one index format, DE+EN on both OSes; kills the TalkieMCP SemanticCore mirror; mac NLEmbedding is English-only | EmbeddingGemma-300m (better quality; Gemma terms unreviewed, 3× size); permanent per-OS embedders | NEAR-ZERO — rebuild-on-upgrade is the rule; mac flips only when the retrieval bench says so |
| D19 | Live preview (B5) | Single-engine IncrementalPreview: resident Parakeet decodes VAD-closed segments during capture, volatile dimmed HUD line, cancelled at release; **display-only by construction** (final path untouched); silero-VAD (MIT, 2 MB) bundled; default ON on Windows w/ auto-off below hardware floor (§7 Q7); fast-finalize concat mode ships only inside the ±1σ WER band | Zero new resident weights (the two-model designs were dishonest on 8 GB); zero WER risk (HC1); zero moat fork (HC4) | Nemotron-streaming 16 GB+ opt-in (OML **cleared**, caveats recorded); parakeet-unified re-eval at M4 | LOW-MOD — same TranscriptUpdate seam; opt-in engine is ~1–2 wks if cadence disappoints |
| D20 | GPU/NPU posture (B6) | **CPU-only ASR permanently; Vulkan-only GPU, and only for the B1 LLM tier** (llama.cpp official backend; probe → offload → silent CPU fallback; mac Tier B gets Metal free); **no onnxruntime-gpu ever in a shipped build**; NPU revisit is event-triggered (T1–T4 in `22-gpu-npu-posture.md`), never dated; installer scan asserts zero CUDA/cuDNN/QNN DLLs | CPU already clears G3 for ASR; CUDA EP = ~2 GB version-pinned payload + exact-version crash trap for a minority's 1–2 s; GPU genuinely buys UX only at the LLM tier (tok/s) | Opt-in "GPU pack" download for ASR (revivable ~1–2 wks if meetings batch re-transcription ever wants it) | LOW-MOD — provider is a config string; the cost was always packaging/QA, not code |

---

## 5. Open-risks / unknowns register → spikes that retire them

| # | Risk / unknown | Exposure | Retired by |
|---|----------------|----------|-----------|
| R1 | Parakeet+stack misses the jargon bar | Whole Windows engine bet | **M0 G2** (comparator-correct probe); fallbacks pre-named + priced: Moonshine swap (+1 wk) → TTS-only fine-tune forward (+2–3 wks, parallel to M1) |
| R2 | Finalize latency unacceptable on mid-range laptops (RTF spread 0.03–0.33) | v1 UX | **M0 G3** latency probe (incl. 10 s point) on target-class hardware, on battery; fallback chain named in M0 |
| R3 | Swift-on-Windows fails at this app's scale (Foundation gaps, 10–20× SPM builds, weak lldb) | Core sharing strategy | **M0 G4** compile spike + priced C#-edges fallback (+4–6 wks) with golden vectors as spec; M1 CI wall-time budget is a hard gate |
| R4 | Per-OS engine error-shape drift degrades shared corrector rules | Moat quality | Engine-tagged rule packs + every bench gate runs both engines' hypotheses from the same corpus (M2+) |
| R5 | EDR/SmartScreen flags LL-hook + clipboard automation from an unknown publisher | Adoption | M3 reputation strategy (stable identity, winget, SHA256s, RegisterHotKey fallback, OSS auditability); residual risk accepted |
| R6 | Fine-tuned-checkpoint → ONNX → sherpa-onnx round-trip unproven end-to-end (conversion scripts currently need `torch==2.8.0` pinned); CoreML conversion of the tuned model likewise unverified | M4 convergence | **Dedicated 2–3 day pilot gating M4 entry**: 50 terms × 10–20 carriers × ≥3 safe-list TTS voices (~1.5–3 h audio) → NeMo adapter tune → ONNX int8 + CoreML → jargon-v1 A/B. GO = tuned beats base on term-recall with zero general regression AND both exports load + decode. NO-GO = ship corrector-only; re-evaluate base model |
| R7 | ClipVault data accrues slowly (opt-in, ~2-person fleet, needs a correction to reconcile) | M4 data quality | The M4 recipe is TTS-majority-tolerant by design (75 %-synthetic precedent; LibriSpeech replay padding); clip count is a tracked target, not a gate; consent veto → recorded TTS-only mode |
| R8 | Hardware floor (AVX2/FMA3, ~1.2 GB RAM) excludes users | Reach | Startup capability check + honest requirements + the SAPI degraded tier (effectively the Win10-tail path, D13) |
| R9 | UIPI: users dictate into elevated terminals | Trust in the flagship dev workflow | M2 UIPI probe + warn path (tested against an elevated terminal in the 10-app matrix); long-term door: `uiAccess=true` requires unpackaged + Program Files — kept open by D11 |
| R10 | Win11 hides tray icons by default | Discoverability | Onboarding "drag the parrot to the taskbar" step (M2) |
| R11 | sherpa-onnx TDT int8 quality bugs (missing words; dither edge case) | Recognition quality | M0 probe runs with `--dither=0.00003`; tracked upstream; bench regression suite catches recurrences |
| R12 | Solo-dev bandwidth: mac momentum stalls during M2's OS-edge weeks | Product | TalkieCore changes land for mac continuously (M1 ships mac wins before Windows exists); M1 not gated on the Windows engine (G2/G3 moved to M2 entry) |
| R13 | Claude Desktop's Electron version may predate native UIA (139+) and its a11y tree sleeps until an AT client connects | Read-back verify + correction mining in the flagship app | InsertionVerifier and WinFieldWatcher are fail-open/fail-soft by design; probe lazily, cache per-app capability in the profile |
| R14 | Windows multilingual quality unproven: no per-locale re-decode exists for Parakeet (single 25-language model; the mac self-consistency check is Apple-specific and does NOT port) | DE/code-switch quality on Windows | M0 probe + M2 gate score the jargon-v1 **code-switch subset** directly via `--hypotheses`; if DE quality misses, ship EN-only v1 (§7 Q4) rather than an undesigned runtime check |
| R15 | All quality gates decode mac-recorded audio; Windows capture path (mic arrays, vendor DSP, WASAPI resampling) differs | Real-world Windows accuracy | **M2 Windows-recorded validation subset** (~20–30 clips on the target laptop mic + headset, same protocol) |
| R16 | B1 cleanup latency on single-channel-RAM 8 GB laptops (~11–13 tok/s — the modal cheap machine; verifier-measured) | Cleanup UX | Committed output-token caps for all styles + runtime memory-bandwidth probe feeding the auto Tier-A-skip floor + the 1×8 GB config in the G-C3/C4 gate matrix + warm-hit-rate-under-pressure test |
| R17 | Two native runtimes in one process (sherpa-onnx ORT + llama.cpp): version drift, memory-pressure interactions | Stability | Both vendored + pinned; fail-open cleanup (raw text always inserts); idle-unload; G-C4 coexistence gate incl. finalize-RTF regression < 10 % |
| R18 | Swift-implemented COM object (loopback activation handler) is novel in this codebase | B3 capture | Bounded surface (4-entry vtable + IAgileObject marker); named 30-line C-shim fallback; retired by the 1-wk M3 capture spike |
| R19 | Preview premise risk: users may not want live text at all (mac deliberately renders none) | B5 value | Severable setting (§7 Q7); beta decides the default; segmenter/assembler still serve the gated fast-finalize mode either way |

---

## 6. macOS also wins (why this reads as a product upgrade, not a clone)

| When | What the existing mac product gains |
|------|--------------------------------------|
| M0 | `jargon-v1` corpus + the **first-ever Apple baseline WER** (raw and Apple+stack) — the measurement foundation every future recognition decision on either OS was missing; the retroactive, reproducible gate-zero record; the lexicon finally seeded |
| M1 | Feature 20's pluggable-backend seam becomes real (v2 protocol with live call sites, backend resolver, enforced Summarizer seam) — unblocking WhisperKit/older-macOS backends later; **SpokenFormNormalizer immediately fixes "claude dot md"-class errors on Apple's own output**; the policy cores (FarEndWatchdog, resolveSwap, ring, scorer, CorrectionExtractor) become one tested shared package; golden vectors pin the moat's semantics |
| M2 | Engine-tagged learned rule packs harden the daily mac correction path; `docs/contracts/injection.md` becomes the doctrine future mac TextInjector work merges against; the mac dev-only SherpaBackend + shadow toggle starts accumulating engine-vs-Apple evidence on real dictation |
| M3 | **InsertionVerifier finally wired** (fail-open read-back) against the recurring mac paste-bug class; **ClipVault on mac** — the only possible source of fine-tune audio in Jann's real voice (with the ring made non-destructive, fixing a latent conflict with the multilingual path); a working reputation/distribution channel (winget/Certum) while mac notarization stays blocked |
| M4 | **The payoff:** the first mac recognizer that actually knows `claude.md` — Apple's structural ceiling broken by an owned, versioned CoreML asset (with sherpa-on-mac as the validated fallback runtime); the "recognition brain" artifact (model + lexicon + rule packs) ships over the TalkieUpdater dev channel, routing intelligence updates around the notarization wall |
| Bring-up (§2b) | **B1:** feature 20's Tier B lands on pre-Apple-Intelligence Macs from the same llama.cpp module (Metal-accelerated) — the OSS-widening lever, plus shared CleanupGuards so the guard logic never forks. **B2:** CommandFlow extraction gives mac one tested command orchestration instead of AppDelegate-only logic, the shared clipboard-probe policy is exactly plan 12 §4.2's wanted Electron fallback, and edit-by-voice (ReplaceSelectionIntent — zero call sites on BOTH OSes today) gets wired once, shared. **B3:** TurnLog/notes-fusion/detector cores become tested TalkieCore assets; the cross-OS PlatformAppID allowlist. **B4:** mac's first *persisted* search index (kills the ~5.5 s per-launch rebuild), the TalkieMCP mirror-copy dedupe, and an optional bench-gated flip to DE+EN semantic recall (NLEmbedding is English-only). **B5:** optional HUD preview line (OFF by default — the calm pill stays calm), and the segmenter/assembler serve the M4 mac backend for free |

---

## 7. Open questions for Jann (defaults are set except Q2, which is week-one Jann-hours)

1. **ClipVault consent posture (M3).** Persisting dictation audio (opt-in, local-only, ledger + purge) is the
   one deliberate change to today's "nothing is ever written" posture — and the only path to fine-tune data in
   your voice. The consent copy must also cover (a) the always-on 90 s ring while consented, and (b) whether
   clips may leave your machines for training on rented GPU infrastructure (encrypted, deleted after the run) —
   otherwise ClipVault-trained runs happen only on hardware you control. Default: build it, opt-in-off,
   local-only until you answer (b). Veto entirely = M4 runs TTS-only (recorded decision, plan proceeds).
2. **Corpus recording session (M0, blocks everything).** 60–120 clips per the protocol incl. the code-switch
   subset, a few hours of your time. When?
3. **Signing identity (M2 entry).** Certum Open Source cert shows "Open Source Developer, Jann Allenberger" as
   publisher (~€104 yr 1, EU-individual-viable, ~2-day IDNow verification). OK, or register an org (unlocks
   Azure Trusted Signing for EU orgs, needs 3-year business history)? **Nothing is purchased until this is
   answered** — the reputation strategy depends on never churning the identity.
4. **Windows v1 language bar.** Default: EN + DE, gated by the code-switch subset scores (R14). If DE misses
   the bar on Parakeet, ship EN-only and revisit at M4.
5. **Meetings deferral confirmation.** v1 story = "dictation that gets your jargon right, everywhere you type."
   Confirm meetings stay v2.
6. **Beta cohort.** Does Lars have a Windows machine? If not, name 3–5 Windows-using devs for the M2 private
   beta (installer via GitHub pre-release + SHA256s).
7. **Live-preview default (B5, v1.1).** The design ships the volatile preview line **default ON** on Windows
   (a visible differentiator vs the finalize-only Wispr-class UX), auto-off below the hardware floor or in
   battery saver — but the mac pill deliberately shows *no* transcript, ever, and that calm is brand. Confirm
   default-ON on Windows, or align with the mac philosophy (OFF, opt-in)? Beta feedback can overrule either way.

---

## 8. Corrections to the possibility map (what verification changed)

Recorded so the map isn't trusted beyond its shelf life:

1. **"Seams already drawn" → half-true.** The five protocols exist, but the recognizer seam has zero call
   sites, leaks Apple types (`AnalyzerInput`), and the live path uses four concrete-only methods. M1's seam
   re-typing is real, priced work the map assumed away. (NoteDestination + CommandIntent are genuinely live;
   Summarizer is bypassed by its three biggest would-be consumers.)
2. **"~46 of ~90 files portable" → undersold.** It's 64 of 92 (70 %) — but the "3 shims" claim hid the real
   fork: Speech(9) + AVFoundation(15) + CoreAudio(3) + AX(7) + Carbon/CG(3) importers, plus ~13 AppKit files
   that are OS-integration, not UI. (Counts overlap — many files import several frameworks; 28 distinct
   non-portable non-UI files.)
3. **"sherpa-onnx + Parakeet hotword biasing" → refuted as a v1 foundation.** Hotwords need
   `modified_beam_search`, which on Parakeet-TDT hallucinates ~20 % (issue #3267 open; fix PR #3657 unmerged);
   no streaming NeMo path supports hotwords at all; stock streaming Zipformer's vocab cannot emit `claude.md`.
   Biasing is upside behind a probe, not the plan.
4. **"BiasComparison proved the no-op" → the tooling exists and runs, but the corpus run never happened.** The
   no-op verdict rests on the in-app A/B; no baseline WER number exists anywhere. M0 creates both.
5. **"TalkieMCP = localhost daemon precedent" → it's stdio JSON-RPC**, a child-process precedent. (Which argues
   for D10's in-process/no-sockets stance.)
6. **"Multi-TTS the lexicon" → legal minefield mapped.** macOS `say`, ElevenLabs, Azure TTS (incl. Edge-TTS),
   Coqui XTTS are all banned for commercial training data; Kokoro-82M + Piper libritts_r/ljspeech are the safe
   list.
7. **NPU/Copilot+ → not v1, possibly not v2.** DirectML is in maintenance mode and ~50× slower in sherpa-onnx;
   QNN EP silently falls back to CPU by default and isn't wired into sherpa-onnx on Windows at all.
8. **Injection tiers → the map imagined an auto-cascade; the verified mac design is per-app *settings* + a
   dormant verifier**, and the lesson that matters is *never gate on focus detection*. The Windows design ports
   the reality, not the imagination.
9. **The autopaste fix is merged** (PR #10) — the "canonical fix lives unmerged on a branch" note was stale.
10. **No audio is retained anywhere** (confirmed) — and the rolling ring the fine-tune path wants exists only in
    multilingual mode and is destructively drained before insertion; ClipVault must change both (M3). Text-only
    learned pairs are tiny (22 pairs; the production niche store is literally empty — seeded in M0).
11. **MSIX container fear → wrong reason, right decision.** runFullTrust MSIX does *not* break LL
    hooks/SendInput/clipboard; the real reasons to stay unpackaged-plus-sparse are `uiAccess` (unsupported in
    MSIX) and harsher unsigned-install behavior. PowerToys itself ships unpackaged.
12. **The mac multilingual self-consistency check does not port** — it exists because Apple ships one model per
    locale; Parakeet v3 is one multilingual model. Windows DE quality is gated by corpus scoring instead (R14).

---

*Sources: verification and research artifacts from this session (19-agent foundation-verification workflow,
9-agent judge-panel workflow, 4-critic completeness pass, 2026-07-02; 9-agent bring-up design + verification
workflow, 2026-07-03). Key external references: k2-fsa/sherpa-onnx issues #3267/#2918/#3572/#3032/#3059 + PRs
#3077/#3657; nvidia/parakeet-tdt-0.6b-v3 model card (CC-BY-4.0); NVIDIA Open Model License (nemotron streaming);
arXiv 2011.11564 (TTS-OOV RNN-T fine-tune); LFM2 tech report (small-LLM CPU tok/s measurements); icefall adapter
recipe; Microsoft Artifact Signing FAQ (2026-05); learn.microsoft.com MSIX/uiAccess +
audioclientactivationparams (process-loopback EXCLUDE semantics) + ApplicationLoopback sample docs; Certum Open
Source Code Signing; intfloat/multilingual-e5-small (MIT) + Xenova int8 export; Qwen3/SmolLM3 model cards;
silero-vad (MIT); Wispr Flow support docs; Chirp/OpenWhispr/Whispering/Handy repos. Code citations verified
against this worktree at commit 366a52d.*
