# Talkie → Windows: Possibility Map

**Purpose:** a full option landscape for a possible Windows version of Talkie, to hand to a Fable 5 agent orchestration for detailed design/implementation. This is a *breadth* document — it maps decisions and trade-offs, it does **not** prescribe implementation. Weighted (per request) toward the local speech model and the "build our own voice model" question.

**Method:** 9 parallel research agents (one per dimension) + a synthesis pass, grounded in the 2026 landscape. ~700k tokens of exploration compressed here.

---

## 0. The one-paragraph reframe

Talkie is not really a macOS app that needs porting — it's a **jargon-accurate recognition engine** (plus correction, context, commands) wearing a macOS shell. The recognition engine and the text-injection layer are the only irreducibly OS-specific hard parts; ~46 of ~90 non-UI Swift files already import only Foundation and sit behind clean protocols (`TranscriptionBackend`, `Summarizer`, `NoteDestination`, `CommandIntent`, `MeetingContextProvider`). **The fork line is already drawn in the codebase.** The strategic punchline: Apple's macOS 26 `SpeechAnalyzer` **structurally cannot do transcription-time biasing** (the repo's own `BiasComparison.swift` gate-zero proved `contextualStrings` is a silent no-op) — so adopting an open, biasable, fine-tunable recognizer is **not a Windows tax, it's the single biggest recognition-quality upgrade available, and it flows straight back to the Mac build.** That reframes the whole thing: don't "port to Windows," build an **OS-independent recognizer** and make every OS (mac, Windows, CLI, browser) a thin client of it.

---

## 1. The six end-to-end strategy paths

Ordered cheapest → most ambitious. These bundle choices across all dimensions. Fable can mix (most real plans are B→C, structured as D).

| Path | Philosophy | Recognition | Effort | Killer risk |
|---|---|---|---|---|
| **A — Windows Baseline** | Ship fast, lean on Windows' own on-device speech like mac leans on Apple | Windows ML / Copilot+ NPU speech + existing NicheCorrector post-pass | Low (weeks) | Hits the *exact* jargon ceiling that pushed Talkie off Apple's recognizer → fails the team's own "as good or better" bar |
| **B — Portable Engine Now** ⭐ | Make recognition the point on day one, real hotword biasing, **no training required** | sherpa-onnx hosting Parakeet-TDT transducer + biasing from `NicheVocabStore` + Silero VAD | Medium (1–2 mo) | CPU-only live-latency unproven; Parakeet hotword maturity < Zipformer; NeMo license |
| **C — Own-the-Model** | Recognition becomes a versioned asset Talkie owns identically on both OSes | Fine-tuned Parakeet/Zipformer (or Whisper+LoRA), gated by TalkieBench WER harness | High (multi-mo) | Tuned model fails to clear the WER gate vs Apple/base → no weights ship (mitigated: B already shipped value) |
| **D — Recognition-Core-as-Daemon** | The deliverable is the brain behind a localhost API; every OS is a thin client | B or C engine, packaged as headless `127.0.0.1` service (mirrors existing talkie-mcp pattern) | Med-High | Daemon lifecycle / firewall / EDR friction erodes the trust brand |
| **E — Fork-the-Shell + Own-Engine** | Don't greenfield the plumbing — fork a mature OSS dictation shell, rip its engine, drop in Talkie's | B/C engine inside a forked shell (OpenWhispr is closest) | Low-Med | Inherited Electron/Python footprint clashes with the lightweight-native brand |
| **F — Injection-First Beachhead** | Attack portability per-*surface* not per-OS: flawless insertion into the ~5 apps the dev ICP lives in | any engine; browser ext + VS Code/JetBrains + terminal injectors | Low-Med, incremental | Users read the coverage gap (arbitrary native apps) as incomplete vs mac "types anywhere" |

**Recommended default (synthesis):** *Start on Path B with intent to graduate into C, structured as D if the team can absorb the service-boundary refactor.* Path B is the minimum that respects "recognition is the core," requires no training to start, and the same engine+biasing is simultaneously a **macOS upgrade** — double-valuable from day one. Gate everything on the WER harness so failure surfaces in week one.

---

## 2. HEADLINE — "Build our own voice model" verdict

**Viable, high-leverage, and the honest answer to the team's own thesis — but stage it behind biasing and a WER gate; do not lead with it.**

- **HOW:** fine-tune an open transducer (**Parakeet-TDT** or **Zipformer** via NeMo/icefall as primary; **Whisper large-v3-turbo + LoRA** as the multilingual hedge with the most mature toolchain) on jargon audio the team can largely **manufacture** — multi-TTS synthesis of the known lexicon (`claude.md`, `RTK`, `AXUIElement`, lib/symbol names) in carrier phrases, mixed with real audio and the **mined `LearningEngine` misrecognized→correct pairs**. Layer this **on top of** runtime hotword biasing, not instead of it.
- **WHAT IT UNLOCKS (the strategic core):** converts "getting the user's jargon right" from a property of Apple's un-biasable recognizer into a **portable, versioned ONNX asset Talkie owns identically on macOS AND Windows.** The deliverable stops being "a Windows port" and becomes "an OS-independent recognizer"; Windows becomes a near-free second deployment of an already-validated asset. It's a **shared win** — the same tuned model finally makes jargon biasing work on macOS.
- **WHAT GATES IT:**
  1. **The existing TalkieBench/BiasComparison WER harness** — no weights ship until the tuned model beats the Apple/base baseline on the user's *own* audio. Ship biasing-only first so value lands even if training stalls.
  2. **Is raw audio retained at correction time?** Today's `LearningEngine` pairs are text-only. Either store audio (privacy/storage decision) or re-synthesize via TTS.
  3. **Commercial redistribution licensing** of the base weights (NVIDIA NeMo/Parakeet) and of TTS-generated training audio. (Whisper/Voxtral/Moonshine are permissive/Apache; NVIDIA terms need confirming.)
  4. **Realistic first step = biasing with ZERO training** (Path B): a transducer honoring the existing `NicheVocabStore` list likely already beats Apple, buying time to build the fine-tune properly.

> Treat **"own the model" as the destination, biasing as the on-ramp, and the WER gate as the toll booth.**

---

## 3. Dimension-by-dimension option menus (the full breadth)

### 3a. On-device (local) STT engines
The 2026 landscape has moved past "Whisper is the only local option." Families: **NVIDIA transducers** (top the Open-ASR leaderboard, fast on CPU via ONNX), **Whisper ecosystem** (most portable, weakest at streaming/jargon), **purpose-built streaming models**, and the **runtime layer** that unifies them.

- **whisper.cpp** — most portable (Windows/mac-CoreML/Linux/mobile/WASM, no Python). large-v3-turbo ≈ near-large at ~8× speed. *But:* chunked pseudo-streaming; jargon biasing limited to a 224-token prompt or full fine-tune.
- **faster-whisper (CTranslate2)** — fastest Whisper-accuracy on NVIDIA GPU; Python-centric; **weak on mac** (CPU-only) so a poor cross-OS unifier.
- **distil-whisper** — best latency within Whisper family (English-focused); drops into existing runtimes.
- **WhisperX** — batch diarization + word timestamps → relevant to **meetings**, not dictation.
- **NVIDIA Parakeet-TDT 0.6B v2/v3** ⭐ — leaderboard-leading WER, real-time on CPU via ONNX, **native streaming + hotword/contextual biasing** (the best jargon lever). onnx-asr covers CUDA/TensorRT/DirectML/WebGPU/**CoreML** → one model, both OSes. NPU builds already exist. v2 English-only; v3 adds 25 langs.
- **NVIDIA Canary 1B / 1B-Flash** — top accuracy + built-in translation; AED architecture is more batch-oriented (less ideal for lowest-latency dictation).
- **NVIDIA Canary-Qwen 2.5B (SALM)** — most accurate open model (~5.63% WER); the LLM head can reason about jargon inline (an end-to-end NicheCorrector), but heavy → GPU/NPU class, more a meeting/batch engine.
- **NVIDIA Nemotron Speech Streaming** — benchmark-endorsed winner for real-time English streaming on constrained hardware.
- **Moonshine v2 (Tiny/Small/Medium, streaming)** — edge-first, ~50–258ms latency, beats Whisper-large-v3 WER at Medium with ~6× fewer params; **near-perfect fit for press-hotkey-and-speak.** Newer ecosystem; jargon biasing less mature (fine-tune likely).
- **Kyutai STT (1b en/fr, 2.6b en)** — true streaming + semantic VAD (knows when an utterance ends); narrow language coverage.
- **Mistral Voxtral (Realtime / Transcribe 2)** — **Apache-2.0** (clean license), accuracy-leading + native streaming in one family, 13 langs; 4B is heavy for low-end on-device.
- **sherpa-onnx (k2-fsa)** ⭐ — *runtime, not a model.* One C++/Rust/Swift/C#-bindable library runs Zipformer/Parakeet/Whisper/Paraformer/Moonshine across Windows/mac/Linux/mobile/NPU, with **built-in hotword biasing, VAD, diarization, speaker-ID.** Most likely single dependency serving **both** builds. Ships Windows C# + C++ real-time examples.
- **Streaming Zipformer transducer (icefall/k2)** — low-latency, small footprint, **native hotword biasing**, fully open & fine-tunable → the biasing/fine-tune sweet spot; generic accuracy trails the biggest models (its edge is biasing + tuning).
- **Windows built-in on-device speech (Windows ML / Copilot+ NPU)** — the macOS-analog play (zero model to ship on Copilot+ PCs, NPU-efficient). *Same ceiling that pushed Talkie off Apple:* mangles novel proper nouns, ~no biasing. Windows-only, API in flux (WinML vs DirectML).
- **ONNX Runtime + execution providers (DirectML/TensorRT/QNN/CUDA/CoreML)** — the "write once, accelerate everywhere" layer beneath most options; the foundational shared win.
- **Vosk (Kaldi)** — tiny, instant, true streaming; accuracy below the leaders → best as a fast-preview layer or low-resource fallback.
- **Silero STT + VAD** — the **VAD** is the de-facto endpointing gate you want in *any* pipeline regardless of main engine.
- **wav2vec2 / HuBERT (CTC)** — excellent **fine-tuning base** for a domain model; needs external LM/fine-tune to shine.
- **Conformer / Conformer-Transducer (NeMo)** — proven streaming baseline the Parakeet/Canary family builds on.
- **Paraformer (FunASR)** — fast non-autoregressive; strongest for CJK if the language roadmap needs it.
- **WhisperKit (Argmax)** — mac-only ANE runtime; pairs with a Windows Whisper engine to **share weights**.
- **Hybrid two-stage** — light streaming preview (Vosk/Moonshine-Tiny/Zipformer) + accurate final pass (Parakeet/turbo/Canary-Qwen) where heavy biasing/LLM-correction is applied. Sub-100ms perceived + top-tier final accuracy.

*Lean:* **sherpa-onnx + Parakeet-TDT** as the default engine, hotword biasing wired to `NicheVocabStore`, Silero VAD; Moonshine/Zipformer as the instant-preview layer; Windows built-in speech only as a low-effort baseline.

### 3b. Cloud / hybrid STT
Decisive axis isn't raw WER, it's **jargon steerability** — every 2026 provider exposes runtime keyterm/phrase biasing (a runtime feature, strictly stronger than Apple's no-op). Catch: **privacy** for a tool that types into terminals and the Claude app.

- **Deepgram Nova-3** — runtime keyterm prompting (~100 terms), 200–300ms streaming, **self-hosted/on-prem** escape hatch.
- **AssemblyAI Universal-Streaming** — word boost + strong diarization (bonus for meetings); US-hosted, cloud-only.
- **ElevenLabs Scribe v2 Realtime** — lowest latency (~150ms), keyterm prompting, **zero-retention + EU residency** (strongest privacy posture), cheap. Realtime keyterm cap is small (50).
- **OpenAI gpt-4o-transcribe (Realtime)** — natural-language **prompt-steering** for jargon ("claude.md is a filename") — uniquely flexible, softer/less deterministic.
- **Groq-hosted Whisper** — fastest Whisper inference, cheap; same weights run locally later (shared-model path).
- **Azure AI Speech + Custom Speech** — best *enterprise jargon* story (actually adapt the model, not just hints), container/on-prem, native Windows fit; heaviest setup.
- **Speechmatics** — custom dictionary with **sounds-like** hints, real on-prem appliance.
- **Google STT v2 (Chirp 3)** — per-phrase boost weights; cloud-only GCP terms.
- **Rev AI** — custom vocab, English-centric, weakest differentiator.
- **NVIDIA Riva (self-hostable Parakeet/Canary)** — your own private GPU service with word boosting; overlaps the "roll your own" dimension; enterprise/power-user tier.
- **Windows built-in / Voice Access** — the free offline privacy baseline every hybrid needs.
- **Hybrid: local + cloud keyterm on hard cases** — common dictation stays private/offline; only low-confidence/jargon-suspect utterances escalate. Extends NicheCorrector from fuzzy-match to a real second opinion.
- **Hybrid: cloud/LLM pass as pure jargon corrector on top of local text** — narrowest cloud exposure; LLM uses the *full* vocabulary (no keyterm cap).

*Lean:* hybrid, **local-first + keyterm-boosted cloud pass** (ElevenLabs on latency/privacy, Deepgram on boost capacity + on-prem) behind one interface — and that keyterm/gating layer is itself a **portable macOS win.**

### 3c. Custom / own model — see §2 (headline). Bases: Whisper-turbo+LoRA (most documented, multilingual), Parakeet-TDT (native streaming + biasing), Zipformer (cleanest biasing, fully open), wav2vec2/HuBERT (fine-tune base). Data assets Talkie already has: confidence-ranked jargon lexicon (`NicheVocabStore`) + misrecognized→correct pairs (`LearningEngine`). Synthetic-data lever: **multi-TTS the known lexicon.**

### 3d. Text injection (the AX-paste analog)
Windows has **no single "just works" API** — a tiered menu. (Note: unlike mac, **no accessibility-permission gate** — typing "just works" — but elevated/admin windows (UIPI) silently swallow injected input.)

- **SendInput + KEYEVENTF_UNICODE** — near-universal synthetic Unicode keystrokes; slow for long text, UIPI-blocked on elevated windows (silent), messy undo, surrogate-pair bugs in some terminals.
- **Clipboard-then-paste (Ctrl+V)** — instant regardless of length, single-undo; clobbers clipboard (save/restore races), apps may transform paste, terminals need bracketed-paste awareness.
- **TSF (Text Services Framework) direct insert** — the **genuinely native/invisible path** (how Win+H, Voice Access, Dragon work); focus-tolerant; unlocks future select-and-correct; *but* high COM complexity and coverage gaps (Flutter/Electron/terminals often expose no TSF store) → needs a fallback.
- **UI Automation `ValuePattern.SetValue`** — literal analog to mac AXUIElement; instant, focus-independent; **replaces** whole control contents (wrong for mid-document), unsupported for multi-line docs.
- **WM_CHAR/WM_UNICHAR via SendMessage/PostMessage** — can inject to a specific window *without* focus; fragile, only classic HWND Edit controls; not a general solution.

*Lean:* **tiered injector** — TSF (aspirational native tier) → UIA (single-line) → SendInput (short) → clipboard-paste (long), with a **paste-then-read-back-via-UIA verify loop**. Ship SendInput+clipboard **first** (days, universal), TSF as a v2 quality investment. Mirrors the tiered, edge-case-hardened paste philosophy Talkie already earned on mac.
Wildcards: register as a full **TSF Input Processor/IME** (most native, sidesteps focus entirely); ship a **"Dictation Box" escape hatch** for worst-case apps; **detect-and-warn on UIPI silent-block**; per-app strategy rules (extends the mac app-rules feature).

### 3e. Audio capture (dictation + meetings)
- **WASAPI shared-mode mic** — the baseline every serious app uses.
- **WASAPI exclusive-mode** — lowest latency but blocks other apps (unacceptable — must coexist with Zoom/Teams).
- **WASAPI process-loopback (`AUDIOCLIENT_PROCESS_LOOPBACK`, Win10 2004+)** ⭐ — the **meetings unlock**; per-app capture/exclude, direct analog of the macOS Core Audio process-tap. EXCLUDE mode kills self-feedback without AEC.
- **WASAPI full-endpoint loopback** — dead simple whole-mix capture; no per-app isolation.
- **cpal (Rust)** ⭐ — one layer for Windows+mac; loopback support landed; needs Swift↔Rust FFI into the mac app; loopback is full-endpoint (per-process still hand-rolled).
- **miniaudio (single-header C)** ⭐ — batteries-included: **free 48k→16k resampler + auto device hot-swap + loopback**; would simplify the mac build too.
- **WinRT AudioGraph** — high-level, built-in resampling/AEC hints; higher latency (better for meetings than dictation).
- **PortAudio / RtAudio / SDL3 audio** — cross-platform but superseded by miniaudio/cpal for this use.
- **Virtual audio cable (VB-CABLE/Voicemeeter)** / **own signed driver** — avoid as default (install-a-driver trust tax / WHQL burden); at most a power-user fallback.

*Lean:* one shared Rust/C layer (cpal or wrapped miniaudio) for mic + basic loopback on both OSes; **hand-roll WASAPI process-loopback** as a small Windows-only module for meeting speaker-separation. Key design: **"separation by plumbing, not ML"** — keep loopback (remote) and mic (local) as *separate channels* into the transcriber.

### 3f. UI / app shell
The shell is **not** where Talkie's value lives, and recognition/injection are separate native modules regardless — so this is a **low-stakes decision that should not gate the port.** Current mac UI: ~30 SwiftUI files incl. an animated always-on-top HUD pill.

- **(a) Two native codebases** (SwiftUI mac + WinUI3/.NET Win) — best HUD fidelity, most duplication.
- **(b) Electron** — ranked **last** for an always-on tray utility (200–300MB RAM wrong weight class).
- **(c) Tauri** (Rust core + web UI) — small footprint, aligns with team Rust competency, shared web dashboard.
- **(d) Flutter** — good HUD animation, new language (Dart).
- **(e) Qt** — mature, C++.
- **(f) Avalonia / .NET MAUI / Uno** — best of the *adopt-one-cross-platform-stack* class (C# matches a Windows recognition stack); means discarding working SwiftUI + non-native mac render.
- **(g) Cross-platform Swift + swift-winrt** — keep the language, share logic that also dedupes mac; **least-proven UI bindings** (higher variance), riding the Swift Windows Workgroup momentum.
- **(h) Web UI + tiny native host** — lowest-risk ship: native tray + native overlay + OS webview dashboard, mac SwiftUI stays intact, shared web bundle.

*Lean:* **(h) to ship now** (lowest risk, mac untouched) or **(g) for the higher ceiling** (one language). Rank **Electron last.** Wildcards: build the HUD once as a portable Skia/canvas mini-renderer; ship Windows first as **headless + tiny tray, no dashboard window** (defer 70% of the UI question until recognition is proven); engine-as-sidecar makes the shell a swappable, low-stakes pick.

### 3g. System-integration plumbing
Mostly a **solved, well-trodden space that's dramatically *less* painful than macOS.** Two big contrasts: **no AX-permission gate** for typing into other apps, and **no notarization wall** (you can ship immediately) — but SmartScreen shows an "unrecognized app" warning until a stable identity earns download reputation (EV no longer buys instant trust as of 2024).

- **Hotkeys:** `RegisterHotKey` (simple, combo-only) vs **low-level keyboard hook** `WH_KEYBOARD_LL` (enables real **push-to-talk / tap-to-talk**, key-up, key suppression) vs Rust crates (`global-hotkey` is cross-platform, `win-hotkeys`/`willhook` for LL). AV/EDR may scrutinize global hooks.
- **Tray:** `Shell_NotifyIcon` / framework tray API. Win11 **hides tray icons by default** (discoverability hit vs mac menubar).
- **Launch-at-login:** HKCU Run key (simplest) / Startup-folder shortcut / **Task Scheduler** (delayed start, elevated-without-UAC) / **MSIX StartupTask** (OS-managed toggle, needs package identity).
- **Single-instance:** named mutex / named pipe / framework plugin (can forward argv to the live instance).
- **Notifications:** WinRT toasts **require package identity** (MSIX or sparse package) for proper branding.
- **Mic permission:** far lighter than mac TCC; packaged apps get a per-app toggle, unpackaged ride the global "desktop apps" switch. **No AX-equivalent permission to celebrate.**
- **Packaging:** MSIX (clean identity, but light container may restrict low-level hooks — *verify given the mac sandbox-broke-paste scar*) / **sparse package + own installer** (best-of-both: full Win32 freedom **and** identity) / plain installer (NSIS/Inno/WiX) / Squirrel auto-update / **winget** (dev-audience-native, free).
- **Code signing:** OV (cheap) / EV (no longer instant-trust) / **Azure Trusted/Artifact Signing** (tokenless CI — but individual-dev geography limits: US/Canada only for individuals, US/Canada/EU/UK for orgs — *check EU eligibility*). Optimize **SmartScreen reputation** (winget volume + stable cert), not cert tier.

*Lean:* Rust/Tauri core + LL keyboard hook for push-to-talk + **sparse package over a signed installer** (identity without surrendering Win32) + Azure signing if eligible; treat reputation-building as the "notarization analog."

### 3h. Architecture — share vs fork
The seam is **already drawn:** share the pure-logic core (ContextGraph, Niche correction, Commands, Search, stores, settings) behind existing protocols; fork only the ~6 thin OS-edges (injection, audio, system-audio tap, hotkeys, tray, launch-at-login).

- **Option 1 — full parallel rewrite** (rewrite the moat twice): **don't.**
- **Option 2 — shared portable core in Rust/C++/Go** + thin native shells (the recognizer as a C-ABI dep on both OSes).
- **Option 3 — shared core in cross-platform Swift** (`TalkieCore` package, keep Apple-native shells): cheapest fit for a Swift team; risk = Swift-on-Windows shims for the 3 non-Foundation deps (NaturalLanguage, on-device LLM summarizer, EventKit).
- **Option 4 — one cross-platform framework for everything** (throw away working mac app): **don't.**

*Lean:* **Option 3, then Option 2 for the recognizer specifically** — lift the Foundation-only files into `TalkieCore`, keep OS-edges behind existing protocols, and adopt an open recognizer (whisper.cpp/Parakeet via sherpa-onnx, C-ABI) driven on **both** OSes. If Swift-on-Windows shims prove too painful, the protocol boundaries make "move core to Rust" a contained *later* decision.

### 3i. Lateral / out-of-the-box routes
- **Recognition-core-as-localhost-daemon** ⭐ — headless engine (HTTP/WS/gRPC on 127.0.0.1) + tiny per-OS clients. Mature pattern (Vosk-server, WhisperLive, RealtimeSTT, sherpa-onnx WS). De-risks mac notarization/engine-lock-in; Windows becomes a client, not a rewrite.
- **Portable engine via sherpa-onnx** — the technical linchpin of the jargon strategy (biasing on transducers).
- **Bring-Your-Own-Model server (the model IS the product)** — mac/Windows/CLI/web are commodity skins; model updates ship independently of the notarized app shell.
- **Fork/partner an OSS Windows dictation app** — **OpenWhispr** (MIT-spirited, cross-platform, actively released 2026, already Parakeet/Whisper+BYOK) is closest; WhisperWriter (stale), Whispering, Buzz (wrong shape).
- **IME / TSF injection** — Talkie as a system input method: most native injection possible (note: Feb-2025 Praetorian research flags TSF auto-load as an EDR red flag → sign + build reputation early).
- **Copilot+ PC NPU differentiator** — "runs its jargon model on your NPU at ~1.5W, fully offline" is a claim Apple Silicon can't make in Microsoft's store; later-phase halo with mandatory CPU fallback.
- **Web / browser client (WASM or thin client)** — zero-install trial surface; can't inject into native apps alone.
- **Browser-extension dictation (DOM-native injection)** — solves injection *perfectly* for Claude.ai/Slack/Gmail/Notion/GitHub, dodges the recurring paste-autopaste bug, one codebase all OSes.
- **WSL2 + WSLg** — near-zero incremental if a Linux core exists; host-app injection is not a clean path → niche dev bridge, not a shipping strategy.
- **Cloud-thin-client** — smallest client but off-brand vs local-first DNA; optional fallback tier only.
- **Editor/IDE & terminal plugins** — inject via the editor's own API; high-ROI dev-ICP beachhead, portable per editor.

---

## 4. Cross-cutting insights (traps Fable must NOT miss)

1. **Engine choice and the jargon feature are ONE decision.** In sherpa-onnx, hotword/contextual biasing works on **transducer** models (Parakeet/Zipformer) but **NOT on Whisper.** Picking Whisper for Windows silently forfeits the live biasing that is Talkie's entire reason to exist. Whisper's familiarity/multilingual then forces biasing to come from fine-tuning/prompt-conditioning (weaker).
2. **Windows removes mac's two biggest headaches** (no AX-permission gate; no notarization wall) but **mirrors them differently:** elevated/UIPI windows silently swallow injected input, and SmartScreen warns until reputation accrues. Plan UIPI detection + a reputation strategy, not a certificate tier.
3. **The protocol seams already in the codebase are the single most valuable asset** — the fork line between portable brain and OS edges is essentially drawn. The UI framework debate is therefore low-stakes and must not gate the decision.
4. **Injection wants to be tiered and self-verifying on both OSes** (TSF → UIA → SendInput → clipboard, with paste-then-read-back). A shared "inject" interface with per-app rules extends the existing mac app-rules feature and is directly relevant to the recurring mac paste/autopaste bug.
5. **Meetings is the most platform-divergent subsystem — a candidate to defer from Windows v1.** Clean design: "separation by plumbing, not ML" (loopback channel + mic channel kept separate); process-loopback EXCLUDE kills self-feedback.
6. **A single cross-platform Rust/C audio layer** turns the Windows port into a codebase *consolidation* (also de-risks Linux). Catch: Swift↔Rust/C FFI seam + per-process loopback still hand-rolled.
7. **An LLM-based corrector is the universal jargon escape hatch** — feed local transcript + audio + the *full* vocabulary (no keyterm cap) to a fast model that reasons "cloud-of-em-dee → claude.md." Generalizes NicheCorrector from string-matching to semantic correction; portable. Canary-Qwen is the end-to-end version.
8. **Cloud STT is philosophically off-brand** for terminal/Claude-app dictation, but its runtime keyterm biasing is exactly the steering OS recognizers lack — if used, only as a confidence-gated hybrid, which is itself a portable mac win.
9. **Context-aware dynamic biasing is a latent superpower** — Talkie already reads the focused app; feed visible symbols/filenames/window-title/recent-clipboard as per-utterance hotwords so jargon recognition adapts in real time. Works with transducer hotwords OR cloud keyterms OR LLM correction.

---

## 5. Portable wins (things that also upgrade the macOS build)

- **The headline:** a transducer engine with real hotword biasing (or a fine-tuned owned model) finally gives macOS the jargon biasing its own `BiasComparison` experiment proved Apple ignores → the Windows port becomes a **recognition-quality upgrade for the existing product.**
- LLM-based semantic corrector upgrades mac's NicheCorrector from phonetic close-miss matching to reasoning-based correction (fixes the "AX-blind in the Claude app" gap).
- Shared cross-platform audio layer gives mac a free high-quality resampler + device hot-swap and dedupes two audio stacks.
- "Separation by plumbing" meetings design maps identically to the mac Core Audio tap.
- Shared web Dashboard/Settings/Onboarding (or shared Swift `TalkieCore`) lets the port **dedupe the mac app, not duplicate it.**
- Recognition-core-as-daemon routes the intelligence layer **around the mac notarization wall** (distribution currently blocked) — brain updates ship independently of the notarized shell.
- Personalized synced pronunciation dictionary + mined correction pairs are OS-independent learning assets that survive any recognizer change.
- The tiered self-verifying injection interface hardens both injectors and is directly relevant to the mac paste/autopaste bug.
- A single fine-tuned ONNX model + per-user LoRA adapters is the most portable artifact of all — "the model is the product" makes every client a commodity skin.

---

## 6. Open questions / spikes to run FIRST (the gates)

**Highest-priority (they gate everything):**
- **What is Apple's macOS 26 `SpeechAnalyzer` WER on Jann's jargon corpus TODAY?** Runnable now via TalkieBench. Without it the entire owned-model build is ungated. **Do this in week one.**
- **Live partial-transcript latency of a Parakeet/Zipformer ONNX model for dictation on a mid-range CPU-only Windows laptop** (the majority hardware case). Leaderboard RTFx is batch throughput, not perceived streaming latency. Needs a spike.
- **Is hotword biasing in sherpa-onnx mature for Parakeet specifically** (vs Zipformer, where it's most proven) — can it reliably lock in `claude.md`/`RTK` out of the box, or is Zipformer the safer biasing bet?

**Model / data:**
- Does Talkie retain **raw audio** at correction time? (Acoustic fine-tune needs audio+text; today's pairs are text-only.)
- **Commercial redistribution licensing** for NVIDIA NeMo/Parakeet weights + TTS-generated training audio.
- Is the team willing to **replace/augment Apple's `SpeechAnalyzer` on macOS** with the shared open engine (re-validate accuracy/latency/battery), or must mac keep Apple (which forks the core and kills the "write once" win)?

**Plumbing / platform:**
- Does **DirectML/QNN NPU execution** cover transducer-ASR ops, or silently fall back to CPU on Copilot+ PCs?
- Does **MSIX's container** restrict low-level hooks / SendInput / clipboard-paste? (mac sandbox-broke-paste precedent.) → MSIX-full vs sparse vs plain installer.
- Is the team **eligible for Azure Trusted/Artifact Signing** given individual-dev geography limits (team looks EU-based)?
- Is the **Claude desktop app on Windows Electron/Chromium?** If so, TSF/UIA coverage may be weak there → SendInput/clipboard for that flagship target. Test empirically early.
- **Minimum Windows target** — Win11 only (cleaner MSIX/toast/AI/process-loopback) or Win10 (larger base)?
- How painful are **Swift-on-Windows shims** for the 3 non-Foundation core deps? A one-week spike compiling `TalkieCore` under the Swift Windows toolchain de-risks Option 3 vs falling back to Rust.
- Is **meetings** in scope for Windows v1, or deferred to shrink the fork surface?
- Exact **licenses of fork candidates** (OpenWhispr/Whispering/Buzz) if Path E is pursued.
