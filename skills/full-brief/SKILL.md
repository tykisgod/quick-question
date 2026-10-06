---
description: "Composite command: run /qq:brief and /qq:timeline in parallel, generating a complete PR review package."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Arguments: $ARGUMENTS
- No arguments: compare against the default base branch (develop if it exists, else main, else master)
- `--base <branch>`: specify the comparison base branch

## Execution Steps

1. Obtain a shared timestamp before launching agents, and pass it (with any `--base`) to both.

2. Use two parallel agents to execute:
   - Agent 1: follow the complete instructions of `/qq:brief` to generate the architecture change document + PR review checklist
   - Agent 2: follow the complete instructions of `/qq:timeline` to generate the commit timeline + phase-grouped review documents

3. Once both agents complete, (re)generate `REVIEW_GUIDE.md` per `/qq:timeline` step 6 so it indexes all four documents, then report the paths.

## Output Files

All files go to the same directory, sharing the same timestamp:
- `Docs/qq/<branch-name>/arch-review_<timestamp>.md`
- `Docs/qq/<branch-name>/pr-review_<timestamp>.md`
- `Docs/qq/<branch-name>/timeline-arch_<timestamp>.md`
- `Docs/qq/<branch-name>/timeline-review_<timestamp>.md`
- `Docs/qq/<branch-name>/REVIEW_GUIDE.md` (no timestamp)
