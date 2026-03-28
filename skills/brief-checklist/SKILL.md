---
description: "Based on the diff between the current branch and develop, generate a priority-sorted human review checklist."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Based on the diff between the current branch and develop, generate a priority-sorted human review checklist.

Arguments: $ARGUMENTS
- No arguments: compare develop...HEAD
- `--base <branch>`: specify the comparison base branch
- `--commits`: only look at the most recent commit's changes

## Execution Steps

1. Determine the comparison scope
   - Default: `git diff develop...HEAD`
   - If `--base` is specified, replace develop with that branch
   - If `--commits` is specified, use `git diff HEAD~1...HEAD`
   - Also run `git log <base>...HEAD --oneline` to get the commit list

2. Read the full contents of all files involved in the diff (not just the diff fragments — understand the context)

3. Evaluate each change along the following dimensions and assign a priority:

   **P0 — Must be human-reviewed** (architecture / interface / cross-module impact)
   - Public interface changes
   - New cross-.asmdef module dependencies
   - Data format changes (schema, save-file compatibility)
   - State management / lifecycle changes (init order, destroy logic)
   - Matches anti-patterns defined in the project's AGENTS.md
   - Global static state (static List/Dictionary/Instance) isolation in multi-instance scenarios
   - Resource cleanup / event unsubscription: is OnDestroy complete for new components, is there a cleanup path for plain C# objects

   **P1 — Worth a look** (core logic changes)
   - Business logic branches / condition changes
   - Performance-sensitive paths (Update / FixedUpdate / high-frequency callbacks), especially O(N²) patterns
   - Error handling / edge cases
   - Newly added public methods or classes
   - Review depth for new modules should be proportional to code volume (e.g., 1000+ line new module warrants at least 3-5 review items)

   **P2 — Quick scan** (low risk)
   - Pure getters/setters, logging, comment changes
   - Test code
   - Configuration tweaks (minor value adjustments)

4. Output format:

```
## Files Under Review

Summary of all C# files to review, grouped by priority, for easy batch opening:

| File | Priority | Change Summary |
|------|----------|----------------|
| `Assets/Scripts/.../GameManager.cs` | P0 | Core game loop changes |
| `Assets/Scripts/.../PlayerController.cs` | P0 | Input handling refactor |
| `Assets/Scripts/.../InventorySystem.cs` | P1 | Data model migration |
| ... | ... | ... |

File list generation rules:
- Obtain all changed C# files from `git diff <base>...HEAD --name-only -- '*.cs'`
- Tag each file with its highest priority across all review items (P0 > P1 > P2)
- Files with code changes but no review items are tagged `--` (no separate review needed)
- Sort by priority: P0 first, `--` last
- Exclude pure test files (unless the test itself has a review item)

---

## P0 — Must Be Human-Reviewed
1. **filename:line** — one-sentence description of the change
   Risk: why this needs attention
   Suggestion: what to focus on during human review

## P1 — Worth a Look
2. **filename:line** — one-sentence description of the change
   Suggestion: what to check

## P2 — Quick Scan
3. **filename:line** — one-sentence description

---
## PR Summary (ready to paste into PR description)
### Title
- Key change 1
- Key change 2

**Affected modules**: module list
**Tests**: attach test status if known
```

## Output File

Write the full result to `Docs/<branch-name>/pr-review_<timestamp>.md`.
- Branch name: take the current branch name and replace `/` with `_` (e.g., `git branch --show-current | tr '/' '_'`)
- Timestamp format: `YYYY-MM-DD-HHmm` (e.g., `2026-03-17-1430`)
- Create the directory if it does not exist
- Inform the user of the file path after writing

## Notes

- Within each priority level, also sort items by importance
- P0 items must include a specific risk description and review guidance
- Do not list every change — only list items with review value. Skip purely mechanical changes (import reordering, blank lines)
- PR Summary should be concise: 3-5 bullet points, do not restate the diff
- If the diff is empty, simply inform the user that the current branch has no differences from the base
