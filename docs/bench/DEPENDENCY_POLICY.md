# The external-dependency policy — adding an ASR backend to talkie-bench

This is the **decision record** for the one question WS-E cannot answer with a
number until it spends it: *may Talkie take an external speech-recognition
dependency, and if so, where?* It is written **before** any FluidAudio/Parakeet
code lands, on purpose — the gate has to exist before the thing it gates, or it
is not a gate, it is a rationalization.

Its scope is deliberately narrow. It **approves exactly one thing today**: an
env-gated FluidAudio/Parakeet dependency inside **`talkie-bench` only**, so the
gate-two jargon benchmark can produce Apple-vs-Parakeet numbers. It **defers**
the far larger question of an in-app backend (the E3 branch) to a data-driven
decision made against those numbers. And it **forbids** the easy mistakes:
weights in the git tree, a second network path in the shipped core, a
dependency that rots the zero-network gate.

> **One repo, one honest claim.** Talkie's shipped core "contains zero
> networking code — open source, grep it yourself" (`scripts/check-no-network.sh`
> *is* that grep). Every clause below exists to keep that sentence true no matter
> which way the E3 branch eventually goes.

---

## 0. The state this policy starts from (verified)

- **`Package.swift` has ZERO external dependencies.** Grep for
  `fluidaudio`/`parakeet`/`whisperkit`/`sherpa` in `Sources/` returns only
  comments. The only env-gated target today (`TalkieUpdater`, behind
  `TALKIE_DEV_TOOLS`) is a **first-party** target — it resolves nothing from the
  network at build time. Adding FluidAudio would be the **first-ever** external
  SPM dependency in the tree.
- **`talkie-bench` is not scanned by `check-no-network.sh`.** The gate scopes to
  `Sources/Talkie`, `Sources/TalkieMCP`, and the shared `TalkieFileKit` +
  `TalkieCLI` (which ship inside the app bundle). The bench executable is a
  dev-only tool that never enters the app bundle, so a bench-only dependency
  **cannot rot the zero-network gate** — that is the structural reason bench is
  the safe place to spend the first dependency.
- **The app is hardened-runtime, NOT App-Sandboxed.** `Resources/talkie.entitlements`
  carries three entitlements — audio-input, `personal-information.calendars`
  (read-only), and `automation.apple-events` — and **none is a network
  entitlement**. Crucially, the sandbox is *off* (it breaks paste). So nothing
  structural stops a linked third-party library from opening a socket: **the
  zero-network claim is carried entirely by what code is linked**, not by an
  entitlement. This is why the E3 in-app branch is load-bearing and gets its own
  criteria below (§3).
- **`PrivacyWall.assertLocal` is real and wired** at three composition sites
  (`AppDelegate.swift`, `Commands/CommandRouter.swift`, `Meetings/MeetingSubtopicEngine.swift`)
  and unit-tested (`Tests/TalkieTests/PrivacyWallTests.swift`). It is *trivially*
  satisfied today because every conformer hard-codes `requiresNetwork = false`.
  A real second backend (E3) is what first makes that check non-trivial; it does
  not create the wall, it gives it teeth.

---

## 1. The decision — three branches, one chosen for bench, one deferred for the app

The eventual in-app question (E3) has exactly three answers. This doc names all
three, records the trade-offs, and **commits only to what E2 needs now**.

| Branch | What it means | Verdict here |
| --- | --- | --- |
| **(a) SPM dep on the app target** | `Sources/Talkie` links FluidAudio; models loaded only from local disk; the download API is never referenced. | **DEFERRED to E3.** Allowed *only* if it clears §3's criteria. Not decided by this doc. |
| **(b) Vendor an inference-only subset into `Sources/`** | Copy the minimal decode/inference code into the tree so `check-no-network.sh` greps the actual linked source. | **DEFERRED to E3.** The most gate-honest branch, at a real maintenance cost. Not decided here. |
| **(c) Never in-app — bench / external-CLI only** | Parakeet lives only in `talkie-bench`; sherpa-onnx hotword decoding runs entirely outside the repo. | **The always-safe floor. This doc approves (c)'s bench half unconditionally, right now.** |

**What is decided today:**

- **Branch (c)'s bench half is APPROVED.** `talkie-bench` may take an env-gated
  FluidAudio dependency (§2). This is safe regardless of the E3 outcome because
  the bench tool is outside both the app bundle and the network gate's scan
  scope.
- **The E3 in-app branch (a vs b vs c-forever) is DEFERRED.** It is chosen later,
  in `E3`, against the gate-two numbers this package produces — never before them.
  A backend that does not clear the file-transcription bar (Parakeet ≤ Apple −
  2.0 WER pts on file-style audio) never reaches the app, so the branch question
  may never need answering at all.

That deferral is the whole point of the workstream: **turn a bet into a
measurement.**

---

## 2. What is approved now — Parakeet in `talkie-bench`, env-gated

The bench dependency is approved subject to **all** of the following, which the
E2 code half must honor:

1. **Env-gated, exactly like the `devTools` precedent.** A default `swift build`
   resolves **zero** external packages. Only `TALKIE_BENCH_PARAKEET=1 swift build`
   adds FluidAudio, and **only to the `talkie-bench` target** — never to `Talkie`,
   `talkie-mcp`, `TalkieFileKit`, or `talkie-cli`. The Parakeet transcriber source
   is wrapped in `#if canImport(FluidAudio)` so the default graph compiles
   unchanged.
2. **Exact-pinned.** The dependency is pinned to an exact tag, not a range —
   bench numbers are only reproducible against known bytes, exactly as corpus
   versions are frozen (`jargon-v1`, never mutated in place).
3. **`Package.resolved` policy is decided up front, not discovered.** An
   env-gated *external* dependency churns `Package.resolved` between the two
   build flavors (the `devTools` precedent gates only first-party targets, which
   resolve nothing, so it never had this problem). To stop parallel sessions
   fighting over the file: **the default-flavor `Package.resolved` (zero external
   deps) is the committed one**; the Parakeet-flavor resolution is a local,
   uncommitted artifact of running with the env var set. Never commit a
   `Package.resolved` that names FluidAudio from a bench run.
4. **The default gate stays green, untouched.** `swift build`, `swift test`, and
   `./scripts/check-no-network.sh` must all pass with no dependency resolution
   and no behavior change on the default flavor. `check-no-network.sh` is not
   modified by E2 at all — bench is out of its scope by design.

### 2.1 Model download is loud dev-tool network traffic — never silent

Parakeet weights are **not** in the repo and never will be (§4). The bench tool
therefore has to obtain them once, and that fetch **is real network traffic**.
The honesty contract for it:

- **The USER triggers it, explicitly.** First-time model acquisition is a
  documented manual step — `curl`/`hf` CLI, or FluidAudio's own fetch invoked
  **only** by an explicit `talkie-bench` action — never an implicit side effect
  of a scoring run.
- **It announces itself.** Before any byte moves, the tool prints what it is
  about to download, from where, and how large — the never-silent contract
  applies to a dev tool exactly as it applies to the app. "This is only a bench
  tool" is **not** a license to touch the network quietly.
- **It is confined to the bench flavor.** Nothing in this download path exists in
  the default build graph — it lives behind `TALKIE_BENCH_PARAKEET` /
  `#if canImport(FluidAudio)`, so the shipped core never links, references, or
  compiles a line of it.

This is the same shape as the app's honesty rule for any future in-app fetch
(explicit tap, disclosed size/source, absent from the default path) — stated
here for the bench so the discipline is identical on both sides of the wall.

---

## 3. Criteria for the DEFERRED in-app decision (E3 will apply these)

E3 chooses branch (a), (b), or (c-forever) for the app. This doc does **not**
make that choice; it fixes the criteria so E3 is an evaluation, not an argument.
The branch is admissible **only if** it clears the accuracy gate first, then
satisfies every optics/maintenance clause:

1. **Accuracy gate (hard, first).** Parakeet must beat Apple by **≥ 2.0 WER pts**
   on file-style/conversational audio (the E3 file-beachhead bar) on the recorded
   corpus. If it does not, **no branch is admissible** — the dependency simply
   does not enter the app, and (c-forever) stands. Accuracy is measured, not
   assumed.
2. **Linked-binary optics.** Because the app is hardened-runtime and *not*
   sandboxed, "what is linked IS the claim." If branch (a) is chosen, the app
   binary now links model-download-capable code, and the honesty story must be
   updated coherently: `NOTICE`/`docs/PRIVACY.md` must state that the download
   API exists in the linked library, is **never referenced**, that models are
   only ever loaded from disk, and that the sole download path is an explicit,
   user-invoked fetch script. `check-no-network.sh` must be extended with a
   documented linked-symbol audit note (`otool -L` / `strings` spot-check). If
   branch (b) is chosen, the vendored directory joins the gate's scan scope so
   the grep covers the actual linked source. **Whichever branch, the
   "grep it yourself" story must remain coherent — a half-updated privacy page
   hands a reviewer a gotcha.**
3. **License / attribution obligations satisfied in-product** (see §4).
4. **Build-time resolve behavior acceptable.** For the app, a range-pinned or
   network-resolving dependency at build time is not acceptable; exact-pin either
   way, and prefer a resolution posture that a from-source builder can reproduce
   offline.
5. **Maintenance cost owned.** Branch (b)'s vendoring is a standing maintenance
   burden; branch (a)'s external dep is a supply-chain surface. E3 records which
   cost was accepted and why.

Bench-only usage (§2) is approved **regardless** of which branch §3 eventually
selects — including if §3 selects (c-forever) and the app never takes the
dependency at all.

---

## 4. Licensing & attribution (facts to verify at the pinned tag)

Recorded from `docs/plans/20-pluggable-backend.md` §4.5; **re-verify against the
actual pinned tag/model card at integration** — the v3 card is internally
inconsistent (metadata says `cc-by-4.0`, prose says Apache-2.0), so do not trust
this summary over the bytes you pin:

- **FluidAudio *code*: Apache-2.0.** Permits commercial use + redistribution;
  carries a notice/attribution obligation.
- **Parakeet TDT 0.6B v3 *weights*: CC-BY-4.0**, derived from
  `nvidia/parakeet-tdt-0.6b-v3`. Permits commercial + redistribution **with
  attribution** to **NVIDIA** and **FluidInference/FluidAudio**.
- **Weights are NEVER vendored into the git tree** — bench and (if E3 ever
  chooses it) the app both load weights from a local directory the user fetched.
  Same posture as HF-hosted model weights generally.
- **In-product attribution is an E3 obligation, not a bench one.** For the bench
  dev tool, attribution in this doc + the results note suffices. If E3 ships a
  branch into the app, that package owns the `NOTICE` file (Apache-2.0 code +
  CC-BY-4.0 weights) and the in-app/download-UI credit — this doc only records
  that the obligation exists and travels with the weights.

RTFx note: plan 20 records **~110× RTF on M4 Pro** as an *upstream-advertised*
figure. It is unverified in this repo; talkie-bench's own measurement replaces it
(and every other borrowed number) once E2 runs. Do not cite the upstream figure
as ours.

---

## 5. sherpa-onnx hotword decoding runs OUTSIDE the repo

The third gate-two column — sherpa-onnx keyword/hotword boosting (merged upstream
Feb 2026, flaky per its issue #3267, unverified here) — is **not** an in-repo
dependency in any form:

- **No sherpa code enters this repo** — not in `Sources/`, not vendored, not as
  an SPM dependency, not gated behind an env var. Zero footprint.
- It runs entirely via **its own external CLI, on the dev machine**, emitting a
  `<stem>.hyp.txt` per clip.
- Those hypotheses are scored by `talkie-bench` through E1's existing
  `--hypotheses --terms` path — **no FluidAudio work and no sherpa linkage
  required**. The exact CLI invocations are recorded in the talkie-brain results
  note, never here.

This is why the sherpa column is a clean natural split from the Parakeet column:
it needs only E1's hypothesis scorer, so it can land as its own follow-up. The
gate-two verdict is final only once **both** columns are in.

---

## 6. The gate-two verdict itself is DEFERRED to E1's recorded corpus

This doc is the *policy*; it is not the *verdict*. The actual three-way numbers —
Apple vs Parakeet-greedy vs sherpa-onnx-hotwords — cannot be produced until the
`jargon-v1` corpus (E1's protocol, `docs/bench/JARGON_CORPUS.md`) is **recorded**,
which is Jann's task and is not part of this or the E2 code package. Until then:

- The **live-promotion bar** (for E4): Parakeet, or a hotworded alternative,
  beats Apple by **≥ 1.0 WER pt** on the jargon corpus with **improved >
  worsened** clips — the strict gate-zero precedent (`BiasComparison.swift`
  requires strictly greater, not ≥).
- The **file-beachhead bar** (for E3, §3.1): Parakeet **≤ Apple − 2.0 WER pts**
  on conversational/file-style audio.

Both verdicts are written to talkie-brain with corpus version, tag pins, and
hardware — never rounded into a marketing line, always with the provenance footer
the tool prints. **No downstream package (E3–E6) proceeds on a bet; each proceeds
on a number, or not at all.**

---

## 7. Summary — what this doc licenses and what it withholds

**Approved now:**

- A `TALKIE_BENCH_PARAKEET`-gated, exact-pinned FluidAudio dependency in
  **`talkie-bench` only** (§2), with loud, user-triggered, bench-flavor-confined
  model downloads (§2.1).
- The default build's `Package.resolved` (zero external deps) as the committed one
  (§2.3).

**Withheld / deferred:**

- Any `Sources/Talkie` dependency — deferred to E3, admissible only against §3's
  measured criteria.
- The gate-two verdict — deferred to E1's recorded corpus (§6).

**Forbidden outright:**

- Model weights in the git tree (§4).
- Any sherpa-onnx code in the repo, in any form (§5).
- A default `swift build` that resolves an external package, or any change to
  `check-no-network.sh`'s green status on the default flavor (§2).
- A silent model download from any tool, bench or app (§2.1).
