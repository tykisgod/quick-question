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

Before starting execution, read prior decisions for context:
```bash
qq-decisions.py summary --project .
```
This shows what design and plan phases decided and why — use this context to make consistent implementation choices.

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

## 3.5. Pre-flight: Engine Project Readiness

Before writing any engine source code, run the preflight check. Use the `project_dir` from `qq-project-state.py` output (§3) as `$PROJECT` — do **not** assume CWD is the project root.

```bash
qq-preflight.py --project "$PROJECT" --fix --pretty
```

`--fix` auto-repairs recoverable issues (e.g., injects tykit into `manifest.json` if missing).

Interpret the output:

- `ready: true` → continue to §4.
- `block_reason: "virgin_project"` → **STOP immediately.** Tell the user to open the project in the engine's editor (Unity Hub / Godot / Unreal), wait for import, then confirm. Save checkpoint with `--status paused`. Do NOT write any source files until the user confirms.
- `block_reason: "missing_tykit"` → re-run with `--fix`, then ask user to open Unity so it resolves the package.
- Any other `ready: false` → report the `message` and stop.

After `ready: true`, do a **test compile** to verify the pipeline end-to-end:

```bash
qq-compile.sh --project "$PROJECT"
```

If this fails, diagnose and resolve before proceeding.

> **Mechanical backstop:** The `compile-gate-check.sh` PreToolUse hook independently blocks engine source writes when `Library/` is missing (virgin project) or the last compile failed. Even if you miss this pre-flight, the hook will catch it. But running preflight explicitly gives better diagnostics and enables `--fix`.

**Why this matters:** The auto-compile hook now sets a compile-gate on failure, but the gate only blocks the _next_ edit — it cannot undo code you already wrote in a non-compiling state. Running preflight + test compile upfront catches issues before any code is written.

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

For each phase:
1. **Dispatch** → implementation subagent
2. **Compile** → **actively verify** compilation succeeded. The auto-compile hook sets a compile-gate on failure, but always run `qq-compile.sh --project "$PROJECT"` explicitly and check exit code 0. If fails: dispatch fix subagent (max 3 rounds, then `--status paused`)
3. **Review** → dispatch review subagent to check behavior correctness (compilation only catches type errors, not logic bugs like "triggers on every hit instead of only on kill")
4. **Fix** → if Critical/Moderate: dispatch fix subagent, re-compile
5. **Checkpoint** → `qq-execute-checkpoint.py save`
6. THEN next dependent phase

**Parallel phases** (independent, no shared interfaces):
1. Dispatch all parallel implementation subagents simultaneously
2. Wait for all to complete → **actively verify** compilation: run `qq-compile.sh --project "$PROJECT"` and check exit code 0
3. Dispatch review subagents for each (can be parallel)
4. Fix issues if any
5. Checkpoint all completed phases
6. THEN next group

**Key constraint:** Do NOT parallelize phases that have interface dependencies. If Phase B uses interfaces defined in Phase A, Phase A must pass review before Phase B starts.

For truly large module-crossing refactors (10+ files, 3+ independent modules), consider dispatching subagents with `isolation: "worktree"` to avoid file conflicts.

**Implementation subagent context** — pass inline:
- The phase steps from the plan (only this phase, not the full plan)
- Interfaces/contracts created by completed phases (paste the actual code)
- CLAUDE.md and AGENTS.md rules

**Review subagent context** — pass inline:
- The phase steps (what was supposed to be implemented)
- The actual code that was written (read the changed files, paste key sections)
- Interfaces from prior phases

**Review prompt:**
> "Review the changes made in [PHASE_NAME] for behavior correctness. Compilation already passed — focus on logic errors that the compiler cannot catch:
> 1. Are event triggers conditional on the right state? (e.g. only on kill, not every hit)
> 2. Is state stored on the right lifecycle object? (e.g. persistent data on DontDestroyOnLoad singletons, not scene-scoped objects)
> 3. Are edge cases handled? (null checks at system boundaries, empty collections)
> Report findings as [Critical] / [Moderate] / [Minor]. Be concise."

**Checkpoint command** (this is NOT optional — it is a fixed workflow step):
```bash
qq-execute-checkpoint.py save \
  --project . --plan "<PLAN_PATH>" --step <N> --total <M> \
  --mode <MODE> --phase "<PHASE_NAME>" --step-title "<STEP_TITLE_TEXT>"
```
This atomically updates `.qq/state/execute-progress.json` AND the plan file checkbox. Do NOT Edit the plan file separately.

### Small task checkpoint

After each step completes:
1. **Completeness check:**
   After implementing a step, quickly scan the files you wrote:
   - Are there any empty method bodies?
   - Are there any `throw new NotImplementedException()` or `// TODO` markers?
   - Does every MonoBehaviour have the lifecycle methods it needs?
   If yes, fix them before checkpointing.
2. **Compile** — **actively verify** compilation: run `qq-compile.sh --project "$PROJECT"` and check exit code 0. The auto-compile hook sets a compile-gate on failure, but explicit verification catches issues immediately. Fix before proceeding. If unfixable after 3 attempts, save `--status paused` and stop.
3. **Checkpoint** — same command as above.

## 5. Completion

Clear the checkpoint:
```bash
qq-execute-checkpoint.py clear --project .
```

Summarize: what was implemented, deviations from plan, issues resolved.

**Without `--auto`:** recommend next step, wait for user:
- Always → `/qq:claude-code-review` (review first, then test)
- If review already done → `/qq:test`
- If test already done → `/qq:commit-push`

**Do NOT recommend `/qq:commit-push` as the first next step.** The order is always: review → test → commit-push.

**With `--auto`:** run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:execute" --next-skill "/qq:claude-code-review"`, then take the full path automatically:
`/qq:claude-code-review` → `/qq:test` → `/qq:commit-push`

## Rules

- Do not add features or abstractions beyond what the plan specifies
- Each .cs save triggers auto-compilation — never skip this
- If a step is significantly more complex than planned, note the deviation and continue
- If the plan is ambiguous or contradictory, use best judgment and note the decision
- Test steps → prefer `/qq:add-tests` over hand-writing test files
- Every file must have COMPLETE implementation — no stubs, no skeleton classes, no "// TODO" comments
- Every method must have a full working body, not just a signature
- After implementing each step, re-read the file to verify completeness before moving on
- If a step's instruction is vague, write MORE code than seems necessary — thorough > minimal
