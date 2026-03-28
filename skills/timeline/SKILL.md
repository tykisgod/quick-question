---
description: "Group the current branch's commit history into semantic phases along a timeline, and generate two review documents: architecture evolution + code review."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Group the current branch's commit history into semantic phases along a timeline, and generate two review documents: architecture evolution + code review.

Arguments: $ARGUMENTS
- No arguments: diff against develop...HEAD
- `--base <branch>`: specify a custom base branch for comparison

## Core Concept

Unlike `/qq:arch-review` (final-state snapshot × Tier grouping) and `/qq:pr-review` (final-state snapshot × Priority grouping),
this command groups commits by **timeline phases**, helping reviewers build a mental model in development order while preserving priority annotations.

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

Each Phase requires:
- A semantic name (e.g. "Player Health System", not "Phase 1")
- Date range
- List of commits (hash + one-line description)
- One-sentence summary

Target: 5–10 Phases (too few loses timeline value; too many becomes per-commit annotation)

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
<diagram: show the architectural changes introduced in this phase, not the accumulated final state>
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
- Each diagram shows the **incremental changes in this phase**, not the accumulated final state up to this point
- Use green to highlight parts newly added in this phase, gray for existing context
- If this phase modifies a structure introduced in a previous phase, use orange to highlight it

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

List C# files involved in this phase by priority (exclude pure asset/config/test files), annotated with the highest priority level:

| File | Priority | Change Summary |
|------|----------|---------------|
| `Assets/Scripts/.../GameManager.cs` | P0 | Core game loop changes |
| `Assets/Scripts/.../PlayerController.cs` | P0 | Input handling refactor |
| `Assets/Scripts/.../InventorySystem.cs` | P1 | Data model migration |
| ... | P2 | ... |

File list generation rules:
- Obtain from `git diff <phase_start>..<phase_end> --name-only -- '*.cs'`
- Exclude test files under `Tests/` (unless the tests themselves have P0/P1 review items)
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

**P0/P1/P2 Assessment Criteria** (consistent with /qq:pr-review):

- **P0**: Public interface changes, new cross-module dependencies, data format changes, state management/lifecycle changes, global static state isolation, anti-patterns (FindObjectOfType, etc.), resource cleanup/event unsubscription
- **P1**: Business logic branches, performance-sensitive paths (Update/FixedUpdate), O(N²) patterns, error handling/edge cases, new public methods or classes
- **P2**: Pure getters/setters/logging/comments, test code, config value tweaks

**Key rule**: Each review item appears only in **the phase that introduced it** — do not repeat it in later phases.
If a later phase modifies code from an earlier phase, annotate it in that later phase as "modifies Phase X's ...".

### 6. Generate Document C: Review Guide

Generate `REVIEW_GUIDE.md` (no timestamp, overwrite each time), with content dynamically populated based on documents already present in the current directory.

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

If a document does not exist, annotate in the table "Not generated — run `/qq:review` to generate".

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
Run /unity-compile + /qq:ut to verify
  ↓
Optional: run /qq:review to generate final-state docs for last-pass coverage
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

Write three files to `Docs/<branch-name>/`:
- `timeline-arch_<timestamp>.md`
- `timeline-review_<timestamp>.md`
- `REVIEW_GUIDE.md` (no timestamp, overwritten each time)

Branch name rule: use the current branch name, replacing `/` with `_`.
Timestamp format: `YYYY-MM-DD-HHmm`.

## Notes

- Phase grouping is the most critical judgment in this command — poor grouping makes the entire document useless. Take extra time to group well rather than rushing to write content
- The two documents must have completely identical Phase numbers and names for easy cross-reference
- Architecture diagrams show increments, not the accumulated state — reviewers should be able to see "what was added in this phase"
- If a Phase has no architecture changes (pure bug fix/UI), briefly note it in the arch document — no need to force a diagram
- If a Phase has no points worth reviewing, note "No additional review needed for this phase" in the review document
- Each Phase's analysis should be based on the actual diff for that phase, not speculation
- For large Phases (>15 commits), you may further split into sub-phases
