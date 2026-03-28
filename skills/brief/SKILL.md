---
description: "Compare the current branch against develop and generate two review documents: architecture change diagram + PR review checklist."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Compare the current branch against develop and generate two review documents: architecture change diagram + PR review checklist.

Arguments: $ARGUMENTS
- No arguments: compare develop...HEAD
- `--base <branch>`: specify a custom base branch for comparison
- `--commits`: only look at the changes from the most recent commit

## Execution Steps

### Part 1: Collect Change Scope

- `git diff <base> HEAD --name-only | grep '\.cs$'` — get all changed C# files
- `git diff <base> HEAD --diff-filter=A --name-only | grep '\.cs$'` — get newly added files
- `git log <base>..HEAD --oneline` — get the commit list
- Group and count changes by module
- Use `git diff <base> HEAD --numstat` to get accurate added/deleted line counts per module

### Part 2: Architecture Change Diagram

Identify architectural changes, ordered from most to least significant:

**Tier 1 — Cross-module contract changes**
- Interface additions/modifications under Contracts/
- .asmdef dependency changes
- Public enum/data structure changes
- Global static state isolation in multi-instance scenarios
- Check anti-patterns defined in AGENTS.md

**Tier 2 — New modules/subsystems**
- New Service modules or subdirectories
- New Manager/Factory/Registry classes
- New state machines or process orchestration

**Tier 3 — Internal refactoring of existing modules**
- Initialization flow changes
- Pattern changes such as singleton → dependency injection
- Data flow direction changes

**Tier 4 — Extension points/configuration changes**
- New interface implementations
- Config structure changes
- New events/callbacks

Draw a Mermaid diagram for each Tier:
- **Module dependency changes** → `graph LR`, color-coded: new (green) / modified (orange) / deleted (red)
- **Data flow / lifecycle** → `sequenceDiagram` or `flowchart`
- **State machines** → `stateDiagram-v2`
- **Class relationships** → `classDiagram`

Diagram requirements:
- Each diagram has a title indicating "Before vs After"
- Use `style` or `:::` to annotate added and modified nodes
- No more than 15 nodes per diagram
- Stable, unchanged modules use gray/dashed styling

### Part 3: PR Review Checklist

Read the full content of all files touched by the diff, and evaluate across these dimensions:

**P0 — Must be human-reviewed**
- Public interface changes
- New cross-.asmdef module dependencies
- Data format changes
- State management / lifecycle changes
- Anti-pattern matches from AGENTS.md
- Global static state isolation
- Resource cleanup / event unsubscription

**P1 — Recommended attention**
- Business logic branches / condition changes
- Performance-sensitive paths (O(N²) patterns)
- Error handling / edge cases
- New public methods or classes

**P2 — Quick scan**
- Pure getter/setter, logging, comment changes
- Test code
- Config value tweaks

### Part 4: Output

Write two files to the same directory:

**File 1: `Docs/qq/<branch-name>/arch-review_<timestamp>.md`**
```
# Architecture Change Overview

> X modules affected, Y new modules, Z contract changes

## Tier 1 — Cross-module contract changes
### 1.1 Change Title
**Scope**: which modules are affected
**Nature of change**: one sentence

```mermaid
<diagram>
```

**Key points**: explanation of key decisions

## Tier 2/3/4 ... (same format)

## Module Change Heatmap
| Module | New Files | Modified Files | +Lines | Key Changes |
|--------|-----------|---------------|--------|-------------|
```

**File 2: `Docs/qq/<branch-name>/pr-review_<timestamp>.md`**
```
## Review File Overview
| File | Priority | Change Summary |
|------|----------|---------------|

---
## P0 — Must be human-reviewed
1. **Filename:line** — description
   Risk: ...
   Suggestion: ...

## P1 — Recommended attention
## P2 — Quick scan

---
## PR Summary (ready to paste into PR description)
```

Branch name: use `git branch --show-current | tr '/' '_'`.
Timestamp format: `YYYY-MM-DD-HHmm`.
Both files share the same timestamp.

## Notes

- Tier 1 is the core deliverable of the architecture diagram — readers should grasp the most critical changes from Tier 1 alone
- Diagrams are the core output, not decoration. Every architectural change must have at least one diagram
- The heatmap must cover all modules with changes — none may be omitted
- P0 items in the PR review checklist must include specific risk descriptions and review guidance
- If the diff is empty, simply tell the user that the current branch has no differences from the base
