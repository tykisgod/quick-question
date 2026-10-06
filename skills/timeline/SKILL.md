---
description: "Group the current branch's commit history into semantic phases along a timeline, and generate two review documents: architecture evolution + code review."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Arguments: $ARGUMENTS
- No arguments: compare against the default base branch (develop if it exists, else main, else master)
- `--base <branch>`: specify a custom base branch for comparison

## Execution Steps

### 1. Collect Commit History

```bash
git log <base>..HEAD --oneline --reverse --format="%h %ai %s"
```

### 2. Group Commits into Semantic Phases

Grouping criteria (in order of priority):
1. **Semantic affinity**: consecutive commits on the same feature/subsystem go in the same group
2. **Natural breakpoints**: merge commits, date gaps > 1 day, module switches
3. **Phase markers in commit messages**: if a commit self-annotates with a Phase, respect that first

Give each Phase a semantic name (e.g. "Player Health System", not "Phase 1"). Target 5–10 Phases (too few loses the timeline's value; too many becomes per-commit annotation); a Phase of more than 15 commits may be split into sub-phases. Grouping is the judgment the whole document rests on — settle it before writing.

### 3. Analyze Changes per Phase

For each Phase:
```bash
git diff <phase_first_commit>~1..<phase_last_commit> --stat
git diff <phase_first_commit>~1..<phase_last_commit> -- '*.cs'
```

Read the full content of key changed files to understand context — not just diff fragments.

### 4. Generate Document A: Architecture Evolution Timeline

Format:
```markdown
# Architecture Evolution Timeline

> X phases, Y commits, Z-day development span
> Branch: `<branch>`, base: `<base>`

---

## Phase 1: <Semantic Name> (<date range>, N commits)

> One-sentence summary

<details>
<summary>Commits</summary>

- `hash1` message1
- `hash2` message2
</details>

### Architecture Changes

#### [Tier 1] Change Title (if any)
**Scope**: ...
**Nature of change**: ...

\```mermaid
<diagram of this phase's changes>
\```

#### [Tier 2] Change Title (if any)
...

### Dependencies Introduced This Phase
- `ModuleA` → `ModuleB` (new reference)

### Cumulative State
> Overall progress to this point: X completed, next phase will Y

---

## Phase 2: <Semantic Name> ...
```

**Diagram requirements**:
- Each diagram shows only what this phase changed, not the accumulated state — a reviewer should see "what was added in this phase"
- Use green to highlight parts newly added in this phase, gray for existing context
- If this phase modifies a structure introduced in a previous phase, use orange to highlight it
- A Phase with no architecture changes (pure bug fix/UI) gets a one-line note instead of a diagram

### 5. Generate Document B: Code Review Timeline

Format:
```markdown
# Code Review Timeline

> X phases, Y commits
> Branch: `<branch>`, base: `<base>`

## Review Priority Quick Reference

| Phase | P0 | P1 | P2 | Files | Est. Time | Core Risk |
|-------|----|----|----|-------|-----------|-----------|
| 1. Name | 0 | 2 | 1 | 5 | 10 min | No major risk |
| 2. Name | 3 | 1 | 0 | 12 | 25 min | Global static state isolation |
| ... | | | | | | |

Time estimation rules:
- Each P0 item ~5 min (requires reading context + verification)
- Each P1 item ~2 min (quick check)
- Each P2 item ~0.5 min (quick scan)
- Round up to the nearest 5 minutes

**Recommended review order**: sort by P0 count descending — review the highest-risk phases when most focused

---

## Phase 1: <Semantic Name> (<date range>, N commits)

> One-sentence summary

<details>
<summary>Commits</summary>

- `hash1` message1
- `hash2` message2
</details>

### Files to Review

C# files touched in this phase, by priority:

| File | Priority | Change Summary |
|------|----------|---------------|
| `Assets/Scripts/.../GameManager.cs` | P0 | Core game loop changes |
| `Assets/Scripts/.../PlayerController.cs` | P0 | Input handling refactor |
| `Assets/Scripts/.../InventorySystem.cs` | P1 | Data model migration |
| ... | P2 | ... |

File list generation rules:
- Obtain from `git diff <phase_first_commit>~1..<phase_last_commit> --name-only -- '*.cs'`
- Exclude pure asset/config files, and test files under `Tests/` (unless the tests themselves have P0/P1 review items)
- Exclude pure Editor tool files (unless they have review items)
- Each file is annotated with its highest priority level from this Phase's review items
- Files with no review items are annotated `--` (no separate review needed)
- Sort by priority: P0 first, `--` last

### P0 — Must be human-reviewed
1. **Filename:line** — change description
   Risk: why this needs attention
   Suggestion: what to focus on during review

### P1 — Recommended attention
2. **Filename:line** — change description
   Suggestion: checkpoints

### P2 — Quick scan
3. **Filename:line** — description

---

## Phase 2: ...
```

**P0/P1/P2 Assessment Criteria** (consistent with /qq:brief):

- **P0**: Public interface changes, new cross-module dependencies, data format changes, state management/lifecycle changes, global static state isolation, anti-patterns (FindObjectOfType, etc.), resource cleanup/event unsubscription
- **P1**: Business logic branches, performance-sensitive paths (Update/FixedUpdate), O(N²) patterns, error handling/edge cases, new public methods or classes
- **P2**: Pure getters/setters/logging/comments, test code, config value tweaks

**Key rule**: Each review item appears only in **the phase that introduced it** — do not repeat it in later phases.
If a later phase modifies code from an earlier phase, annotate it in that later phase as "modifies Phase X's ...".

### 6. Generate Document C: Review Guide

Generate `REVIEW_GUIDE.md`, indexing whichever documents exist in `Docs/qq/<branch-name>/`.

Format:
```markdown
# Review Guide

> Branch: `<branch>`
> Generated: `<timestamp>`

## Document Index

| Document | Perspective | Purpose |
|----------|-------------|---------|
| `timeline-arch_<ts>.md` | Timeline × Architecture | Understand how the architecture evolved in development order |
| `timeline-review_<ts>.md` | Timeline × Review | Review code phase by phase, each with a file list |
| `arch-review_<ts>.md` | Final state × Architecture | Final architecture overview + module heatmap (if exists) |
| `pr-review_<ts>.md` | Final state × Review | Full final P0/P1/P2 list (if exists) |

If a document does not exist, annotate in the table "Not generated — run `/qq:brief` to generate".

## Reading Order

### Scenario A: First time looking at this branch

Use when: just picked it up, cross-team review, or returning after a long break

1. **timeline-arch** — follow the timeline to understand "how it got to this state", build a mental model
2. **arch-review** — view the final architecture overview and confirm the model is complete
3. **timeline-review** — review code phase by phase (use the quick reference to pick high-risk phases first)
4. **pr-review** — final scan from the final-state perspective to catch systemic risks across phases

### Scenario B: Already familiar with the branch, reviewing code directly

Use when: self-reviewing your own code, routine incremental review

1. **timeline-review** — quick reference → pick phases with most P0s → file list → review each item
2. **pr-review** — catch what was missed: the final-state perspective may reveal cross-phase combination risks

> Skip the two arch documents in Scenario B — you already know the architecture.

## Self-Review Workflow

```
Run /qq:timeline
  ↓
Open timeline-review, check the quick reference table
  ↓
Select phases in descending P0 count order (review highest-risk phases when most focused)
  ↓
For each Phase:
  1. Open the "Files to Review" table → open all P0 files
  2. Go through P0 items one by one → verify against the code
  3. Quickly scan P1 → only check items marked "Suggestion"
  4. Skip P2 (unless there's a question)
  5. Found an issue → fix it → commit
  ↓
All phases reviewed
  ↓
Make sure the project compiles, then run /qq:test to verify
  ↓
Optional: run /qq:brief to generate final-state docs for last-pass coverage
  ↓
Merge
```

## Time Budget

Summarize from the `timeline-review` quick reference table:

| Phase | Estimated Time |
|-------|---------------|
| (copied from quick reference) | |
| **Total** | **X min** |
```

### 7. Output

Write three files to `Docs/qq/<branch-name>/`:
- `timeline-arch_<timestamp>.md`
- `timeline-review_<timestamp>.md`
- `REVIEW_GUIDE.md` (no timestamp, overwritten each time)

Branch name rule: use the current branch name, replacing `/` with `_`.
Timestamp format: `YYYY-MM-DD-HHmm`.

## Notes

- Both timeline documents use identical Phase numbers and names
- A Phase with no points worth reviewing gets "No additional review needed for this phase" in the review document
