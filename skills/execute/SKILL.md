---
description: "Smart implementation — read a plan, execute step by step with auto-compilation, subagent dispatch for large tasks, and checkpoint-based resume."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Read a plan, execute it fully. Execution is always automatic — never ask "proceed?" or "start?" during implementation. The user invoked execute; that IS the go-ahead.

Arguments: $ARGUMENTS
- A file path to a plan/design document
- `--no-worktree`: skip worktree guard
- `--auto`: after completion, auto-select and run the next workflow step instead of asking the user (includes push — user should be aware)
- No arguments: detect the plan source from conversation or `Docs/qq/`

## 1. Worktree Guard

If already in a worktree, skip. If not, and `--no-worktree` was not passed:
1. Derive a slug from the plan filename.
2. Call `EnterWorktree` with `name: <slug>`.
3. If unavailable, fall back to `qq-worktree.py create --name <slug>`, then tell the user to reopen in the new path and stop.
4. Seed runtime cache: `qq-worktree.py seed-runtime-cache --project . --source "<SOURCE_PROJECT>"`

## 2. Locate Plan & Resume

Find the plan (user arg → conversation → `Docs/qq/` scan → ask).

**Resume check:** Run:
```bash
qq-execute-checkpoint.py resume --project .
```
If it returns progress with `status: "running"` or `"paused"`, resume from the first uncompleted step. Report: "Resuming from step N (steps 1–M already complete)."

If empty, fall back to scanning the plan for checked boxes (`- [x]`) for backward compatibility.

## 3. Analyze & Start

Read the plan. Read CLAUDE.md and AGENTS.md (if it exists).

**Do NOT write a new plan, enter plan mode, or save files to `.claude/plans/`.** The plan already exists — your job is to execute it, not rewrite it.

Classify the plan:
- **Small** (≤8 steps touching ≤12 files): main agent executes directly, using subagents only for independent parallel files.
- **Large** (>8 steps or >12 files across >3 modules): main agent becomes a **coordinator only** — dispatch each phase/group as a subagent. Do NOT write implementation code in the main session.

Use judgment for borderline cases.

Output a brief summary to the user (plain text, not a file):
```
Executing: <plan name> (coordinator mode, N phases)
Phase 0: ... → Phase 1: ... → ...
```

Then initialize checkpoint and begin immediately:
```bash
qq-execute-checkpoint.py save \
  --project . --plan "<PLAN_PATH>" --step 0 --total <M> \
  --mode <coordinator|direct> --phase "<FIRST_PHASE>" --status running
```

## 4. Execute

Follow existing project patterns.

### Subagent context rule

**Always pass context inline in subagent prompts.** Never ask subagents to read CLAUDE.md, AGENTS.md, or the plan file — paste the relevant content directly. This saves tool calls and ensures subagents get exactly the context they need.

### Small task execution

For each step, decide:
- **Has dependencies on the previous step** → write it yourself (main session)
- **Independent files** → dispatch parallel subagents
- **Sequential chain (A→B→C)** → execute sub-steps one by one; consider subagents for long chains (4+) to prevent context accumulation

### Large task execution (coordinator mode)

**The main agent writes zero implementation code.** Execute phases in the order the plan specifies (which may not be numeric — e.g. Phase 9.1 before Phase 2).

**Dependency rule:** Read the plan to identify which phases are sequential (have dependencies) vs. parallel (independent). The plan typically indicates this explicitly (e.g. "Phase 3 + Phase 4 parallel").

**Sequential phases** (downstream depends on upstream interfaces):

For each phase, **all 5 steps are mandatory** — do not skip any:
1. **Dispatch** → implementation subagent
2. **Compile** → verify passes. If fails: dispatch fix subagent (max 3 rounds, then `--status paused`)
3. **Review** → dispatch review subagent. **This step is NOT optional.** Every phase gets reviewed before the next one starts.
4. **Fix** → if Critical: dispatch fix subagent → re-review (max 2 rounds)
5. **Checkpoint** → `qq-execute-checkpoint.py save`

THEN next dependent phase — not before step 5 completes.

**Parallel phases** (independent, no shared interfaces):
```
  1. Dispatch all parallel implementation subagents simultaneously
  2. Wait for all to complete → compile
  3. Dispatch review subagents for each (can also be parallel)
  4. Fix Criticals if any
  5. Checkpoint all completed phases
  6. THEN next group
```

**Key constraint:** Do NOT parallelize phases that have interface dependencies. If Phase B uses interfaces defined in Phase A, Phase A must complete review before Phase B starts — otherwise interface changes invalidate Phase B's work.

For truly large module-crossing refactors (10+ files, 3+ independent modules), consider dispatching subagents with `isolation: "worktree"` to avoid file conflicts.

**Implementation subagent context** — pass inline:
- The phase steps from the plan (only this phase, not the full plan)
- Interfaces/contracts created by completed phases (paste the actual code)
- CLAUDE.md and AGENTS.md rules

**Review subagent context** — pass inline:
- The phase steps (what was supposed to be implemented)
- Interfaces from prior phases (so the reviewer can check correct usage)
- The review prompt below

**Review prompt** (lightweight — not `/qq:claude-code-review`):
> "Review the changes made in [PHASE_NAME]. Check:
> 1. Do the new files follow project conventions?
> 2. Are interfaces from previous phases used correctly? [interfaces pasted above]
> 3. Any obvious bugs or missing error handling at system boundaries?
> Report findings as [Critical] / [Moderate] / [Minor]. Be concise."

**Checkpoint command** (this is NOT optional — it is a fixed workflow step):
```bash
qq-execute-checkpoint.py save \
  --project . --plan "<PLAN_PATH>" --step <N> --total <M> \
  --mode <MODE> --phase "<PHASE_NAME>" --step-title "<STEP_TITLE_TEXT>"
```
This atomically updates `.qq/state/execute-progress.json` AND the plan file checkbox. Do NOT Edit the plan file separately.

### Small task verification

After each step completes:
1. **Verify compilation** — fix before proceeding. If unfixable after 3 attempts, save `--status paused` and stop.
2. **Quick review** — for steps touching 3+ files, dispatch a lightweight review subagent (same prompt as coordinator mode). For 1-2 file changes, self-review is sufficient.
3. **Checkpoint** — same command as above.

## 5. Completion

Clear the checkpoint:
```bash
qq-execute-checkpoint.py clear --project .
```

Summarize: what was implemented, deviations from plan, issues resolved.

**Without `--auto`:** recommend next step, wait for user:
- Clean → `/qq:test`
- Needs coverage → `/qq:add-tests` then `/qq:test`
- Had issues → `/qq:best-practice`
- Multi-module → `/qq:claude-code-review`

**With `--auto`:** take the strictest path automatically:
`/qq:best-practice` → `/qq:claude-code-review` → `/qq:add-tests` → `/qq:test` → `/qq:commit-push`

## Rules

- Do not add features or abstractions beyond what the plan specifies
- Each .cs save triggers auto-compilation — never skip this
- If a step is significantly more complex than planned, note the deviation and continue
- If the plan is ambiguous or contradictory, use best judgment and note the decision
- Test steps → prefer `/qq:add-tests` over hand-writing test files
