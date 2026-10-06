---
description: "Summarize all changes Claude Code made during this conversation."
---

> Run qq scripts as `${CLAUDE_PLUGIN_ROOT}/bin/<name>`: they are not on PATH, so a bare `qq-run-record.py` exits 127.

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

## Behavior

Identify all **file changes actually executed** by Claude in this conversation (via Edit/Write/Bash tools) and summarize them grouped by logic.

**The data source is the conversation context, not git diff** — include every round, committed or not.

After producing the summary, if `qq-run-record.py` is available, persist a `changes` run record so controller state can advance:

```bash
qq-run-record.py record \
  --project . \
  --stage changes \
  --command qq:changes \
  --status checked \
  --summary "Conversation change summary captured" \
  --capture-local-changes
```

## Output format

```
## Summary of changes in this conversation

### <Group 1 title>
- What was done
- Key files: ...

### <Group 2 title>
- ...

### Status
- Committed: <list of commit hashes, if any>
- Uncommitted: <list of files, if any>
- Compilation: passed / not verified
- Tests: N/N passed / not run
```

## Notes

- List the main file paths for each group (omit the `Assets/Scripts/` prefix to save space)
- If there are architectural changes (file moves, namespace changes, asmdef changes), call them out separately
- `.meta` files do not need to be mentioned
- If there were multiple rounds of changes in the conversation (e.g., did A first, then changed B), group them in chronological order
- If any changes were rolled back or overwritten, show only the final state, but note "tried X then changed to Y"
