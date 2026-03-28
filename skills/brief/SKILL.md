---
description: "Composite command: run /qq:brief-arch and /qq:brief-checklist in sequence, writing output to the same branch directory."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Composite command: run /qq:brief-arch and /qq:brief-checklist in sequence, writing output to the same branch directory.

Arguments: $ARGUMENTS
- No arguments: compare develop...HEAD
- `--base <branch>`: specify the comparison base branch

## Execution Steps

1. Use two parallel agents to execute respectively:
   - Agent 1: execute `/qq:brief-arch` to generate the architecture change document
   - Agent 2: execute `/qq:brief-checklist` to generate the PR review checklist

2. Once both agents complete, inform the user of both file paths

## Output Files

Both files go to the same directory and share the same timestamp:
- `Docs/<branch-name>/arch-review_<timestamp>.md`
- `Docs/<branch-name>/pr-review_<timestamp>.md`

Obtain the timestamp once before launching, and share it between both agents.
