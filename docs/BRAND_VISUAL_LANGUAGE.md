# Talkie — Visual Language & Generated Assets

How Talkie uses its mark and its generated artwork. Companion to
[BRAND.md](BRAND.md) (palette/type/components — the **v2** native-macOS system).
This doc governs **imagery** — the logo, the feather motif, the soft-clay icon
set, and the Higgsfield-generated assets — and it owns the **mandatory pipeline
for producing any new icon**.

---

## 1. The logo — use the real one

The mark is the **layered flat-clay scarlet macaw**. Master art:
`icon_assets/talkie_parrot_transparent.png`. It ships in the app at
`Resources/Brand/TalkieLogo.png` and is loaded at runtime via `Brand.logo`.

- **In-app, always use `Brand.logo`** — never `NSApp.applicationIconImage` (that's
  the rounded-square *app icon*, a different artifact with a dark tile behind it).
- Clear space ≥ 15% of width. Min 20pt tall. Don't recolor, rotate, add
  shadows/gradients, or place on a busy field. The transparent master sits on any
  surface — it holds on the v2 white canvas and on true black alike.

## 2. The feather motif

The macaw's feathers are the brand's expandable visual language: **soft matte
3D plasticine clay**, in the feather hues — scarlet `#E0342B`, amber `#EFA21E`,
cobalt `#2585CE`, emerald `#1FA85C` (and plum `#8A6FB0` for overflow). From this
we derive decorative art: wings, sprays, drifting bokeh. It is warm, tactile,
playful-but-premium — never flat corporate vector, never neon. (Note: in v2 the
*chrome* accent is macaw **blue**; the clay artwork still uses the full feather
spread, because it reads as the mascot, not as UI chrome.)

## 3. The line: clay icons vs. functional symbols

Two icon tiers, split by **size and role**:

- **Identity / category icons ≥ 28pt → generated clay icons.** The settings
  index rows, large empty-state icons, hero glyphs. These are big enough to read
  the soft-clay detail and they *are* the brand. Generated as one consistent
  sheet (see §5) so they all share a material and light, then isolated to
  transparent (§6). Full-color, so they work on both the white and true-black
  surfaces with no tinting. Rendered in-app via `ClayIcon` (SF Symbol fallback if
  the asset is missing).
- **Functional micro-icons < 24pt → SF Symbols.** Chevrons, trash, the add (+),
  copy, toggle labels (`Aa`/`W`), status checks, the live HUD/menu-bar mic,
  sidebar nav glyphs. They must be razor-sharp at 11–16pt, flip for RTL, and
  carry accessibility traits — raster clay would blur and can't theme. The
  settings-row **chevrons stay SF Symbols**; only the leading category icon is
  clay.
- **Decorative / atmospheric art → generated clay art** — onboarding background,
  the Today's Brief banner wings, empty-state illustrations.

## 4. Asset catalog — `Resources/Brand/` (bundled, loaded via `Brand.image(_:)`)

| File | What it is | Used by |
|---|---|---|
| `TalkieLogo.png` | the parrot mark, transparent | sidebar/dashboard wordmark, onboarding, brief banner |
| `FeatherWings.png` | a symmetric clay-feather wing pair, transparent | brief-banner motif, empty states, onboarding accent |
| `AmbientDark.png` | near-black warm bokeh of drifting clay feathers (center kept dark for text) | onboarding background (dark mode) |
| `Icon{Mic,Keyboard,Wand,Globe,Brain,Sliders,Shield,Person,Book}.png` | a consistent set of soft-clay category icons (transparent, 256²) | the Settings index rows; reusable for large empty-states |

Loose PNGs are copied flat into `Talkie.app/Contents/Resources/` by
`scripts/build_app.sh` and read with `Brand.image("Name")` (returns `NSImage?`).

## 5. Higgsfield image-gen pipeline (reproducible) — **MANDATORY for new icons**

> **RULE — fire this pipeline whenever a new icon is implemented.** Every new
> identity / category / decorative clay asset MUST be produced by the **Higgsfield
> CLI image-gen pipeline** below and put through the **isolation technique** in §6.
> Do **not** hand-draw a one-off icon, screenshot one out of a sheet by eye, or
> ship a colored/opaque-background PNG. An icon that skips this pipeline breaks the
> shared material/light and the transparency contract and must not be merged. This
> is the only sanctioned way to add or extend `Resources/Brand/Icon*.png`.

Account/CLI per the `higgsfield-cli` memory. Regenerate or extend with these:

```bash
HF=~/.npm-global/bin/higgsfield

# Category-icon SHEET — generate the whole set as ONE 3×3 image so every icon
# shares the exact material, light, and palette. References the logo to stay on-brand.
$HF generate create nano_banana_2 \
  --prompt "A 3×3 grid of soft matte 3D plasticine-clay app icons in the exact style and palette of this scarlet-macaw logo … microphone, keyboard, magic wand, globe, brain, sliders, shield, person, book … each centered, even lighting, plain pure-white background, no text." \
  --image icon_assets/talkie_parrot_transparent.png --aspect_ratio 1:1 --resolution 2k --wait --json

# Feather wings (then isolate to transparent) — claymorphic, references the logo.
$HF generate create nano_banana_2 \
  --prompt "A graceful fan-spray of layered flat-clay feathers in the exact style and palette of this scarlet-macaw logo: soft matte 3D plasticine clay … scarlet, amber, cobalt, emerald … plain pure-white background, no text." \
  --image icon_assets/talkie_parrot_transparent.png --aspect_ratio 1:1 --resolution 2k --wait --json

# Dark ambient background — feather bokeh, center kept dark for UI text.
$HF generate create nano_banana_2 \
  --prompt "Atmospheric near-black warm charcoal background … soft heavily-blurred layered-clay parrot feathers drifting in from the corners … large central area stays dark and empty for UI text … no text, no characters." \
  --aspect_ratio 16:9 --resolution 2k --wait --json
```

- `nano_banana_2` — claymorphic art + edits-from-`--image` (keeps the parrot's
  exact style/colors). `recraft_v4_1 --model_type vector` — if a flat/vector
  variant is ever needed.
- Always pass `--image icon_assets/talkie_parrot_transparent.png` so a new icon
  inherits the mark's material, lighting, and palette instead of drifting.

## 6. The isolation technique — **always fire it after generation**

Generation gives you an opaque image on a white field. Every clay asset that
goes into `Resources/Brand/` must be **isolated**: cut to a real transparent
RGBA cutout (and, for the category set, sliced out of the shared sheet) so it
composites cleanly on both the white and true-black canvases. This is a hard gate
— an icon with a baked-in white box is a bug.

```bash
HF=~/.npm-global/bin/higgsfield

# 1. ISOLATE — real RGBA cutout via Higgsfield's background remover.
#    Pass the generated PNG with --image; do NOT hand it a bare generation id.
$HF generate create image_background_remover --image <generated_output.png> --wait --json   # → transparent RGBA

# 2. SLICE the 3×3 sheet by explicit offset (the auto-tiler `3x3@` mis-numbers,
#    so crop by coordinate, then trim the transparent margin).
magick sheet_rgba.png -crop 683x683+0+0   -trim IconMic.png
magick sheet_rgba.png -crop 683x683+683+0 -trim IconKeyboard.png
# … repeat per cell offset across the 3×3 grid …

# 3. RESIZE to the in-app size before bundling (master art is 2k — far larger
#    than any in-app use needs; category icons ship at 256²).
sips -Z 256 IconMic.png
```

Order is fixed: **generate → isolate (background-remover → RGBA) → slice →
resize → drop into `Resources/Brand/`**. Re-run `scripts/build_app.sh` so the new
PNG is copied into the app bundle, then verify it loads via `Brand.image("Name")`
/ `ClayIcon`.

## 7. Usage rules

- **Backgrounds sit behind text at low presence** — the ambient's bright bokeh
  lives in the corners; the center stays dark. Never let art reduce text contrast
  below AA.
- **Art is an accent, not wallpaper.** One atmospheric surface per context
  (onboarding); the content panes stay clean white/black.
- **Respect accessibility:** under *Reduce Transparency / Increase Contrast*,
  drop the ambient image to the solid canvas token. Decorative art is
  `accessibilityHidden`.
- **Light vs dark:** `AmbientDark` is for dark mode; in light mode use the white
  canvas with the wings/logo as the accent (no dark image). Generate an
  `AmbientLight` only if a light atmospheric background is later wanted — through
  the same generate → isolate pipeline.
