# Talkie — Visual Language & Generated Assets

How Talkie uses its mark and its generated artwork. Companion to
[BRAND.md](BRAND.md) (palette/type/components). This doc governs **imagery** —
the logo, the feather motif, and the Higgsfield-generated assets.

---

## 1. The logo — use the real one

The mark is the **layered flat-clay scarlet macaw**. Master art:
`icon_assets/talkie_parrot_transparent.png`. It ships in the app at
`Resources/Brand/TalkieLogo.png` and is loaded at runtime via `Brand.logo`.

- **In-app, always use `Brand.logo`** — never `NSApp.applicationIconImage` (that's
  the rounded-square *app icon*, a different artifact with a dark tile behind it).
- Clear space ≥ 15% of width. Min 20pt tall. Don't recolor, rotate, add
  shadows/gradients, or place on a busy field. The transparent master sits on any
  surface.

## 2. The feather motif

The macaw's feathers are the brand's expandable visual language: **soft matte
3D plasticine clay**, in the four feather hues — scarlet `#E0342B`, amber
`#EFA21E`, cobalt `#2585CE`, emerald `#1FA85C`. From this we derive decorative
art: wings, sprays, drifting bokeh. It is warm, tactile, playful-but-premium —
never flat corporate vector, never neon.

## 3. The line: functional icons vs. decorative art

This is the rule that keeps the app crisp **and** branded:

- **Functional UI icons stay SF Symbols** — sidebar glyphs, the settings
  subpage chevrons, toggle labels, status checks. They must be razor-sharp at
  11–16pt, recolor to feather tints, flip for RTL, and carry accessibility
  traits. Raster/AI art can't do any of that, so we do **not** replace them with
  generated bitmaps. The settings rows get their brand identity from
  **feather-tinted icon tiles** (a rounded square filled with the category's
  feather hue), not from custom arrow images.
- **Decorative / atmospheric elements are generated clay art** — onboarding
  backgrounds, the Today's Brief banner motif, empty-state illustrations,
  ambient texture. These are where the macaw's clay language lives.

## 4. Asset catalog — `Resources/Brand/` (bundled, loaded via `Brand.image(_:)`)

| File | What it is | Used by |
|---|---|---|
| `TalkieLogo.png` | the parrot mark, transparent | sidebar/dashboard wordmark, onboarding, brief banner |
| `FeatherWings.png` | a symmetric clay-feather wing pair, transparent | brief-banner motif, empty states, onboarding accent |
| `AmbientDark.png` | near-black warm bokeh of drifting clay feathers (center kept dark for text) | onboarding background (dark mode) |

Loose PNGs are copied flat into `Talkie.app/Contents/Resources/` by
`scripts/build_app.sh` and read with `Brand.image("Name")` (returns `NSImage?`).

## 5. Higgsfield recipes (reproducible)

Account/CLI per the `higgsfield-cli` memory. Regenerate or extend with these:

```bash
HF=~/.npm-global/bin/higgsfield

# Feather wings (then cut to transparent) — claymorphic, references the logo.
$HF generate create nano_banana_2 \
  --prompt "A graceful fan-spray of layered flat-clay feathers in the exact style and palette of this scarlet-macaw logo: soft matte 3D plasticine clay … scarlet, amber, cobalt, emerald … plain pure-white background, no text." \
  --image icon_assets/talkie_parrot_transparent.png --aspect_ratio 1:1 --resolution 2k --wait --json
$HF generate create image_background_remover --image <that_output.png> --wait --json   # → RGBA

# Dark ambient background — feather bokeh, center kept dark for UI text.
$HF generate create nano_banana_2 \
  --prompt "Atmospheric near-black warm charcoal background … soft heavily-blurred layered-clay parrot feathers drifting in from the corners … large central area stays dark and empty for UI text … no text, no characters." \
  --aspect_ratio 16:9 --resolution 2k --wait --json
```

- `nano_banana_2` — claymorphic art + edits-from-`--image` (keeps the parrot's
  exact style/colors). `recraft_v4_1 --model_type vector` — if a flat/vector
  variant is ever needed. `image_background_remover` — real RGBA cutouts (pass
  `--image <path>`; don't hand it a bare id).
- After download, resize with `sips -Z <px>` before bundling (master art is 2k —
  far larger than any in-app use needs).

## 6. Usage rules

- **Backgrounds sit behind text at low presence** — the ambient's bright bokeh
  lives in the corners; the center stays dark. Never let art reduce text contrast
  below AA.
- **Art is an accent, not wallpaper.** One atmospheric surface per context
  (onboarding); the content panes stay clean cream/charcoal.
- **Respect accessibility:** under *Reduce Transparency / Increase Contrast*,
  drop the ambient image to the solid canvas token. Decorative art is
  `accessibilityHidden`.
- **Light vs dark:** `AmbientDark` is for dark mode; in light mode use the cream
  canvas with the wings/logo as the accent (no dark image). Generate an
  `AmbientLight` only if a light atmospheric background is later wanted.
