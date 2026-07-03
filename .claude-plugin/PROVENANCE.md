# marketplace.json — spec provenance

The Claude Code plugin/marketplace schema iterates fast, so this records what
`marketplace.json` (and the sibling `claude-plugin/talkie/` plugin) were written
against. `marketplace.json` itself can't hold this note: the installed
`claude plugin validate` rejects any unrecognized top-level or entry-level key
(including `$schema` and a comment key) as a hard error, so the manifests are
kept to recognized keys only.

**Verified on 2026-07-03** against the official Claude Code docs:

- Marketplace shape (`name`, `owner{name,email?}`, `plugins[]`; same-repo plugin
  `source` is a relative string starting with `./`, resolved from the repo root):
  https://code.claude.com/docs/en/plugin-marketplaces
- Plugin manifest (`.claude-plugin/plugin.json`; only `name` required):
  https://code.claude.com/docs/en/plugins-reference#plugin-manifest-schema
- MCP config location (`.mcp.json` at plugin root, `mcpServers` map):
  https://code.claude.com/docs/en/plugins-reference#mcp-servers
- Skills (`skills/<name>/SKILL.md`, `description` frontmatter):
  https://code.claude.com/docs/en/skills
- Install syntax `/plugin install <plugin>@<marketplace>`:
  https://code.claude.com/docs/en/discover-plugins

**Validator note:** validated green with `claude plugin validate .` and
`claude plugin validate ./claude-plugin/talkie` on Claude Code **2.1.79**. That
version is stricter than the current docs (which say unrecognized keys are
warnings) — it errors on them — so no `$schema`/comment keys are present in the
JSON. Re-verify the live schema before editing these files.
