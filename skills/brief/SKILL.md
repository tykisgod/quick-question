---
description: "Composite command: run brief-arch, brief-checklist, and timeline in parallel, generating a complete PR review package."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Composite command: run `/qq:brief-arch`, `/qq:brief-checklist`, and `/qq:timeline` in parallel, generating a complete PR review package.

Arguments: $ARGUMENTS
- No arguments: compare develop...HEAD
- `--base <branch>`: specify the comparison base branch

## Execution Steps

1. Obtain a shared timestamp before launching agents.

2. Use three parallel agents to execute:
   - Agent 1: execute `/qq:brief-arch` to generate the architecture change document
   - Agent 2: execute `/qq:brief-checklist` to generate the PR review checklist
   - Agent 3: execute `/qq:timeline` to generate the commit timeline with phase-grouped review documents

3. Once all three agents complete, inform the user of all file paths.

## Output Files

All files go to the same directory, sharing the same timestamp:
- `Docs/<branch-name>/arch-review_<timestamp>.md`
- `Docs/<branch-name>/pr-review_<timestamp>.md`
- `Docs/<branch-name>/timeline-arch_<timestamp>.md`
- `Docs/<branch-name>/timeline-code-review_<timestamp>.md`

Obtain the timestamp once before launching, and share it between all agents.
