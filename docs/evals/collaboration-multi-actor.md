# Collaboration Multi-Actor E2E

_Last updated: 2026-03-31_

This is the highest-priority workflow validation for `qq` right now:

> one game project, multiple engineers, different tasks, different workflow intensity, no cross-contamination

It exists because the core product claim is not just "one agent can do one Unity task", but:

- shared project defaults can stay stable
- each worktree can carry its own task mode
- prototype / feature / hardening work can happen at the same time
- the controller should route each engineer correctly without repo-global artifacts taking over

## Why This Matters

This is the real team scenario we care about:

- Engineer A is exploring a rough idea
- Engineer B is iterating on a retainable feature
- Engineer C is stabilizing a risky refactor

If `qq` cannot keep those paths independent, the policy/runtime model is wrong.

## Covered Scenario

The automated suite models one shared project policy with three independent worktrees:

| Engineer | Local override | Situation | Expected next step |
|---|---|---|---|
| A | `work_mode=prototype`, `policy_profile=hardening` | New `.cs` spike with no fresh compile | `verify_compile`, then `/qq:test` after compile |
| B | `work_mode=feature`, `policy_profile=feature`, `task_focus=crew weapon` | Multiple repo design docs exist, but only one matches current task | `/qq:plan` with only the focused design doc activated |
| C | `work_mode=hardening`, `policy_profile=hardening` | Risky refactor with compile+test passing | `/qq:claude-code-review`, then `/qq:doc-drift` after review |

## What This Suite Proves

- shared `qq.yaml` defaults do not force the whole repo into one mode
- `.qq/local.yaml` works as the per-worktree override surface
- unrelated design docs stay background context unless they match current task evidence
- prototype work gets light task routing but still respects hardening verification pressure
- hardening work escalates to review/doc-drift without pretending it is ready to push

## What It Does Not Prove

- cross-host concurrency safety
- successful Unity-backed `/qq:test` from a clean collaboration worktree under Claude or Codex

That remains the main open validation in [`docs/todo.md`](../todo.md).

## How To Run

```bash
python3 scripts/eval/run-benchmarks.py \
  --suite docs/evals/collaboration-multi-actor.json \
  --pretty
```

## Current Result

Current expected result:

- suite passes
- Engineer A stays on compile/test
- Engineer B is routed to plan from the correct design doc
- Engineer C is routed through review before doc drift

## Real Claude Host Spot-Check

We also validated the same routing shape through real `claude -p` host calls against clean `project_pirate_demo` git worktrees.

Current real-host findings:

- Engineer A on `prototype + hardening` with a dirty C# spike in the demo worktree returns `verify_compile`
- Engineer B on `feature + task_focus=crew weapon` returns `/qq:plan`
- Engineer C on `hardening + hardening` returns `/qq:claude-code-review`, then `/qq:doc-drift` after review is marked verified
- Real `/qq:commit-push` host gating matches controller state:
  - Engineer A is blocked until compile is verified
  - Engineer C is blocked until `/qq:doc-drift` is complete

Important test condition:

- the worktree's `.claude/settings.local.json` explicitly disables unrelated user plugins such as `superpowers` and `telegram`
- without that isolation, host runs become much slower and the signal is polluted by non-qq plugin context

## Real Claude Host Worktree Lifecycle

We also ran a separate host E2E against an isolated `project_pirate_demo` clone with a local bare remote to verify the actual qq-managed worktree lifecycle.

Validated behavior:

- `/qq:execute Docs/qq/sea-monster-e2e-plan.md --worktree --auto`
  - created a qq-managed linked worktree from the source feature branch
  - performed a doc-only spike inside the linked worktree
  - committed and pushed the linked branch
  - merged the linked branch back into the source branch
  - removed the linked worktree afterwards
- `/qq:commit-push`
  - when the source worktree had passing compile/test state and the linked worktree only changed a non-design-doc file, Claude successfully:
    - committed the linked worktree change
    - pushed the linked branch
    - merged it back into the source branch
    - deleted the linked branch
    - removed the linked worktree
  - this now works without manually pre-seeding compile/test records inside the linked worktree itself because `qq-worktree create` copies source baseline state into the linked worktree

Important host condition for this lifecycle probe:

- run Claude with the qq plugin directory explicitly so the host path stays focused on qq rather than unrelated user plugins

## Real Claude Host `/qq:test`

We also probed real `claude -p "/qq:test"` behavior in clean `project_pirate_demo` git worktrees.

Current finding:

- `qq-worktree create` now seeds the source worktree `Library` into the linked worktree
- the linked worktree therefore reaches batch test execution without the previous cold-start import wall
- on a real qq-managed linked worktree created from `project_pirate_demo_codex`, Claude completed:
  - `claude -p --permission-mode bypassPermissions "/qq:test editmode"`
  - result: `296 passed / 0 failed / 0 skipped`

What this proves:

- the skill entry and fallback path are real
- a collaboration worktree no longer needs a separate warmup ritual before `/qq:test`
- the remaining worktree test issue is no longer correctness or host wiring
- the remaining cost is only whatever incremental import/compile the linked worktree still needs for its own branch state

## Real Root-Project `/qq:test`

We now also have a real host proof on the actual `project_pirate_demo` root project:

- Claude:
  - `claude -p --plugin-dir /Users/tyk/Documents/GitHub/quick-question --permission-mode bypassPermissions "/qq:test editmode"`
  - result: `349 passed / 0 failed / 0 skipped`
- Codex:
  - `qq-codex-mcp.py install`
  - `qq-codex-exec.py ... "Call unity_run_tests with mode editmode ..."`
  - result: `{"ok":true,"passed":349,"failed":0,"total":349,"mode":"editmode"}`

What this proves:

- the built-in test path is real in both hosts on an Editor-backed consumer project
- the remaining gap is specifically collaboration-worktree `/qq:test`, not project-root host wiring

## Real Codex Host Spot-Check

We now have two real Codex host confirmations:

1. On the real `project_pirate_demo` project, after project-local registration through `qq-codex-mcp.py`, `codex exec` successfully called `unity_health`.
2. On an isolated minimal Unity repo with a qq-managed linked worktree, `codex exec` successfully read `qq-project-state.py` and returned the expected collaboration state:
   - `work_mode=prototype`
   - `policy_profile=hardening`
   - `recommended_next=verify_compile`
   - `is_managed_worktree=true`
   - `worktree_role=managed`
   - `worktree_source_branch=feature/crew`
3. On an isolated minimal Unity repo with a qq-managed linked worktree, `qq-codex-exec.py` automatically added the source worktree as writable scope and Codex successfully drove:
   - `python3 ./scripts/qq-worktree.py closeout --project . --auto-yes --delete-branch --pretty`
   - to completion without manually spelling `--add-dir <source-worktree>`

What this proves:

- Codex can consume the built-in `tykit_mcp` bridge when explicitly registered through the project helper
- Codex can reason from the same per-worktree controller state that Claude uses
- Codex can complete the managed-worktree closeout lifecycle once the source worktree scope is injected by the project wrapper
- Codex can execute the built-in Unity test tool on the real `project_pirate_demo` root project
- Codex can execute the built-in Unity test tool on a seeded qq-managed linked worktree:
  - the underlying qq run completed successfully with `349 passed / 0 failed`
  - current remaining edge: Codex can still hit a 120s host-side MCP tool timeout before surfacing that result cleanly, even though the recorded test run itself passed
- The collaboration model is now real on Codex for runtime/controller parity, closeout, and root-project Unity test execution, not just simulated in `run-benchmarks.py`

This suite should stay green as the controller, policy, and install flow evolve.
