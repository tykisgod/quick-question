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

## 3.5. Pre-flight: Engine Project Readiness

Before writing any engine source code, verify the project can actually compile.

**Step 1 — Resolve the project root.** The `qq-project-state.py` output from §3 contains a `project_dir` field — use that as `$PROJECT`. Do **not** assume CWD is the project root; always pass `--project "$PROJECT"` to every qq script.

**Step 2 — Engine-specific readiness check (Unity):**

**2a. Ensure `Packages/manifest.json` includes tykit.**

tykit is qq's in-process Unity bridge — without it, compile/test/console commands all fall back to slow batch mode or fail entirely. Check:

```bash
$QQ_PY -c "
import json, sys
m = json.load(open('$PROJECT/Packages/manifest.json'))
dep = m.get('dependencies', {}).get('com.tyk.tykit')
print(dep or 'MISSING')
"
```

- If `manifest.json` does not exist → create the minimal Unity package manifest with tykit:
  ```json
  {
    "dependencies": {
      "com.tyk.tykit": "https://github.com/tykisgod/tykit.git#84b129b026d3b725f5f7dd21d59a5fe9d206850c"
    }
  }
  ```
- If `manifest.json` exists but `com.tyk.tykit` is missing → add it to `dependencies` (same URL as above).
- If tykit is already present → continue.

**2b. Check for `Library/` folder.**

```bash
if [ ! -d "$PROJECT/Library" ]; then
  echo "VIRGIN PROJECT — Library/ does not exist"
fi
```

- If `Library/` does **not** exist → this is a virgin project. Unity has never imported it.
  - **STOP immediately.** Tell the user:
    > "This project has no `Library/` folder — Unity has never opened it. Please:
    > 1. Open this project in Unity Hub
    > 2. Wait for the initial import to complete (watch the progress bar)
    > 3. Then tell me to continue"
  - Save checkpoint: `qq-execute-checkpoint.py save --project "$PROJECT" --plan "<PLAN>" --step 0 --total <M> --mode <MODE> --phase "pre-flight" --status paused`
  - **Do NOT write any source files or continue execution** until the user confirms Unity is ready.

**2c. Test compile.**

- If `Library/` exists → verify the compile pipeline actually works:
  ```bash
  qq-compile.sh --project "$PROJECT"
  ```
  If this fails, diagnose (is Editor open? is batch mode finding the right Unity version?) and resolve before proceeding.

**Other engines:** Apply the equivalent readiness check (e.g., Godot needs `.godot/` import data, Unreal needs `Intermediate/`).

**Why this matters:** The auto-compile hook (`auto-compile.sh`) uses `|| true` — it never blocks, even on failure. This means compilation failures are silent to the agent. You cannot rely on "the hook didn't error" as proof of successful compilation. You must actively verify.

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
2. **Compile** → **actively verify** compilation succeeded. The auto-compile hook uses `|| true` and never blocks, so you cannot rely on "no hook error" as evidence. Run `qq-compile.sh --project "$PROJECT"` explicitly and check exit code 0. If fails: dispatch fix subagent (max 3 rounds, then `--status paused`)
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
1. **Compile** — **actively verify** compilation: run `qq-compile.sh --project "$PROJECT"` and check exit code 0. Do not rely on the auto-compile hook (it uses `|| true` and never blocks). Fix before proceeding. If unfixable after 3 attempts, save `--status paused` and stop.
2. **Checkpoint** — same command as above.

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

**With `--auto`:** take the full path automatically:
`/qq:claude-code-review` → `/qq:test` → `/qq:commit-push`

## Rules

- Do not add features or abstractions beyond what the plan specifies
- Each .cs save triggers auto-compilation — never skip this
- If a step is significantly more complex than planned, note the deviation and continue
- If the plan is ambiguous or contradictory, use best judgment and note the decision
- Test steps → prefer `/qq:add-tests` over hand-writing test files
