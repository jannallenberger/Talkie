# Smoke test (5 minutes)

Run after any fresh install (`./scripts/run.sh`) or update, before trusting the
build for real use. Record the SHA and a pass/fail for each step.

1. **Provenance check.** Run `./scripts/verify_build.sh`. It must print
   `✓ MATCHES origin/main`. If it prints `✗ STALE / dirty`, the installed app
   does not match `origin/main` — rebuild before continuing.
2. **Settings ▸ Developer ▸ This build.** Confirm the subtitle shows
   `branch@sha` and that it matches your current `HEAD` (`git rev-parse
   --short HEAD`).
3. **Dictionary undo.** Trigger a learned/MCP suggestion pill and click
   **Undo** (accessibility id `talkie.pill.undo`). Expect the pill to show
   "Reverted" and the rule to be gone — verify via the Talkie MCP
   `get_dictionary` tool.
4. **Cleanup switcher.** Click the cleanup switcher (accessibility id
   `talkie.pill.cleanupSwitch`). Confirm the cleanup style cycles.
5. **Dictation sanity.** Dictate one sentence containing the word "pill" and
   confirm it inserts "pill" (not a mis-transcription).
6. **Pill hover pause.** Hover the pill mid-collapse and confirm the
   countdown pauses while the cursor is over it.

Record: SHA tested, and pass/fail for each of the 6 steps above.
