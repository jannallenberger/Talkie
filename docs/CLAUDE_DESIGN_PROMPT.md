# Redesign prompt — Talkie (for Claude / Claude design)

Paste everything below the line into Claude (or Figma Make / any Claude-powered
design surface) to generate a cohesive visual redesign of Talkie. It is
self-contained: brand system, every screen, constraints, and deliverables. Drop
in `icon_assets/talkie_parrot_transparent.png` as the logo when the tool allows
image input.

---

You are a senior product designer. Redesign **Talkie**, a fast, private,
**on-device dictation app for macOS** (you hold a key, talk, and it types the
transcript into whatever app you're using — like Wispr Flow, but free, open
source, and 100% offline). It is built natively in **SwiftUI + AppKit for macOS
26**, so your designs must be implementable with native controls — no web chrome,
no custom font files I can't ship, no effects SwiftUI can't render.

Produce a **high-fidelity redesign** of every screen below, in **both light and
dark mode**, plus a tokens sheet and component specs. Deliver as clean,
annotated mockup frames.

## Brand to honor

The mascot is a **flat layered-clay scarlet macaw, mid-flight** (attached). The
aesthetic fuses **Anthropic's "Claude" canvas** — warm ivory paper, editorial
serif headlines, a clay-coral accent — with the macaw's four feather colors used
purely for data. Warm, candid, effortless. Never a clinical SaaS dashboard or a
neon-gradient "AI" app.

**Color — neutrals (warm, never pure white/black):** canvas `#F4F2EA` (dark
`#191815`), raised `#EDEADF` (`#211F1B`), card surface `#FBFAF5` (`#24221D`),
sunken `#EAE7DC` (`#2C2A23`). **Ink:** primary `#21201B` (`#F3F0E8`), secondary
`#6C685E` (`#AEA99D`), tertiary `#9B9588`. **Hairline** `#E3DFD3` (`#37342D`).

**Color — brand accent (clay-coral, the only brand color):** `#D65A3F` (dark
`#E67D60`), deep `#BE4B33`, wash `#F6E2D8` (`#3A2A22`). One primary action per
view.

**Color — feather palette (data only, never chrome):** coral `#DB5A40`, gold
`#E6A02B`, blue `#3B82C4`, green `#2FA368`, plum `#8A6FB0`. Heatmap = a
coral-warm ramp from sunken → `#BE4B2C`.

**Type:** serif (New York / Times-class) for page titles, the "Talkie" wordmark,
and big hero numbers; SF Pro for everything functional; 11pt ALL-CAPS `+0.8`
tracking eyebrows above each card.

**Shape & elevation:** card radius 18 continuous, controls 10. Flat-first — one
whisper shadow (`black 4.5%`, blur 14, y 6) + a 1px hairline border. Full-size
content window with a **transparent titlebar**; a 214pt **left sidebar** on the
raised canvas with a `coralWash` pill on the active item.

## Screens to design

1. **Dashboard (home).** The hero. A 3-up top row: (a) a **WPM speed gauge** —
   top-half speedometer arc, sunken track, coral→gold sweep, big serif number in
   the center, with **honest** comparison captions ("1.8× an office typist's
   pace", "82% of the world record, 212 wpm") — NEVER a fake "Top X%" percentile,
   because the app is offline and can't compare to other users; (b) a **"Fixes by
   Talkie"** card — big total, then words-polished / dictionary-fixes /
   fillers-removed with feather-colored dots; (c) a **Total words dictated** card
   with last-7-days / dictations / time-spoken sublines. Second row: a **"Where
   your words go"** app-usage breakdown (per-app rows: app icon, name, %, a
   feather-colored progress capsule) and a **24-week contribution heatmap**
   (GitHub-style, Sun-first columns, month labels, coral ramp, streak count +
   "Less▢▢▢▢More" legend). A flame "N-day streak" pill sits in the header.

2. **History.** A scrollable list of recent dictations (last 7 days). Each row:
   timestamp eyebrow, the transcript (selectable), copy + delete on hover.
   "Copy all" and "Clear" in the header. Friendly empty state.

3. **Dictionary.** Two sections: **Custom Vocabulary** (chips/list of names &
   jargon to spell right) and **Replacements** (heard → written rules, each with
   case-sensitive / whole-word toggles; auto-learned rules wear a coral sparkle).

4. **Vibe Coding.** An enable switch; a **project-folder picker** (empty state =
   a dashed coral drop-zone "Choose project folder…"; filled state = folder name,
   "N files indexed · scanned 2m ago", Rescan/Change/Remove); and a "How it
   sounds" list of spoken→file examples ("exercise library dot tsx" →
   `ExerciseLibrary.tsx`, monospaced result in coral).

5. **Settings.** Grouped form: Activation (key + hold/toggle), Insertion, Smart
   cleanup (None/Light/Medium/High segmented), Basic cleanup, **Context
   awareness** toggle, Learning, Languages (multi-select), Behavior.

6. **Permissions.** Three permission cards (Microphone, Input Monitoring,
   Accessibility) each with a status check/warning glyph, a one-line why, and
   Grant / Open-Settings actions. "All set" success state.

7. **Floating dictation HUD.** A small, non-activating **pill** near the bottom
   of the screen showing a live, reactive **waveform** of the user's voice while
   they hold the key — then brief "Polishing… / Inserted" states. Glassy,
   shadowed, minimal. Design listening, transcribing, processing, inserted, and
   error states.

8. **First-run onboarding (new — propose it).** A warm 1–3 step welcome that
   introduces the hold-to-talk gesture and walks through granting the three
   permissions, on the cream canvas with the macaw.

## Principles & constraints

- Editorial calm over dashboard density. Generous whitespace; one accent per view.
- Feather colors appear ONLY in data viz. Chrome stays neutral + coral.
- Honest metrics only — self-relative or public benchmarks, no invented stats.
- Both light & dark, designed in parallel (warm in both — the cream identity holds).
- Accessible: AA contrast, ≥11pt text, focus states, color never the sole signal.
- Motion is calm and physical (springs ~0.28s/0.8 damping); it confirms, never performs.
- Voice: plain, warm, second person, sentence case. "Hold your key and speak."

## Deliverables

1. Light + dark mockups of all eight screens.
2. A **design-tokens sheet** (the colors/type/spacing above) mapped to names a
   SwiftUI engineer can implement (mirror `Sources/Talkie/DesignSystem.swift`).
3. Component specs: card, eyebrow+hero metric, benchmark gauge, usage bar,
   heatmap cell, sidebar item, HUD pill — with states.
4. A one-paragraph rationale per screen.

Stay faithful to the brand above; surprise me with craft, not with a different
brand. Keep it unmistakably Talkie: warm paper, clay-coral, a parrot's worth of
color kept on a tight leash.
