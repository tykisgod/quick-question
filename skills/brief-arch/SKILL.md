---
description: "Compare the architectural changes between the current branch and develop, presenting the structural changes from high to low level using Mermaid diagrams and written explanations."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Compare the architectural changes between the current branch and develop, presenting the structural changes from high to low level using Mermaid diagrams and written explanations.

Arguments: $ARGUMENTS
- No arguments: compare develop...HEAD
- `--base <branch>`: specify the comparison base branch

## Difference from /review

/review is a line-by-line code review checklist focused on "which lines of code carry risk."
This command focuses on "how the system structure changed," helping build a global mental model before diving into review.

## Execution Steps

1. Collect the change scope
   - `git diff <base> HEAD --name-only | grep '\.cs$'` — all changed C# files
   - `git diff <base> HEAD --diff-filter=A --name-only | grep '\.cs$'` — newly added files
   - `git log <base>..HEAD --oneline` — commit list
   - Group and count changes by Service module (must cover all changed modules, no small modules omitted)
   - Use `git diff <base> HEAD --numstat` for accurate added/deleted line counts per module

2. Identify architectural changes (ordered by importance, highest first)

   **Tier 1 — Cross-module contract changes**
   - Interface additions/modifications under Contracts/
   - .asmdef dependency changes (new cross-module references)
   - Public enum/data structure changes
   - Isolation of global static state (static lists/dicts) in multi-instance scenarios
   - Check whether new code introduces anti-patterns defined in the project's AGENTS.md (e.g., FindObjectOfType)

   **Tier 2 — New modules/subsystems**
   - New Service modules or subdirectories
   - New Manager/Factory/Registry classes
   - New state machines or process orchestration

   **Tier 3 — Internal refactoring of existing modules**
   - Initialization flow changes (Awake/Start → lifecycle interfaces)
   - Singleton → dependency injection pattern changes
   - Data flow direction changes

   **Tier 4 — Extension points / configuration changes**
   - New interface implementations
   - CSV/Config structure changes
   - New events/callbacks

3. Draw a Mermaid diagram for each Tier

   For each architectural change, use the diagram type that best captures its essence:
   - **Module dependency changes** → `graph LR` dependency diagram, color-coded: new (green) / modified (orange) / deleted (red)
   - **Data flow / lifecycle changes** → `sequenceDiagram` or `flowchart`
   - **State machines** → `stateDiagram-v2`
   - **Class relationship changes** → `classDiagram`

   Diagram requirements:
   - Each diagram must have a title explaining "before vs. after" or "what was added"
   - Use `style` or `:::` syntax to highlight new (green) and modified (orange) nodes
   - Keep diagrams concise — no more than 15 nodes per diagram; split complex systems across multiple diagrams
   - Focus on the changed parts; stable unchanged modules can be simplified to a single node

4. Output format

```
# Architecture Change Overview

> X modules affected, Y new modules, Z contract changes

## Tier 1 — Cross-module Contract Changes (Highest Priority)

### 1.1 Change Title
**Scope**: which modules are affected
**Essence**: one sentence describing how the structure changed

\```mermaid
<diagram>
\```

**Key points**:
- Key decisions or trade-offs
- Impact on downstream modules

## Tier 2 — New Modules / Subsystems
...（same format）

## Tier 3 — Internal Refactoring of Existing Modules
...

## Tier 4 — Extension Points / Configuration Changes
...

## Module Change Heatmap

| Module | New Files | Modified Files | +Lines | Main Change |
|--------|-----------|----------------|--------|-------------|
| ...    | ...       | ...            | ...    | one sentence |

Notes:
- Heatmap must cover all changed modules — do not omit any (including DevTools, Editor, UI, etc.)
- New/modified file counts must be accurately derived via `--diff-filter=A` and `--diff-filter=M`, not estimated
- Sort by +Lines descending
```

## Output File

Write the full result to `Docs/<branch-name>/arch-review_<timestamp>.md`.
- Branch name: take the current branch name and replace `/` with `_` (e.g., `git branch --show-current | tr '/' '_'`)
- Timestamp format: `YYYY-MM-DD-HHmm` (e.g., `2026-03-17-1430`)
- Create the directory if it does not exist
- Inform the user of the file path after writing

## Notes

- Order from most important to least; the reader should be able to grasp the key architectural changes just from Tier 1
- Diagrams are the core output, not decoration. Every architectural change must have at least one diagram
- Written explanations should be concise — explain "why it changed this way," not just restate the diff
- If a change involves initialization order, a sequence diagram is required
- Stable, unchanged modules should appear in diagrams in gray/dashed style as reference points only
- If the diff is empty, simply inform the user that the current branch has no architectural differences from the base
