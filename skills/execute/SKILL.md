---
description: "Smart implementation — read a plan, execute step by step with auto-compilation, subagent dispatch for large tasks, and checkpoint-based resume."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Read a plan, execute it fully. Execution is always automatic — never ask "proceed?" or "start?" during implementation. The user invoked execute; that IS the go-ahead.

Arguments: $ARGUMENTS
- A file path to a plan/design document
- `--no-worktree`: skip worktree guard
- `--auto`: after completion, auto-select and run the next workflow step instead of asking the user
- No arguments: detect the plan source from conversation or `Docs/qq/`

## 1. Worktree Guard

If already in a worktree, skip. If not, and `--no-worktree` was not passed:
1. Derive a slug from the plan filename.
2. Call `EnterWorktree` with `name: <slug>`.
3. If unavailable, fall back to `qq-worktree.py create --name <slug>`, then tell the user to reopen in the new path and stop.
4. Seed runtime cache: `qq-worktree.py seed-runtime-cache --project . --source "<SOURCE_PROJECT>"`

## 2. Locate Plan & Resume

Find the plan (user arg → conversation → `Docs/qq/` scan → ask).

**Resume check:** Scan the plan for checked boxes (`- [x]`). If found, skip those steps and report: "Resuming from step N (steps 1–M already complete)."

## 3. Analyze

Read the plan. Classify:
- **Small** (≤8 steps): main agent executes directly, using subagents only for independent parallel files.
- **Large** (>8 steps): main agent becomes a **coordinator only** — dispatch each phase/group as a subagent. Do NOT write implementation code in the main session.

Present a one-line-per-step breakdown, then immediately begin execution. No "Proceed?" prompt.

## 4. Execute

Read CLAUDE.md before writing any code. Follow existing project patterns.

### Small task execution

For each step, decide:
- **Has dependencies on the previous step** → write it yourself (main session)
- **Independent files** → dispatch parallel subagents

Pass subagents inline context (plan step, interfaces from prior steps, CLAUDE.md rules). Never ask subagents to read these files themselves.

### Large task execution (coordinator mode)

For each phase, dispatch a subagent:
- Pass: the phase steps, any interfaces/contracts from completed phases, CLAUDE.md rules — all inline
- Subagent implements, compiles, commits if successful
- Main agent receives result, verifies compilation, updates checkpoint

**The main agent writes zero implementation code in coordinator mode.** Its job is dispatch → verify → checkpoint → next phase.

### Per-step checkpoint

After each step or phase completes:
1. **Verify compilation** — auto-compile hook handles .cs files. Fix before proceeding.
2. **Update plan checkbox** — change `- [ ]` to `- [x]` in the plan file. This is the resume point if the session breaks.

## 5. Completion

Summarize: what was implemented, deviations from plan, issues resolved.

**Without `--auto`:** recommend next step, wait for user:
- Clean → `/qq:test`
- Needs coverage → `/qq:add-tests` → `/qq:test`
- Had issues → `/qq:best-practice`
- Multi-module → `/qq:claude-code-review`

**With `--auto`:** take the strictest path automatically:
`/qq:best-practice` → `/qq:claude-code-review` → `/qq:add-tests` → `/qq:test` → `/qq:commit-push`

## Rules

- Do not add features or abstractions beyond what the plan specifies
- Each .cs save triggers auto-compilation — never skip this
- If a step is significantly more complex than planned, note the deviation and continue (don't silently diverge)
- Test steps → prefer `/qq:add-tests` over hand-writing test files
