---
description: "Summarize all changes Claude Code made during this conversation."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Summarize all changes Claude Code made during this conversation.

## Behavior

Review the current conversation context and identify all **file changes actually executed** by Claude in this conversation (file modifications made via Edit/Write/Bash tools), then summarize them grouped by logic.

**The data source is the conversation context, not git diff.** The user may have gone through multiple rounds of changes in a single conversation — some already committed, some not. Summarize all of them.

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
