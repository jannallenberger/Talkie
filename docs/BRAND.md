# Talkie — Brand & Design Guidelines

Talkie is a fast, private, on-device dictation app for macOS. The brand has to
say three things at a glance: **warm** (it's on your side), **honest** (nothing
leaves your Mac), and **quick** (hold a key, talk, done). This guide is the
single source of truth for how Talkie looks and sounds. The SwiftUI tokens that
implement it live in [`Sources/Talkie/DesignSystem.swift`](../Sources/Talkie/DesignSystem.swift).

---

## 1. Brand essence

| | |
|---|---|
| **Personality** | Warm, candid, effortless. A clever friend, not a corporate tool. |
| **One-liner** | *Your own free Wispr Flow — private, on-device, and beautiful.* |
| **Feels like** | Claude's warm editorial calm, with a splash of tropical color. |
| **Never feels like** | A clinical SaaS dashboard, a neon "AI" gradient, a battery of charts. |

The design DNA is a deliberate fusion of two things:

1. **The mascot** — a layered, flat-clay **scarlet macaw** mid-flight
   (`icon_assets/talkie_parrot_transparent.png`). Parrots *talk*; the macaw's
   stacked feathers give us a ready-made multicolor accent system.
2. **Claude's canvas** — Anthropic's warm ivory paper and clay-coral accent.
   The happy accident: **the macaw's body and Anthropic's terracotta are the
   same hue.** That coral is Talkie's single brand color.

---

## 2. Logo

- **Primary mark:** the flat-clay scarlet macaw. Master art:
  `icon_assets/talkie_parrot_transparent.png`. App icon: `Talkie Icon final.icon`.
- **Clear space:** keep padding ≥ 15% of the mark's width on all sides.
- **Minimum size:** 20 pt tall in UI; 16 px favicon floor.
- **Wordmark:** "Talkie" set in a **serif** (New York / Times-class), regular to
  bold. The icon + serif wordmark form the lockup in the app sidebar.
- **Don't:** recolor the parrot, add gradients/shadows to it, rotate it, place it
  on a busy photo, or stretch it. On dark backgrounds use the transparent master
  as-is — the clay colors hold up.

---

## 3. Color

### 3.1 Canvas & ink (the Claude layer)

Warm, paper-like neutrals — never pure `#FFFFFF` or `#000000`.

| Token | Light | Dark | Use |
|---|---|---|---|
| `canvas` | `#F4F2EA` | `#191815` | App background (ivory paper) |
| `canvasRaised` | `#EDEADF` | `#211F1B` | Sidebar / chrome |
| `surface` | `#FBFAF5` | `#24221D` | Cards & panels |
| `surfaceSunken` | `#EAE7DC` | `#2C2A23` | Inset wells, chart tracks, empty cells |
| `ink` | `#21201B` | `#F3F0E8` | Primary text |
| `inkSecondary` | `#6C685E` | `#AEA99D` | Secondary text |
| `inkTertiary` | `#9B9588` | `#7B766B` | Hints, captions |
| `hairline` | `#E3DFD3` | `#37342D` | 1px borders/dividers |

### 3.2 Brand accent — clay-coral

The one brand color. Buttons, active nav, the gauge fill, the parrot's body.

| Token | Light | Dark |
|---|---|---|
| `coral` | `#D65A3F` | `#E67D60` |
| `coralDeep` (press) | `#BE4B33` | `#CF6A4E` |
| `coralWash` (tint) | `#F6E2D8` | `#3A2A22` |

Use coral with restraint — one primary action per view, accents not floods.

### 3.3 Feather palette — categorical data

The macaw's four feathers, used **only** for charts/data (usage bars, dots,
multi-series). Never decorate chrome with them.

| Token | Light | Meaning |
|---|---|---|
| `featherCoral` | `#DB5A40` | (also the brand tie-in) |
| `featherGold` | `#E6A02B` | |
| `featherBlue` | `#3B82C4` | |
| `featherGreen` | `#2FA368` | also `positive` / success |
| `featherPlum` | `#8A6FB0` | overflow / "other" |

### 3.4 Heatmap ramp

A coral-warm contribution ramp (not the reference's teal). `surfaceSunken` for
empty, then four warming steps to `#BE4B2C`. See `Theme.heat(level:)`.

---

## 4. Typography

Two voices, used with intent.

- **Serif display — New York** (`Font.talkieDisplay`, `.talkieMetric`).
  Page titles, the wordmark, and big hero metrics (`2,119`). This is what makes
  Talkie read *editorial* and human rather than dashboard-y.
- **SF Pro — system** (`Font.talkieHeading`, body). Everything functional:
  labels, settings, buttons, table rows.
- **Eyebrows** (`Font.talkieEyebrow`): 11pt semibold, ALL-CAPS, `+0.8` tracking,
  `inkSecondary`. Sits above every card and section ("WORDS PER MINUTE").

Scale (pt): display 26 · card hero number 46 · section 17–21 · body 13–14 ·
caption 11–12. Numbers use serif or `.monospacedDigit()` so they don't jitter.

---

## 5. Layout, shape & elevation

- **Card radius** 18 (continuous) · **control** 10 · **chip** 8.
- **Card padding** 20 · **grid gap** 14 · **section gap** 22 · **page pad** 28.
- **Elevation:** flat-first. A single whisper shadow on cards
  (`black @ 4.5%`, radius 14, y 6) plus a 1px `hairline` border. No heavy drop
  shadows, no glows.
- **Window:** full-size-content with a transparent titlebar; the cream canvas
  runs edge to edge under the traffic lights. Left **sidebar** (214pt) on
  `canvasRaised`; active item gets a `coralWash` pill + coral icon.

---

## 6. Components

- **Card** — `.talkieCard()`: surface fill, radius 18, hairline, whisper shadow.
- **Eyebrow + hero** — every metric card: eyebrow label, then a 46pt serif number.
- **Benchmark gauge** — top-half speedometer arc, `surfaceSunken` track, coral→gold
  sweep. Honest framing (vs. an office typist / the world record), never a fake
  percentile of other users.
- **Usage bars** — feather-colored capsules over a sunken track, app icon + %.
- **Heatmap** — 12pt rounded cells, 3pt gaps, Sun-first columns, month labels.
- **Sidebar button** — icon + label; active = `coralWash`; hover = `surfaceSunken`.

---

## 7. Iconography

SF Symbols throughout, weight `.semibold`, sized 11–14 in UI. Lead each metric/row
with a symbol in `inkTertiary` (neutral) or a feather color (categorical). The
parrot is the *only* bespoke illustration — keep it special.

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
| Warm ivory canvas | Pure white / pure black |
| One coral accent per view | Coral everywhere |
| Feathers for data only | Feathers on chrome/text |
| Serif for titles & hero numbers | Serif for body/labels |
| Flat + hairline + whisper shadow | Heavy shadows, glows, gradients |
| Honest, self-relative metrics | Invented percentiles/benchmarks |
