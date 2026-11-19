# Talkie — Design guidelines (binding)

The rulebook for every main-window, popover, sheet and onboarding surface. It is
distilled from [BRAND.md](BRAND.md), [BRAND_VISUAL_LANGUAGE.md](BRAND_VISUAL_LANGUAGE.md),
the macOS 26 Liquid Glass migration plan and `Sources/Talkie/DesignSystem.swift`.
Where they disagree, the migration plan and **DesignSystem.swift win**. Every rule
below is checkable in code review; "use X" means the named component, not a look-alike.

## 1. Colour roles
| Role | Token | Allowed for | Never for |
|---|---|---|---|
| Canvas | `Theme.canvas` | page background | cards |
| Surface | `Theme.surface` via `.talkieSurface()` / `.talkieCard()` | cards, panels, grouped rows | outlines |
| Sunken | `Theme.surfaceSunken` | text-editor wells, chips, tracks, secondary-button fill | page background |
| Ink | `ink` / `inkSecondary` / `inkTertiary` | primary text / help + subtitles / captions, meta, placeholders | — |
| Hairline | `Theme.hairline` | row dividers (`SettingsDivider`, `Divider().overlay(hairline)`) | element outlines |
| Brand | `Theme.brand` (`coral` in old code), `brandWash`, `brandDeep` | primary button, selection, focus, links, progress tint — **one primary per view** | error text, data |
| Feathers | `featherRed/Gold/Blue/Green/Plum` | data marks only: charts, heatmap, speaker dots, nav tints | text, button labels, backgrounds of chrome |
| Semantic | `positive` / `warning` / `danger` | status icons + `TalkieStatusLine` tones; `danger` also destructive labels | decoration |
| Recording | `tint: Theme.featherRed` on `.talkie(.primary)` | the Stop/recording control and the live-recording glyph only | anything else |

## 2. Type, spacing, radii
- Page title: `Font.talkiePageTitle` (Young Serif 26). Detail titles/hero numbers: `talkieDisplay`/`talkieMetric`. Serif nowhere else.
- UI text: `talkieHeading(size, weight)` — row title 14 medium, popover title 15 semibold, body 13, subtitle/help 12 regular, caption 11–11.5. Minimum 11 pt.
- Section labels: `Eyebrow` / `TalkieSectionLabel` only (11 semibold caps, +0.8 tracking, `inkSecondary`). No hand-built `.uppercased()` labels.
- Spacing: card padding `Space.card` 20 (dense cards 16), grid gap 14, section gap 24, page insets `pageTop 36 / pageSide 28 / pageBottom 28`, popover padding `Space.popover` 16, row padding 16 h / 11 v.
- Radii: card 22, control 13 (rows, wells, list selection), chip 9 (chips, keycaps, tags). Always `.continuous`. No other radius literals.

## 3. Page scaffold
Every main-window page is `TalkiePage` / `TalkieScrollPage` + `TalkiePageHeader` (title, optional subtitle, trailing actions); settings subpages are `SubPage`. Header actions are buttons and menus only — **no switches in a header**; switches live in a card row.

## 4. Buttons — `.buttonStyle(.talkie(kind, size:))`
| Kind | Use |
|---|---|
| `primary` | the one main action of a view/popover/sheet (Save, Record, Add) |
| `secondary` | every other action, Cancel, menus (`TalkieMenuPicker`, `TalkieMenuButton`) |
| `quiet` | icon-only affordances (gear, dismiss ×, per-row copy/delete); always `.help` + `.accessibilityLabel` |
| `destructive` | delete / forget / clear; never the default button |

Sizes: **regular (30 pt)** for page headers, popover/sheet action rows and single-action settings rows; **small (24 pt)** for per-item actions in lists, transcript/editor rows and status lines. No `.bordered`, `.borderedProminent`, `.plain`-with-text, or `.link` buttons.

## 5. Cards, chips, tags, menus
- Cards: `SettingsCard(header:footer:)` with `SettingsRow` / `SettingsToggleRow` / `SettingsNote` rows split by `SettingsDivider`; free-form cards use `.talkieCard()` with an `Eyebrow` first.
- Clickable chips: `.buttonStyle(.talkieChip)` (chip radius, sunken fill, hover darkens) and **a trailing action glyph** (`pencil` rename, `xmark` remove, `chevron.down` menu). On/off chips: `TalkieChipToggleStyle`.
- Static tags (e.g. "slower"): `TalkieTag` — capsule, no hover, no glyph. A tag is never clickable; a chip always is.
- Keys: `TalkieKeycap`.
- Pickers and action menus: `TalkieMenuPicker` (choice) / `TalkieMenuButton` (actions); both show a `chevron.down`. Native `Picker` pop-ups only inside settings rows that already use them.

## 6. Forms
- In cards: label + help on the left (`SettingsRow` title/subtitle), control on the right.
- In popovers and sheets: `TalkieField(label:help:)` — label above (12 semibold `inkSecondary`), the field full-width, help text under it (11.5 `inkTertiary`). Text fields are `.roundedBorder`; multi-line editors use `.talkieWell()`.
- Switches: `TalkieSwitchRow` (popover) / `SettingsToggleRow` (card) — title, one-line subtitle, brand-tinted switch on the right. A privacy/consequence line goes in the subtitle, never as loose text.

## 7. Popovers, sheets, confirmations
- Popovers: `TalkiePopover(title:subtitle:width:)` — title 15 semibold (sentence case, never an eyebrow), content, then the action row **last**. Width `Width.popover` 320 (forms) or `popoverWide` 360. Sections inside are separated by a full-width hairline.
- Sheets: same scaffold at `Width.sheet` 480 / `sheetWide` 560, padding 20.
- Action row: `TalkieActionRow` — destructive/clear action at the **leading** edge; `Cancel` (secondary) then the primary at the **trailing** edge, primary rightmost. Primary = `.keyboardShortcut(.defaultAction)` (Return), Cancel = `.cancelAction` (Escape). A popover with only immediate controls (switches) needs no Cancel.
- Toolbar-style rows with no primary (meeting detail): actions left to right by frequency, destructive last, pushed trailing by a `Spacer`.
- Confirmations: `.confirmationDialog(title, titleVisibility: .visible)` — title is the question ("Delete this meeting?"), message states the consequence, buttons are the verb (`role: .destructive`) + `Cancel` (`role: .cancel`). Required before deleting user content or replacing generated content that holds user notes. `.alert` only for errors/information with a single OK.

## 8. Affordance and states
- Anything clickable looks clickable: a Talkie button/chip style, or a full row with hover wash (`surfaceSunken` hover, `brandWash` selected, radius control). Bare coloured text is never a button.
- Hover: fill shifts one step (built into the styles); pressed: scale 0.97; disabled: 45 % opacity and still visible; focus: system ring.
- Every icon-only control has `.help` and `.accessibilityLabel`.

## 9. Liquid Glass
Only on the top functional layer: sidebar, toolbar, HUD pill, mic FAB, the pushed-page back button (`TalkieBackButton`), and the onboarding card over its atmospheric background. Never on cards, lists, rows, popover contents or the page body.

## 10. Icons
SF Symbols for functional icons < 24 pt (semibold, 11–14 pt, `inkTertiary` or semantic colour). Clay `ClayIcon` for identity/category icons — settings index rows and onboarding permission rows (22–24 pt) and empty-state heroes (≥ 40 pt). New clay art only via the Higgsfield + isolation pipeline.

## 11. Empty, loading, error
- Empty: centred, max 420 wide: clay or SF hero, 15 medium `inkSecondary` title, 13 `inkTertiary` one-line what-to-do.
- Loading / status / error inline: `TalkieStatusLine(text, tone:)` — `.progress` (spinner), `.info`, `.success`, `.warning`, `.error` (icon + colour, never colour alone).
- Waiting for **content** (a page's first frame, search results, a scan, a summary being written): a skeleton from `Skeleton.swift`, shaped like what is coming so nothing jumps when it lands. Parts: `TalkieSkeletonLine` / `Text` / `Block` / `Chip` / `Circle`; layouts: `TalkieSkeletonCard`, `TalkieSkeletonList`, `TalkieSkeletonChips`. Fill `Theme.skeleton` (= `surfaceSunken`), chip radius for lines and chips, control radius for blocks.
- Placeholder parts sit in a `TalkieSkeletonGroup` placed **inside** their card (the shimmer is masked to the parts, so card surfaces stay still): one shimmer per group, never per bar, frozen under Reduce Motion, read by VoiceOver as one "Loading…". Several skeleton cards together get `.talkieSkeletonRegion()` (one VoiceOver element). A skeleton is transient — it leaves the hierarchy when content arrives — so nothing animates in a hidden window.
- A **running action** (Check now, Install, Stop & summarize) keeps its spinner or `TalkieStatusLine(.progress)`; a skeleton never replaces a button's feedback. A status line may sit above a skeleton ("Writing the summary…" over placeholder lines).
- The shimmer runs on a Core Animation layer (`ShimmerBandView`), never on a SwiftUI animation: any running SwiftUI animation re-diffs the whole window's display list every frame.
- Repeating animations (pulses, shimmers) run only while their surface is on screen: a view kept alive in an ordered-out panel must not hold a `repeatForever`. Entrance animations on heavy pages are finite (a timing curve, not a spring with a settling tail) and play once per launch.
- Dismissible notices (update reminder): `TalkieNotice` on a control-radius surface with its action and a quiet ×.

## 12. Dictation pill
- Status lines (the format hint "Listening for a format…", the format chip, "Not recognised") sit on their **own line, horizontally centred directly below the waveform row** — never beside the waveform. The live transcript stays below them. The waveform row keeps its position; height changes animate.
- State colours on the pill are used at **full strength**: the pill is black in both appearances, so the format state uses the brand blue's dark-surface value (`Theme.coral` dark, #4AA0E6) at full opacity for the waveform bars and hint text — no extra dimming or blending. Every state colour must reach **≥ 4.5:1** against the pill background (and against the fills it sits on) and differ clearly from the normal red waveform; `PillPaletteTests` checks both.

## 13. Copy
Sentence case everywhere; second person; plain and calm; privacy stated as fact; no exclamation marks; ellipsis (…) only on buttons that open a further step. Every string uses `.loc` / `LocalizedStringKey` and exists in all 10 languages.

## Known disagreements between the sources (resolved as above)
1. `tokens.css` header still says "warm paper + scarlet-macaw red"; values are v2 white/blue. 2. `inkTertiary`: docs `#969AA1/#70747B`, code `#6A6E76/#80848B` (AA fix) — code wins. 3. Card shadow: BRAND.md + code two whispers (5 % r2 y1, 7 % r20 y10); tokens.css `0 12 28 /.08`; migration Appendix B a single `.07 r26 y10`. 4. Eyebrow colour: tokens.css `ink-3`, code `inkSecondary`. 5. Clay icons: visual-language doc says ≥ 28 pt; code uses 22–24 pt rows. 6. Migration plan puts page titles and actions in the toolbar; code keeps them in `TalkiePageHeader` with an empty toolbar. 7. Migration plan: active nav item = feather tint at 16 %; BRAND.md: `brandWash` pill. 8. tokens.css `--on-coral` is dark in dark mode; code draws white on the primary in both. 9. tokens.css names Inknut Antiqua / weight 500 for display; code uses Young Serif semibold. 10. The design prompt still lists History/Permissions screens and a History "Clear" — the app has Memory and Privacy & history now. 11. README called the look "Anthropic's warm Claude canvas" (v1).
