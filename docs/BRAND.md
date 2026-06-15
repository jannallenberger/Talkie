# Talkie — Brand & Design Guidelines

Talkie is a fast, private, on-device dictation app for macOS. The brand has to
say three things at a glance: **warm** (it's on your side), **honest** (nothing
leaves your Mac), and **quick** (hold a key, talk, done). This guide is the
single source of truth for how Talkie *looks and sounds*. The SwiftUI tokens that
implement it live in [`Sources/Talkie/DesignSystem.swift`](../Sources/Talkie/DesignSystem.swift) —
**that file is the source of truth for exact values; this doc is the source of
truth for philosophy.** They are now reconciled (this is the **v2** system).

> **v1 → v2.** Talkie's first identity was a warm ivory-paper "Claude canvas"
> with a clay-**coral** accent. The shipped app is **v2**: a clean, native
> **macOS 26** surface — pure white / true black — with **macaw blue** leading
> the chrome. The macaw mascot and the feathers-for-data rule carry over
> unchanged; the canvas and the accent are what moved. Where you still see
> "coral" in code (`Theme.coral`), the *value* is now blue — the name was kept
> so call sites stayed valid. Prefer `Theme.brand` in new code.

---

## 1. Brand essence

| | |
|---|---|
| **Personality** | Warm, candid, effortless. A clever friend, not a corporate tool. |
| **One-liner** | *Your own free Wispr Flow — private, on-device, and beautiful.* |
| **Feels like** | A crisp, native Mac app with a parrot's worth of color kept on a tight leash. |
| **Never feels like** | A clinical SaaS dashboard, a neon "AI" gradient, a battery of charts. |

The design DNA is a deliberate fusion of two things:

1. **The mascot** — a layered, flat-clay **scarlet macaw** mid-flight
   (`icon_assets/talkie_parrot_transparent.png`). Parrots *talk*; the macaw's
   stacked feathers give us a ready-made multicolor accent system.
2. **A native macOS 26 canvas** — clean white / true-black surfaces, Liquid
   Glass chrome, squircle corners, system vibrancy. Talkie reads as a first-class
   Mac citizen, not a ported web app. The one feather we promote to *chrome* is
   **blue**; the rest stay reserved for data.

---

## 2. Logo

- **Primary mark:** the flat-clay scarlet macaw. Master art:
  `icon_assets/talkie_parrot_transparent.png`. App icon: `Resources/AppIcon.icon`.
  In-app, load it via `Brand.logo` — never `NSApp.applicationIconImage` (that's
  the rounded-square *app icon*, a different artifact).
- **Clear space:** keep padding ≥ 15% of the mark's width on all sides.
- **Minimum size:** 20 pt tall in UI; 16 px favicon floor.
- **Wordmark:** "Talkie" set in **Young Serif** (the bundled display face),
  regular to bold. The icon + serif wordmark form the lockup in the app sidebar.
- **Don't:** recolor the parrot, add gradients/shadows to it, rotate it, place it
  on a busy photo, or stretch it. The transparent master sits on any surface —
  the clay colors hold on both white and true black.

---

## 3. Color

All values mirror `DesignSystem.swift` (`Theme`). Every token is light/dark
adaptive via `Theme.dyn(light:dark:)`.

### 3.1 Canvas & ink (the native layer)

Clean system neutrals — pure white / true black at the base, surfaces lifting by
**contrast + a whisper shadow, never an outline** (v2 is borderless).

| Token | Light | Dark | Use |
|---|---|---|---|
| `canvas` | `#FFFFFF` | `#000000` | App background |
| `canvasRaised` | `#EFF1F3` | `#121214` | Sidebar / chrome fallback (real sidebar is Liquid Glass) |
| `surface` | `#F5F6F8` | `#1B1B1E` | Cards & panels |
| `surfaceSunken` | `#E9EBEE` | `#29292D` | Inset wells, chart tracks, empty cells |
| `ink` | `#1C1D20` | `#F4F5F6` | Primary text |
| `inkSecondary` | `#5E626A` | `#A6AAB0` | Secondary text |
| `inkTertiary` | `#969AA1` | `#70747B` | Hints, captions |
| `hairline` | `#E6E8EB` | `#2B2B2F` | Row dividers only — never an element outline |

### 3.2 Brand accent — macaw blue

The one chrome color. Primary action, selection, focus ring, the HUD, the mic FAB,
the active sidebar pill. Named `coral` in code for call-site compatibility — the
value is blue; prefer the `brand` alias in new code.

| Token | Light | Dark |
|---|---|---|
| `coral` / `brand` | `#1F66B3` | `#4AA0E6` |
| `coralDeep` / `brandDeep` (press) | `#18548F` | `#79B8EE` |
| `coralWash` / `brandWash` (tint) | `#E1ECF6` | `#122739` |

Use the accent with restraint — one primary action per view, accents not floods.

### 3.3 Feather palette — categorical data

The macaw's five feathers, used **only** for charts/data (usage bars, dots,
multi-series) and per-item nav tints. Never flood chrome with them.

| Token | Light | Dark | Meaning |
|---|---|---|---|
| `featherCoral` / `featherRed` | `#E0342B` | `#F0473B` | the macaw red — data, Dashboard tint, speed gauge, streak |
| `featherGold` | `#EFA21E` | `#F4B33E` | also `warning` |
| `featherBlue` | `#2585CE` | `#4AA0E6` | |
| `featherGreen` | `#1FA85C` | `#34C172` | also `positive` / success |
| `featherPlum` | `#8A6FB0` | `#A98FCB` | overflow / "other" |

`Theme.categorical` is the ordered ramp `[red, gold, blue, green, plum]`.

### 3.4 Heatmap ramp

A deep-red contribution ramp. `surfaceSunken` for empty, then four warming steps
to `#C0271C` (light) / `#F0473B` (dark). See `Theme.heat(level:)`.

---

## 4. Typography

Two voices, used with intent.

- **Display serif — Young Serif** (bundled in `Resources/Fonts/`, registered via
  `ATSApplicationFontsPath`; `Font.talkieDisplay`, `.talkieMetric`). Page titles,
  the wordmark, and big hero metrics. Graceful `.system(design: .serif)` fallback
  when the bundled face isn't registered (debug runs). This is what makes Talkie
  read *editorial* and human rather than dashboard-y.
- **SF Pro — system** (`Font.talkieHeading`, body). Everything functional:
  labels, settings, buttons, table rows.
- **Eyebrows** (`Font.talkieEyebrow`): 11pt semibold, ALL-CAPS, `+0.8` tracking,
  `inkSecondary`. Sits above every card and section ("WORDS PER MINUTE").

Numbers use the serif metric face or `.monospacedDigit()` so they don't jitter.

---

## 5. Layout, shape & elevation

- **Card radius** 22 (squircle / superellipse, continuous) · **control** 13 ·
  **chip** 9 (`Theme.Radius`).
- **Card padding** 20 · **grid gap** 14 · **section gap** 24 (`Theme.Space`).
- **Elevation:** flat-first and **borderless**. A card is a clean surface lifted
  by **two whisper shadows** (`black @ 5%`, radius 2, y 1; and `black @ 7%`,
  radius 20, y 10) — no outline, no heavy drop shadow, no glow (`.talkieCard()` /
  `.talkieSurface()`).
- **Window:** full-size-content with a transparent titlebar; the canvas runs edge
  to edge under the traffic lights. The **sidebar** is a native macOS 26
  `NavigationSplitView` (Liquid Glass / `VisualEffectView` vibrancy); the active
  item gets a `brandWash` pill + blue icon.

---

## 6. Components

- **Card** — `.talkieCard()`: surface fill, squircle radius 22, two whisper
  shadows, no border.
- **Eyebrow + hero** — every metric card: eyebrow label, then a big serif number.
- **Benchmark gauge** — top-half speedometer arc, `surfaceSunken` track, warm
  sweep. Honest framing (vs. an office typist / the world record), never a fake
  percentile of other users.
- **Usage bars** — feather-colored capsules over a sunken track, app icon + %.
- **Heatmap** — rounded cells, small gaps, **Monday-first** columns, month labels,
  deep-red ramp.
- **Sidebar item** — icon + label; active = `brandWash` pill; hover = `surfaceSunken`.
- **HUD pill** — borderless non-activating panel with real macOS 26 `.glassEffect`,
  showing only the live waveform while active.

---

## 7. Iconography

Two tiers, split by size and role — see
[`BRAND_VISUAL_LANGUAGE.md`](BRAND_VISUAL_LANGUAGE.md) for the full rule:

- **Functional micro-icons (< 24pt) → SF Symbols**, weight `.semibold`, sized
  11–14. Lead each metric/row with a symbol in `inkTertiary` (neutral) or a
  feather color (categorical).
- **Identity / category icons (≥ 28pt) → generated soft-clay icons** (`ClayIcon`,
  loaded from `Resources/Brand/`). These ARE the brand and must be produced by the
  **Higgsfield CLI image-gen + isolation pipeline** — see the visual-language doc.
  The macaw mark is the only fully-bespoke illustration; keep it special.

---

## 8. Motion

Calm and physical. Springs (`response 0.28, damping 0.8`) for state changes;
`easeOut 0.11` for the live waveform. Nothing bounces gratuitously; motion
confirms an action, it doesn't perform.

---

## 9. Voice & tone

- **Plain, warm, second person.** "Hold your key and speak." Not "Initiate dictation."
- **Honest about limits.** Because Talkie is offline we say "82% of the world
  record," never "Top 33%" of users we can't see.
- **Privacy stated, not sold.** "Runs entirely on your Mac; nothing leaves the
  device." Calm fact, not a billboard.
- **Encouraging, never gamified-guilt.** Streaks celebrate; they don't nag.
- **Sentence case** for everything (titles, buttons). Title Case only for the
  wordmark "Talkie".

---

## 10. Do / Don't

| Do | Don't |
|---|---|
| Clean white / true-black canvas | Muddy off-grays or pure SaaS gradients |
| One blue accent per view | Accent everywhere |
| Feathers for data only | Feathers on chrome/text |
| Serif for titles & hero numbers | Serif for body/labels |
| Borderless surface + whisper shadows | Heavy shadows, glows, outlines |
| Honest, self-relative metrics | Invented percentiles/benchmarks |
| Generate new clay icons via the Higgsfield + isolation pipeline | Hand-drawn one-off icons that break material/light |
