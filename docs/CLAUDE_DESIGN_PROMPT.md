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
aesthetic is a **clean, native macOS 26 surface** — pure white / true black,
Liquid Glass chrome, squircle corners — with **macaw blue** leading the chrome
and the macaw's feather colors used purely for data. Warm, candid, effortless.
Never a clinical SaaS dashboard or a neon-gradient "AI" app. (This is the **v2**
identity; an earlier v1 used a warm ivory "Claude paper" canvas with a coral
accent — do not revive it.)

**Color — neutrals (clean, system-native):** canvas `#FFFFFF` (dark `#000000`),
raised `#EFF1F3` (`#121214`), card surface `#F5F6F8` (`#1B1B1E`), sunken
`#E9EBEE` (`#29292D`). **Ink:** primary `#1C1D20` (`#F4F5F6`), secondary
`#5E626A` (`#A6AAB0`), tertiary `#969AA1` (`#70747B`). **Hairline** `#E6E8EB`
(`#2B2B2F`) — row dividers only, never an element outline.

**Color — brand accent (macaw blue, the only chrome color):** `#1F66B3` (dark
`#4AA0E6`), deep `#18548F` (`#79B8EE`), wash `#E1ECF6` (`#122739`). One primary
action per view.

**Color — feather palette (data only, never chrome):** red `#E0342B`, gold
`#EFA21E`, blue `#2585CE`, green `#1FA85C`, plum `#8A6FB0`. Heatmap = a deep-red
ramp from sunken → `#C0271C`.

**Type:** display serif (**Young Serif**, bundled) for page titles, the "Talkie"
wordmark, and big hero numbers; SF Pro for everything functional; 11pt ALL-CAPS
`+0.8` tracking eyebrows above each card.

**Shape & elevation:** squircle card radius 22 continuous, controls 13, chips 9.
Flat-first and **borderless** — surfaces lift by two whisper shadows (`black 5%`,
blur 2, y 1; and `black 7%`, blur 20, y 10), **no outline**. Full-size content
window with a **transparent titlebar**; a native `NavigationSplitView` **Liquid
Glass left sidebar** with a `brandWash` blue pill on the active item.

**Iconography:** functional micro-icons (< 24pt) are SF Symbols; identity /
category icons (≥ 28pt) are soft-clay icons produced by the Higgsfield image-gen
+ isolation pipeline (see `BRAND_VISUAL_LANGUAGE.md`) — full-color clay on
transparent, never tinted flat vectors.

## Screens to design

1. **Dashboard (home).** The hero. A 3-up top row: (a) a **WPM speed gauge** —
   top-half speedometer arc, sunken track, warm red→gold sweep, big serif number in
   the center, with **honest** comparison captions ("1.8× an office typist's
   pace", "82% of the world record, 212 wpm") — NEVER a fake "Top X%" percentile,
   because the app is offline and can't compare to other users; (b) a **"Fixes by
   Talkie"** card — big total, then words-polished / dictionary-fixes /
   fillers-removed with feather-colored dots; (c) a **Total words dictated** card
   with last-7-days / dictations / time-spoken sublines. Second row: a **"Where
   your words go"** app-usage breakdown (per-app rows: app icon, name, %, a
   feather-colored progress capsule) and a **24-week contribution heatmap**
   (GitHub-style, Monday-first columns, month labels, deep-red ramp, streak count +
   "Less▢▢▢▢More" legend). A flame "N-day streak" pill sits in the header.

2. **History.** A scrollable list of recent dictations (last 7 days). Each row:
   timestamp eyebrow, the transcript (selectable), copy + delete on hover.
   "Copy all" and "Clear" in the header. Friendly empty state.

3. **Dictionary.** Two sections: **Custom Vocabulary** (chips/list of names &
   jargon to spell right) and **Replacements** (heard → written rules, each with
   case-sensitive / whole-word toggles; auto-learned rules wear a blue-accent sparkle).

4. **Vibe Coding.** An enable switch; a **project-folder picker** (empty state =
   a dashed blue-accent drop-zone "Choose project folder…"; filled state = folder name,
   "N files indexed · scanned 2m ago", Rescan/Change/Remove); and a "How it
   sounds" list of spoken→file examples ("exercise library dot tsx" →
   `ExerciseLibrary.tsx`, monospaced result in the blue accent).

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
   permissions, on the white canvas with the macaw.

## Principles & constraints

- Editorial calm over dashboard density. Generous whitespace; one accent per view.
- Feather colors appear ONLY in data viz. Chrome stays neutral + the blue accent.
- Honest metrics only — self-relative or public benchmarks, no invented stats.
- Both light & dark, designed in parallel (the macaw identity holds in both — white canvas in light, true black in dark).
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
brand. Keep it unmistakably Talkie: clean native canvas, macaw blue, a parrot's worth of
color kept on a tight leash.
