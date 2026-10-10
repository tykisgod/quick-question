---
description: "Smart implementation — read a plan, execute step by step with auto-compilation, subagent dispatch for large tasks, and checkpoint-based resume."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Read a plan and execute it fully without asking "proceed?" or "start?" — invoking execute is the go-ahead.

> **Workflow:** take `--workflow <name>` from `$ARGUMENTS` if present, else run `qq-config.py field workflow`. On `prototype-loop`, keep §1-§3.5 and the checkpoint command, and run §4-§5 as [`shared/prototype-loop.md`](../../shared/prototype-loop.md) §Execute describes: failing check first per slice, no per-phase review subagents, the checklist re-read at each checkpoint; on `heavy-review` (the default), follow this file as written.

> Run qq scripts as `${CLAUDE_PLUGIN_ROOT}/bin/<name>`: they are not on PATH, so a bare `qq-compile.sh` exits 127.

> **Live Unity Editor steps** (inspect a component, change a scene object, open or save a scene, run a menu item — instead of writing code): `qq-unity-cli.py channel --project "$PWD"` prints the project's channel, `unity-cli`, `tykit` or `none` ([`shared/unity-live-state.md`](../../shared/unity-live-state.md) explains them; the plan may already name it). Never open or print `Library/Pipeline/.unity-pipeline-port` — it holds an eval token.
> - **unity-cli**: `unity command --project-path "$PWD" --json --no-banner <command> -- <params>` (e.g. `set_component_properties`, `set_serialized_field`, `open_scene`, `save_all`, `menu`). Look parameters up first with `unity command --project-path "$PWD" --query <keyword> --detail full --json`; command map and timeout recovery in [`shared/unity-cli-reference.md`](../../shared/unity-cli-reference.md).
> - **tykit**: the MCP tools (`unity_query`, `unity_object`, `unity_assets`, `unity_physics`) or direct HTTP — see [`shared/tykit-reference.md`](../../shared/tykit-reference.md).
> - **none**: do the step in code or assets instead, and note it.
>
> Editor changes persist only once saved (`save_all` / tykit `save-scene`). Compile and tests still go through qq (auto-compile, `/qq:test`) on every channel.

Arguments: $ARGUMENTS
- A file path to a plan/design document
- `--no-worktree`: skip worktree guard
- `--auto`: after completion, auto-select and run the next workflow step instead of asking the user (includes push — user should be aware)
- No arguments: detect the plan source from conversation or `Docs/qq/`

## 1. Worktree Guard

Execute in a linked git worktree. Skip it only when:

1. You are already in one: `git rev-parse --path-format=absolute --git-dir` differs from `git rev-parse --path-format=absolute --git-common-dir`.
2. `$ARGUMENTS` contains the literal token `--no-worktree` (a user who only seems to mean it does not count).
3. The plan is trivially small: ≤ 3 steps touching ≤ 3 files, and no compilation.

If something seems to require skipping the worktree, resolve it instead:

| Obstacle | Resolution |
|---|---|
| Plan file is untracked | Commit it (step 1 below), then enter the worktree — the plan is visible there. |
| Uncommitted changes in the working tree | Commit them if they belong to this plan, stash them if not, then enter the worktree. If the user wants them left as they are, they pass `--no-worktree`. |

State any skip and its reason in your first message (e.g. "Skipping worktree: user passed `--no-worktree` in arguments" / "Skipping worktree: already inside linked worktree <path>" / "Skipping worktree: plan is 2 steps, 1 file, no compile").

**The procedure:**

1. **Commit the plan**, together with the design doc its `Design doc:` line names (the review at the end reads it). Check them:
   ```bash
   git status -- <plan_file> <design_doc>
   ```
   If either is untracked or modified, commit them and say so:
   ```bash
   git add -- <plan_file> <design_doc>
   git commit -m "docs(plan): <slug> plan document" -- <plan_file> <design_doc>
   ```

2. **Capture the source state** before creating the worktree, and remember it along with the source project path:
   ```bash
   SOURCE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
   SOURCE_HEAD=$(git rev-parse HEAD)
   echo "Source: $SOURCE_BRANCH @ $SOURCE_HEAD"
   ```

3. **Derive a slug** from the plan filename (lowercase, dashes, no extension).

4. **Enter the worktree:** call `EnterWorktree` with `name: <slug>`. If `EnterWorktree` is unavailable, fall back to `${CLAUDE_PLUGIN_ROOT}/bin/qq-worktree.py create --name <slug>`, tell the user to reopen in the new path, and stop — don't proceed in the main dir.

5. **Make sure the worktree contains the source HEAD.** `EnterWorktree` branches from `origin/<default-branch>` unless the user's `worktree.baseRef` setting is `head`:

   ```bash
   WT_HEAD=$(git rev-parse HEAD)
   if git merge-base --is-ancestor "$SOURCE_HEAD" HEAD 2>/dev/null; then
       echo "✓ Worktree HEAD ($WT_HEAD) includes source HEAD ($SOURCE_HEAD)"
   else
       echo "✗ Worktree HEAD ($WT_HEAD) does NOT include source HEAD ($SOURCE_HEAD) — resetting"
       # The new worktree branch has no commits of its own yet.
       git reset --hard "$SOURCE_HEAD"
       echo "  ✓ Reset worktree to $SOURCE_HEAD"
   fi
   ```

   Recover with this reset, not cherry-pick: cherry-pick brings the commits over but leaves the branch's merge-base on the default branch, which breaks `git diff source...HEAD`-style scoping and the merge back.

6. **Seed local runtime files** (qq scripts, AGENTS.md, CLAUDE.md, .mcp.json, qq.yaml, baseline state, run records, and the `.qq/state/worktree.json` metadata that registers the worktree as qq-managed — `EnterWorktree` copies none of them):
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/bin/qq-worktree.py seed-local-runtime --project . --source "<SOURCE_PROJECT>"
   ```

7. **Seed the runtime cache** (Unity `Library/`, etc.). Pass no `--source` — the metadata from step 6 names it:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/bin/qq-worktree.py seed-runtime-cache --project .
   ```

## 2. Locate Plan & Resume

Find the plan (user arg → conversation → `Docs/qq/` scan → ask).

**Resume check:** Run:
```bash
qq-execute-checkpoint.py resume --project .
```
If it returns progress with `status: "running"` or `"paused"`, resume from the first uncompleted step. Report: "Resuming from step N (steps 1–M already complete)."

If empty, scan the plan's checkboxes and resume from the first unchecked step (`- [ ]`).

## 3. Analyze & Start

Read the plan, and AGENTS.md if the project has one.

Read the decisions the design and plan phases made, and keep implementation choices consistent with them:
```bash
qq-decisions.py summary --project .
```

Don't write a new plan, enter plan mode, or save files to `.claude/plans/` — the plan exists; execute it.

Classify the plan:
- **Small** (≤8 steps touching ≤12 files): main agent executes directly, using subagents only for independent parallel files.
- **Large** (>8 steps or >12 files across >3 modules): main agent becomes a **coordinator only** — dispatch each phase/group as a subagent, and write no implementation code in the main session.

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

Before writing any engine source code, run the preflight check. `$PROJECT` below is the engine project root — the directory holding `ProjectSettings/`, `project.godot`, the `.uproject` or the `.sbproj`; don't assume it is the CWD.

```bash
qq-preflight.py --project "$PROJECT" --pretty
```

Preflight only reports; the user resolves its blockers, not a flag.

- `ready: true` → continue.
- `block_reason: "virgin_project"` → stop. Tell the user to open the project in the engine's editor (Unity Hub / Godot / Unreal), wait for import, then confirm. Save checkpoint with `--status paused`, and write no source files until the user confirms.
- Any other `ready: false` → report the `message` and stop.

After `ready: true`, do a **test compile** to verify the pipeline end-to-end:

```bash
qq-compile.sh --project "$PROJECT"
```

If this fails, diagnose and resolve before proceeding.

> The `compile-gate-check.sh` PreToolUse hook also blocks engine source writes when `Library/` is missing (linked git worktrees are exempt) or the last compile failed. While it is red, the files with errors, the file that broke the build, files of types named in the errors, and new files stay editable — fix those first.

## 4. Execute

### Milestones

After each checkpoint (both modes), check the plan's Milestones table: when every step of a milestone is in `completed_steps` (printed by `save`) and it has not been announced yet (on resume, milestones finished before the resume point count as announced):
1. Compile and run the tests written so far: invoke `/qq:test <narrowest scope>` without `--auto` and skip its Handoff; fix failures as in the Fix step.
2. Check the milestone's Checklist items against the code with one read-only subagent.
3. Tell the user "Milestone N can be tried", with How to try it / What to look at, and any Checklist item still missing.
4. If the project's instructions describe how to hand work over for checking, do only the part that produces something runnable (for example, a dev build). Keep the editor open so the user can try it; merging, pushing, and publishing wait until after review → test → commit-push.

Then continue without waiting for an answer. If a later compile has no verdict because the Editor is in Play mode (the user is trying the milestone), that is not a failure. Without `--auto`: save `--status paused`, ask the user to leave Play mode, and resume with `/qq:execute`. With `--auto`: tell the user once, then re-check the compile about once a minute until Play mode ends.

### Subagent context

Subagents already load CLAUDE.md. Paste inline what they cannot see — don't ask them to read the plan file or AGENTS.md:
- **Implementation subagents:** the steps they own (only this phase, not the full plan), the interfaces/contracts created by completed phases (the actual code), and the relevant AGENTS.md rules.
- **Review subagents:** the phase steps (what was supposed to be implemented), the actual code that was written (read the changed files, paste key sections), and interfaces from prior phases.

### Small task execution

For each step, decide:
- **Has dependencies on the previous step** → write it yourself (main session)
- **Independent files** → dispatch parallel subagents
- **Sequential chain (A→B→C)** → execute sub-steps one by one; consider subagents for long chains (4+) to prevent context accumulation

After each step:
1. **Compile** — run `qq-compile.sh --project "$PROJECT"` and check exit code 0. Fix before proceeding. If unfixable after 3 attempts, save `--status paused` and stop.
2. **Checkpoint** — the checkpoint command below.

### Large task execution (coordinator mode)

Execute phases in the order the plan specifies (which may not be numeric — e.g. Phase 9.1 before Phase 2). Work out from the plan which phases are sequential (a phase uses interfaces an earlier phase creates; see the steps' Depends-on lines) and which are parallel (e.g. "Phase 3 + Phase 4 parallel"). Never run a phase in parallel with one whose interfaces it uses.

**Sequential phases** — for each phase:
1. **Dispatch** → implementation subagent
2. **Compile** → run `qq-compile.sh --project "$PROJECT"` and check exit code 0. If it fails: dispatch fix subagent (max 3 rounds, then `--status paused`)
3. **Review** → dispatch review subagent to check behavior correctness
4. **Fix** → if Critical/Moderate: dispatch fix subagent, re-compile. Fix by correcting the logic or the numbers; a fix that adds a protection or an added restriction goes on the "Needs the user's decision" list instead ([`shared/user-decisions.md`](../../shared/user-decisions.md))
5. **Checkpoint** → `qq-execute-checkpoint.py save`
6. THEN next dependent phase

**Parallel phases** (independent, no shared interfaces):
1. Dispatch all parallel implementation subagents simultaneously
2. Wait for all to complete → run `qq-compile.sh --project "$PROJECT"` and check exit code 0
3. Dispatch review subagents for each (can be parallel)
4. Fix issues if any
5. Checkpoint all completed phases
6. THEN next group

For truly large module-crossing refactors (10+ files, 3+ independent modules), consider dispatching subagents with `isolation: "worktree"` to avoid file conflicts.

**Review prompt:**
> "Review the changes made in [PHASE_NAME] for behavior correctness. Compilation already passed — focus on logic errors that the compiler cannot catch:
> 1. Are event triggers conditional on the right state? (e.g. only on kill, not every hit)
> 2. Is state stored on an object whose lifetime matches the data's? (e.g. data that must survive a scene change is not kept on a scene-scoped object)
> 3. Are edge cases handled? (null checks at system boundaries, empty collections)
> Report findings as [Critical] / [Moderate] / [Minor]. Be concise."

### Checkpoint command

```bash
qq-execute-checkpoint.py save \
  --project . --plan "<PLAN_PATH>" --step <N> --total <M> \
  --mode <MODE> --phase "<PHASE_NAME>" --step-title "<STEP_TITLE_TEXT>"
```
This updates `.qq/state/execute-progress.json` and the plan file checkbox together; don't edit the plan file yourself.

## 5. Completion

If the plan has a Cross-cutting Seams section (跨切面接缝清单) and `.claude/seams.yml` exists, run every grep command in that checklist (Grep tool / `rg`) first. Each fan-out point must be handled — your diff edited it, or you can justify "no change needed"; don't finish with a row the plan marks as needing a change untouched in your diff. Append any newly hit seam that is not yet in `.claude/seams.yml`.

Clear the checkpoint:
```bash
qq-execute-checkpoint.py clear --project .
```

Summarize: what was implemented, deviations from plan, issues resolved, and any "Needs the user's decision" entries.

Pass the plan to the review as a spec, and the design doc too when the plan's `Design doc:` line names one: `/qq:claude-code-review --spec <design-doc> --spec <plan>`. The review still picks its own scope (normally the uncommitted changes); the specs make it also check the code against the plan and the design's Acceptance Checklist.

**Without `--auto`:** recommend the next step and wait for the user. The order is always review → test → commit-push:
- Always → `/qq:claude-code-review`
- If review already done → `/qq:test`
- If test already done → `/qq:commit-push`

**With `--auto`:** run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:execute" --next-skill "/qq:claude-code-review" --plan-doc "<plan>" --design-doc "<design doc, if named>"`, then take the full path automatically:
`/qq:claude-code-review` (with the `--spec` arguments above) → `/qq:test` → `/qq:commit-push`

## Rules

- Do not add features or abstractions beyond what the plan specifies
- If a step is significantly more complex than planned, note the deviation and continue
- If the plan is ambiguous or contradictory, use best judgment and note the decision, except for protections, added restrictions, and scope cuts: those go on the "Needs the user's decision" list, with the normal rule built meanwhile ([`shared/user-decisions.md`](../../shared/user-decisions.md))
- Test steps → prefer `/qq:add-tests` over hand-writing test files
- Every file must have a complete implementation — no stubs, skeleton classes, signature-only methods or "// TODO" comments. A stand-in the plan names for a milestone is not a stub; the later step the plan names replaces it
- If a step's instruction is vague, implement everything the step needs — thorough > minimal — but add no player-facing rule the plan or design does not name
