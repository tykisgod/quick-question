---
description: "Smart implementation — read a plan, execute step by step with auto-compilation, subagent dispatch for large tasks, and checkpoint-based resume."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Read a plan, execute it fully. Execution is always automatic — never ask "proceed?" or "start?" during implementation. The user invoked execute; that IS the go-ahead.

> **Live Unity editing during execution**: if a plan step needs to poke the live Unity Editor (inspect a component, modify a scene object, invoke a runtime method) instead of writing new C# code, consult [`shared/tykit-reference.md`](../../shared/tykit-reference.md) for the command map. Use tykit commands directly via the MCP tools (`unity_query`, `unity_object`, `unity_assets`, `unity_physics`) or direct HTTP (`/ping`, `/health`, `/focus-unity` for recovery). Only fall back to code-writing for changes that need version control or compile-time validation.

Arguments: $ARGUMENTS
- A file path to a plan/design document
- `--no-worktree`: skip worktree guard
- `--auto`: after completion, auto-select and run the next workflow step instead of asking the user (includes push — user should be aware)
- No arguments: detect the plan source from conversation or `Docs/qq/`

## 1. Worktree Guard (strict — do NOT bypass)

**Worktree isolation is non-negotiable for `/qq:execute`.** Executing a multi-step plan directly on a shared branch pollutes main, blocks parallel work, and makes rollback surgical instead of trivial. You MUST enter a worktree unless one of these **three** conditions is explicitly met:

1. **You are already inside a git worktree** (check with `git rev-parse --show-toplevel` — if it matches `.git/worktrees/<name>/` in the output of `git worktree list`, you're in one). Skip to step 2.
2. **The user passed `--no-worktree` as a literal flag in `$ARGUMENTS`.** Not "semantically meant" — the exact token must be present. Agent-invented `--no-worktree semantics` is forbidden.
3. **The plan is trivially small** (≤ 3 steps touching ≤ 3 files, and no .cs compilation). For anything larger, you need a worktree.

**Do NOT invent other bypass conditions.** If you encounter an obstacle that seems to require skipping the worktree, **fix the obstacle**, don't skip the safety check. Common obstacles and their correct fixes:

| Obstacle | ❌ Wrong reaction | ✅ Correct reaction |
|---|---|---|
| **Plan file is untracked** | "switching worktree loses plan → skip worktree" | `git add <plan_file> && git commit -m "docs(plan): <slug>"` → now plan is in git → enter worktree → plan is visible from worktree. |
| **Uncommitted unrelated changes in working tree** | "dirty tree → can't worktree → skip" | Commit them (if related to this plan) or stash them (if unrelated). Then enter worktree. If user wants to keep them dirty, they must pass `--no-worktree` explicitly. |
| **Conversation has ephemeral state** (open files, scratch edits) | "would lose context → skip" | Conversation state IS lost on worktree entry by design — that's the point of isolation. Re-load plan from disk in the new session. Do not skip for this reason. |
| **`EnterWorktree` tool unavailable** | "no tool → skip" | Fall back to `${CLAUDE_PLUGIN_ROOT}/bin/qq-worktree.py create --name <slug>`, tell the user to reopen in the new path, and **stop**. Don't proceed in the main dir. |

**The procedure:**

1. **Verify plan is in git.** If the plan file is untracked or has uncommitted changes:
   ```bash
   git status -- <plan_file>
   ```
   If dirty, commit it now:
   ```bash
   git add <plan_file>
   git commit -m "docs(plan): <slug> plan document"
   ```
   Announce: "Committed plan doc before entering worktree so it's accessible from the new worktree."

2. **Capture source state BEFORE creating the worktree** (required for verification in step 5):
   ```bash
   SOURCE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
   SOURCE_HEAD=$(git rev-parse HEAD)
   echo "Source: $SOURCE_BRANCH @ $SOURCE_HEAD"
   ```
   Remember these — you'll verify the new worktree inherits them.

3. **Derive a slug** from the plan filename (lowercase, dashes, no extension).

4. **Enter the worktree:** call `EnterWorktree` with `name: <slug>`. If `EnterWorktree` is unavailable, fall back to `${CLAUDE_PLUGIN_ROOT}/bin/qq-worktree.py create --name <slug>` (which uses current branch correctly by design), tell the user to reopen in the new path, and **stop**.

5. **CRITICAL: Verify the new worktree inherited the source branch's HEAD.** `EnterWorktree` is documented as "based on HEAD" but in practice it sometimes creates the worktree branch from the repo's default branch (develop/main) instead of the current feature branch — silently losing your plan commit and any other recent commits. You MUST verify after every `EnterWorktree` call:

   ```bash
   WT_HEAD=$(git rev-parse HEAD)
   if git merge-base --is-ancestor "$SOURCE_HEAD" HEAD 2>/dev/null; then
       echo "✓ Worktree HEAD ($WT_HEAD) includes source HEAD ($SOURCE_HEAD)"
   else
       echo "✗ BUG: worktree HEAD ($WT_HEAD) does NOT include source HEAD ($SOURCE_HEAD)"
       echo "  EnterWorktree branched from a different ref. Recovering..."
       # Hard-reset the new worktree branch to the source HEAD.
       # This works because the new worktree branch was just created and has no
       # commits of its own yet (worst case it had a single auto-generated commit).
       git reset --hard "$SOURCE_HEAD"
       echo "  ✓ Reset worktree to $SOURCE_HEAD"
   fi
   ```

   **Why this matters**: if you skip verification, the worktree's branch is silently rooted at develop. When you eventually `commit-push` and try to merge back, you'll be merging develop's history (zero source-branch commits) into your feature branch — losing the plan commit and any other source-branch context. **Do not skip this verification.** Cherry-pick is NOT a sufficient recovery — it brings over commits but the branch's merge-base is still wrong, which breaks `git diff source...HEAD`-style scoping later.

6. **Seed local runtime files** in the new worktree (qq scripts, AGENTS.md, CLAUDE.md, .mcp.json, qq.yaml, baseline state, run records, AND the worktree.json metadata that registers it as qq-managed). Without this step, `EnterWorktree`-created worktrees lack `scripts/platform/detect.sh` (every qq script call exits 127), and downstream consumers like `commit-push` Type B closeout, `qq-codex-exec` `--add-dir` injection, and `qq-project-state.py` see `isManagedWorktree=false`.
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/bin/qq-worktree.py seed-local-runtime --project . --source "<SOURCE_PROJECT>"
   ```

7. **Seed runtime cache** (Unity `Library/`, etc.) in the new worktree. Now that step 6 has written `.qq/state/worktree.json` with `sourceWorktreePath`, this command can resolve the source from metadata and persist `runtimeCacheSeed` state back into the same file (so `qq-project-state` and `qq-doctor` see the seed completed). Pass NO `--source` flag — the metadata is now authoritative.
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/bin/qq-worktree.py seed-runtime-cache --project .
   ```

**If you decide to skip the worktree under any condition above, state the exact reason in your first message** (e.g. "Skipping worktree: user passed `--no-worktree` in arguments" / "Skipping worktree: already inside `.git/worktrees/demo-loop`" / "Skipping worktree: plan is 2 steps, 1 file, no compile"). Do NOT skip silently.

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

## 3.6. Seam Checklist Gate (跨切面接缝自检)

If the plan has a **跨切面接缝清单 (Cross-cutting Seams)** section and `.claude/seams.yml` exists:

Before marking execution complete, run **every** grep command in that checklist (Grep tool / `rg`) and confirm each fan-out point is handled — either your diff edited it, or you can justify "no change needed". Do **not** finish with any "需改" seam row untouched in your diff. This catches the compile-clean-but-runtime-broken class of bug (added a WorkType / MonsterType / item but forgot a parallel switch / registration / CSV row). Any newly hit seam not yet in `.claude/seams.yml` → append it there.

If the plan has no seam section or `.claude/seams.yml` is absent, skip (no regression).

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
