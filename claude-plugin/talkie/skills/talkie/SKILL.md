---
name: talkie
description: Recall the user's own meetings, daily brief, commitments, people/projects, and past dictations from their local Talkie app — and, when they correct a mis-heard term, suggest a fix to their Talkie dictionary so recognition spells it right next time. Use whenever they ask "what did I say about…", "what did we decide in that meeting", "what am I on the hook for", "who is <name>", "what's on my brief today", reference their own spoken history/notes/context, or write a niche name recognition would mangle. All data is on-device via the Talkie MCP server — nothing leaves their Mac.
---

# Talkie recall & dictionary

The **talkie** MCP server exposes the user's local Talkie data — meetings, today's brief, their context graph (people, projects, commitments), dictation history, stats, scratchpad, and dictionary — plus a set of **queued** dictionary/meeting edits. Everything runs on-device; nothing is sent anywhere. Use the reads to ground answers in what the user actually said or did; use the writes to teach Talkie a term it keeps mis-hearing.

## Reading tools (on-device, read-only — call freely)

| Tool | Use it for | Key args |
|---|---|---|
| `search` | The default for recall. Semantic + keyword across meetings, dictations, and entities — finds by meaning ("shipping the updater" matches "release the auto-update build"). | `query`; optional `limit`, `sources` (`meetings\|dictations\|entities`) |
| `list_meetings` | Browse recent meetings (id, title, date, participants, one-line summary). | optional `limit`, `query` |
| `get_meeting` | Full summary + transcript of one meeting. | one of `id` / `title` / `date` (yyyy-MM-dd) |
| `get_brief` | Today's on-device brief — what they worked on, commitments, open threads. | none |
| `list_commitments` | Action items from the context graph, newest first (things they *said*, not a task list). | optional `limit`, `include_dictations` |
| `lookup_entity` | Resolve a person / project / term by name or alias, with provenance. | `query`; optional `kinds` (`person\|project\|term\|commitment`) |
| `get_recent_context` | "What was I just working on / talking about?" — a timestamped report of recent dictations, overlapping meetings, and entities touched in the last N minutes. | optional `minutes`, `topic`, `limit` |
| `graph_query` | "What do you know about X?" — header, recent provenance snippets, and entities seen alongside one person/project/term. | `entity`; optional `limit` |
| `get_stats` | Lifetime dictation stats — words, dictations, speaking time, avg/best WPM, fixes made, daily streak. | none |
| `get_dictionary` | List the user's vocabulary terms and spoken→written replacement rules. **Call this before any dictionary write** so you don't duplicate what they already have. | none |
| `list_dictations` | Recent dictations newest-first (timestamp, app, opening text) from the retained window (default 7 days). | optional `limit`, `app`, `since` |
| `read_scratchpad` | The user's quick notes and checkbox tasks (read-only — Claude never writes the scratchpad). | none |

## Dictionary & meeting edits (QUEUED — the user confirms in Talkie with a one-tap Undo)

These do **not** change anything directly. Each call drops one suggestion into Talkie's inbox; Talkie applies it only after the user accepts it, and an Undo restores the prior state. So a session can never silently change the user's speech recognition. Just call the tool and tell the user what you queued — don't ask first and wait.

| Tool | Use it for | Key args |
|---|---|---|
| `add_vocabulary_term` | Teach recognition a niche name/product/acronym's spelling (e.g. `Higgsfield`, `Coralate`, `claude.md`). | `term`; optional `note` |
| `add_replacement` | Map a form recognition reliably mishears to what the user meant (`correlate` → `Coralate`, `higgs field` → `Higgsfield`). | `from`, `to`; optional `note` |
| `update_replacement` | Retarget an existing rule (same `from`/`to`, new `new_to`). | `from`, `to`, `new_to`; optional `note` |
| `remove_replacement` | Delete a replacement rule by its exact `from → to`. | `from`, `to`; optional `note` |
| `remove_vocabulary_term` | Delete a vocabulary term by its exact spelling. | `term`; optional `note` |
| `retitle_meeting` | Rename a meeting in the user's history (matched by `id` or 8-char prefix from `list_meetings`/`get_meeting`). | `id`, `title`; optional `note` |

## Workflows

- **"Pull the action items from my last meeting."** `list_meetings` (limit 1) → `get_meeting` by that `id` → extract commitments; cross-check with `list_commitments`.
- **"What did I say about <topic>?" / "what did we decide about X?"** Lead with `search` (`query` = the topic). Open promising hits with `get_meeting` for the full transcript.
- **"What was I just working on?"** `get_recent_context`.
- **"Who is <name>?" / "status of <project>?"** `lookup_entity`, or `graph_query` for what's known + co-occurring entities.
- **"Cite today's brief."** `get_brief`, then quote the relevant line with its source.
- **Teach a mis-heard term.** When the user writes a niche name recognition would mangle (or explicitly corrects one), `get_dictionary` first to avoid duplicates, then `add_vocabulary_term` (novel spelling) or `add_replacement` (you know the exact wrong→right). Tell them it's queued for their confirmation.

## Etiquette for dictionary writes

Call `get_dictionary` before suggesting so you never duplicate an existing term or rule. Keep it **high-signal** — one call per genuinely new or wrong term, no common words recognition already gets right. Frame every write honestly: it's a *suggestion*, queued, applied only when the user confirms it in Talkie (with an Undo) — never claim you changed their recognition.

## If a talkie tool isn't available

If these tools don't appear — or `get_dictionary` and the dictionary writers are missing while the six recall tools are present — the user is on a Talkie build **older than the one that bundles the current MCP server** (or Talkie.app isn't installed). Tell them to update Talkie.app and reconnect the connector; don't fabricate content. To point at a source build instead of the installed app:

```json
{ "mcpServers": { "talkie": { "command": "/absolute/path/to/your/Talkie.app/Contents/MacOS/talkie-mcp" } } }
```

Then run `/reload-plugins`.
