# Vendored FluidAudio (offline diarizer subset)

This directory (`Sources/FluidAudio`, SwiftPM module `FluidAudio`) and
`Sources/FastClusterWrapper` (C++ module) are a **modified subset** of
FluidAudio, <https://github.com/FluidInference/FluidAudio>, licensed under the
Apache License 2.0 (`LICENSE` next to this file). Copyright Fluid Inference and
contributors. The VBx clustering code derives from BUT Speech@FIT's VBx
(Apache-2.0, `vbx-LICENSE.md`); `FastClusterWrapper` contains fastcluster
(BSD-2-Clause, Daniel Muellner / Google, `fastcluster-LICENSE.md`; its copyright
header is preserved in `fastcluster_internal.hpp`). Upstream Swift files carry no
per-file copyright header, so none were removed.

## Provenance

- Upstream tag: `v0.18.3`
- Upstream commit: `c8b41f98eae668794dd0083bbe028fe7e6585051`
- Source of truth for the pinned model revision: `Repo.diarizer.revision` in
  upstream `Sources/FluidAudio/ModelNames.swift` (`df2625ac79a7ac6b65ad868fee6d80f320da4232`),
  mirrored in `SpeakerDiarizer.pinnedRevision` and `scripts/fetch_diarization_models.sh`.

## Why vendored

The shipped Talkie binary must contain no networking code. The FluidAudio
package cannot be linked without its model downloader (Hugging Face client,
`URLSession`). Only the offline community-1 diarizer is needed, and Talkie loads
the CoreML models itself with `MLModel(contentsOf:)` from a bundled folder.

## Modified from upstream (Apache-2.0 section 4(b))

These files were changed; each carries a `MODIFIED FROM UPSTREAM (Talkie)` comment:

- `Diarizer/Offline/Core/OfflineDiarizerManager.swift`: removed `prepareModels`
  (download + cache purge), `purgeDiarizerRepo`, and the model prewarm helpers
  that only it called; the two `if models == nil { prepareModels() }` fallbacks
  now fall through to the existing `modelNotLoaded` error. One URL removed from a
  string literal. Callers use `initialize(models:)`.
- `Diarizer/Offline/Core/OfflineDiarizerModels.swift`: kept the `public struct`
  and its memberwise `init`; removed `defaultModelsDirectory`, `load(...)`
  (ModelHub download) and `loadPLDAPsi` (Talkie has its own in `TalkieDiarization`).
- `Diarizer/Offline/Clustering/VBxClustering.swift`: a doc-comment URL reworded
  (the zero-network gate rejects any `http(s)://` text).
- `Shared/AudioSourceFactory.swift`: removed the conversion fallback that wrote
  `fluidaudio-streaming-<uuid>.raw` into the system temp directory (and its helpers
  `makeTemporaryURL`, `streamConvert`). Only a 16-bit mono PCM wav at the target rate,
  read in place, is accepted; anything else throws, so meeting audio can never be
  copied outside Talkie's private diarization folder.
- `Shared/BlasIndex.swift`: NEW. Upstream defines `BlasIndex`/`makeBlasIndex` in
  the ASR tree and throws `ASRError`; here it throws `OfflineDiarizationError`.
- Build: upstream compiles with `-DDiarizer` (and `-DTTS`); `Package.swift`
  defines only `Diarizer`. `FastClusterWrapper` is byte-identical except that
  `Package.swift` declares it as a plain target.

All other files are byte-identical to the tag (verify with the procedure below).

## Vendored paths (relative to upstream repo root)

Swift, under `Sources/FluidAudio/` (same relative path here):

- `Diarizer/Core/DiarizerTypes.swift`
- `Diarizer/Clustering/SpeakerTypes.swift`
- `Diarizer/HungarianAssignment.swift`
- `Diarizer/Offline/**` (Clustering, Core, Extraction, Segmentation, Utils)
- `Shared/{ANEMemoryOptimizer,ANEMemoryUtils,AppLogger,AudioConverter,AudioSampleSource,AudioSource,AudioSourceFactory}.swift`

C++: `Sources/FastClusterWrapper/{FastClusterWrapper.cpp,fastcluster_internal.hpp,include/*}`
-> `Sources/FastClusterWrapper/`.

Licenses: `LICENSE` -> `Sources/FluidAudio/LICENSE`;
`ThirdPartyLicenses/{fastcluster,vbx}-LICENSE.md` -> `Sources/FluidAudio/`.

Deliberately NOT vendored: `Shared/Download/**` (HFClient, ModelHub, FileDownloader,
...), `ModelNames.swift`, `ModelRegistry.swift`, `Shared/AssetDownloader.swift`,
ASR, TTS, VAD, ITN, Sortformer, LS-EEND, Nemotron3, `DiarizerManager` (legacy
pipeline), and the CLI.

## Re-sync procedure

1. Pick the new tag; `git clone https://github.com/FluidInference/FluidAudio` to a
   scratch dir OUTSIDE this repo, `git checkout <tag>`, record `git rev-parse HEAD`.
2. Diff the vendored paths against the old tag
   (`git diff v0.18.3 <tag> -- <each path above>`). If nothing relevant changed,
   only update the tag/commit here and stop.
3. Copy each listed path over the vendored copy. Then re-apply every edit in
   "Modified from upstream" (re-run the deletions; keep the
   `MODIFIED FROM UPSTREAM` comments). If upstream now references a type that
   is missing, copy that file too, but never a file that mentions `ModelHub`,
   `HFClient`, `URLSession` or `Download`.
4. Check the pinned model revision (`Repo.diarizer.revision`) and, if it changed,
   update `SpeakerDiarizer.pinnedRevision`, `scripts/fetch_diarization_models.sh`
   (`REVISION`), and `scripts/diarization-models.sha256`; re-fetch the models.
5. Copy updated `LICENSE` and `ThirdPartyLicenses/{fastcluster,vbx}-LICENSE.md`.
6. Update the tag/commit above and `THIRD_PARTY_NOTICES.md`.
7. Verify: `swift build`, `swift test` (models fetched), `scripts/check-no-network.sh`
   (must pass with no exemptions in these directories), and on a release build
   `nm -a .build/release/Talkie | grep -iE 'URLSession|NSURLConnection|CFNetwork|nw_connection'`
   must print nothing.
