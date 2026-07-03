---
name: talkie-brief
description: Show and work from the user's Talkie daily brief — what they worked on today, their open commitments, and open threads — pulled on-device. Invoke directly with /talkie:talkie-brief, or when the user asks to see, summarize, or act on "my brief" / "today's brief".
disable-model-invocation: false
---

# Today's Talkie brief

Call the `get_brief` tool (from the talkie MCP server) and present today's on-device brief:

1. **What I worked on** — a short recap.
2. **Open commitments** — the action items, each with who/what if known. If the brief is thin here, also call `list_commitments` to fill it in.
3. **Open threads** — anything unresolved worth following up.

Quote lines from the brief rather than paraphrasing loosely, and keep it scannable. If the user then asks to draft a follow-up or dig into one item, use `get_meeting` or `search` to pull the underlying detail.

If the `get_brief` tool isn't available, the user's Talkie build predates the bundled MCP server (or Talkie.app isn't installed) — tell them to update Talkie.app rather than inventing a brief. See the main `talkie` skill for the source-build `.mcp.json` fallback.
