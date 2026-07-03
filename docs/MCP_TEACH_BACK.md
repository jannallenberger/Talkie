# Teaching Talkie your jargon from Claude (MCP teach-back)

Talkie ships a small local MCP server (`talkie-mcp`) that lets Claude read your
meetings, brief, context graph, and dictation history — all on-device. It also
exposes **two teach-back tools** so Claude can help Talkie spell your jargon right:

| Tool | What it does |
| --- | --- |
| `add_vocabulary_term` | Suggests a niche/jargon term (a name, product, acronym) for your Dictionary's Custom Vocabulary. |
| `add_replacement` | Suggests a spoken→written rule (e.g. `higgs field → Higgsfield`) for your Dictionary's Replacements. |

## The trust model: queued, never silent

These tools **do not write your dictionary directly**. A prompt-injected Claude
session must never be able to quietly change what your microphone hears. So each
call just **queues one suggestion** as an atomic file in
`~/Library/Application Support/Talkie/inbox/`. Talkie watches that folder and, for
each suggestion:

1. validates it (length, deduplicates against what you already have, rate-caps to
   at most 5 per minute),
2. applies it through the same path your own learned corrections use, and
3. **immediately shows a HUD pill with a one-tap Undo** — the exact same
   apply-with-visible-Undo contract the transcript-learning feature uses.

If Talkie is closed when Claude queues a suggestion, it surfaces the pill on the
next launch — it is never applied without you seeing it. Undo removes the entry and
records that the suggestion was wrong, so a bad suggestion also teaches Talkie not
to trust that spelling.

## CLAUDE.md snippet

Drop this into a project's `CLAUDE.md` (or your global one) so Claude Code offers
to fix Talkie's recognition when *you* correct a mis-transcribed term in a prompt:

```md
## Talkie dictation

When I correct a term that voice dictation clearly mis-transcribed — I retype a
name, product, acronym, or filename that Talkie would have misheard (e.g. I write
"Higgsfield", "claude.md", "Coralate", "kubernetes") — call the Talkie MCP tool
`add_vocabulary_term` with the correct spelling so Talkie learns to spell it right.

If I tell you the *wrong* thing dictation keeps producing for a term ("it always
hears 'correlate' when I mean 'Coralate'"), call `add_replacement` with
from = the misheard form and to = the correct spelling instead.

These are only *suggestions*: Talkie shows me a pill with an Undo before anything
enters my dictionary, so you don't need to ask permission first — just queue it and
tell me you did. Don't spam it: one call per genuinely new term.
```

## Notes

- Purely local. `talkie-mcp` contains zero networking code (enforced by
  `scripts/check-no-network.sh`); the suggestion never leaves your Mac.
- Two Claude sessions can queue at the same time safely — each suggestion is its own
  file, so there is no shared file to clobber.
- The suggestion is recorded as a *passive* signal in Talkie's niche-vocabulary
  store (a plain occurrence), not as a strong "the user typed this themselves"
  confirmation. Surviving the Undo window is the only passive confirmation it earns.
