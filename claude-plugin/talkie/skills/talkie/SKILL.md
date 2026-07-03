---
name: talkie
description: Recall the user's own meetings, daily brief, commitments, people/projects, and past dictations from their local Talkie app. Use whenever they ask "what did I say about…", "what did we decide in that meeting", "what am I on the hook for", "who is <name>", "what's on my brief today", or otherwise reference their own spoken history, notes, or context. All data is on-device via the Talkie MCP server — nothing leaves their Mac.
---

# Talkie recall

The **talkie** MCP server exposes the user's local Talkie data — meetings, today's brief, their context graph (people, projects, commitments), and dictation history. Everything is read on-device; nothing is sent anywhere. Use these tools to ground answers in what the user actually said or did, rather than guessing.

## The six tools

| Tool | Use it for | Key args |
|---|---|---|
| `search` | The default for recall. Semantic + keyword across meetings, dictations, and entities — finds by meaning ("shipping the updater" matches "release the auto-update build"). | `query`; optional `limit`, `sources` (`meetings\|dictations\|entities`) |
| `list_meetings` | Browse recent meetings (id, title, date, participants, one-line summary). | optional `limit`, `query` |
| `get_meeting` | Full summary + transcript of one meeting. | one of `id` / `title` / `date` (yyyy-MM-dd) |
| `get_brief` | Today's on-device brief — what they worked on, commitments, open threads. | none |
| `list_commitments` | Open action items from the context graph, newest first. | optional `limit` |
| `lookup_entity` | Resolve a person / project / term by name or alias, with provenance. | `query`; optional `kinds` (`person\|project\|term\|commitment`) |

## Workflows

- **"Pull the action items from my last meeting."** `list_meetings` (limit 1) to get the most recent → `get_meeting` by that `id` → extract the commitments; cross-check with `list_commitments`.
- **"What did I say about <topic>?" / "what did we decide about X?"** Lead with `search` (`query` = the topic). Open any promising hit with `get_meeting` for the full transcript.
- **"Cite today's brief."** `get_brief`, then quote the relevant line back with its source.
- **"Who is <name>?" / "what's the status of <project>?"** `lookup_entity` (`query` = the name). Narrow with `kinds` when the name is ambiguous.
- **"What am I on the hook for?"** `list_commitments`.

Prefer `search` when you don't know which surface holds the answer — it spans all three. Reach for the specific tools when the user already named a meeting, person, or "today."

## If a talkie tool isn't available

If these tools don't appear, the user is on a Talkie build **older than the one that bundles the MCP server** (or Talkie.app isn't installed). Tell them to update Talkie.app, or point `.mcp.json` at a source build instead of the installed app:

```json
{ "mcpServers": { "talkie": { "command": "/absolute/path/to/your/Talkie.app/Contents/MacOS/talkie-mcp" } } }
```

Then run `/reload-plugins`. Don't fabricate meeting content — if the tools are missing, say so.

## Coming soon

Teach-back — suggesting a jargon term or a spoken→written correction to the user's Talkie dictionary so recognition spells it right next time — ships as a separate capability. It is **not** part of this skill yet; don't claim to add dictionary terms.
