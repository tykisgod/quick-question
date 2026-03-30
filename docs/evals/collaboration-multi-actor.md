# Collaboration Multi-Actor E2E

_Last updated: 2026-03-30_

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

- shared `qq-policy.json` defaults do not force the whole repo into one mode
- `.qq/local-policy.json` works as the per-worktree override surface
- unrelated design docs stay background context unless they match current task evidence
- prototype work gets light task routing but still respects hardening verification pressure
- hardening work escalates to review/doc-drift without pretending it is ready to push

## What It Does Not Prove

- real Unity host execution inside Codex
- cross-host concurrency safety
- Codex MCP end-to-end tool exposure

Those remain separate validations. The Codex MCP gap is still tracked in [`docs/todo.md`](../todo.md).

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
  - when controller state was explicitly prepared so `recommended_next=/qq:commit-push`, Claude committed and pushed the managed worktree branch successfully
  - after push, `qq-worktree status` reported `canCleanup=true`

Current boundary:

- the non-interactive `/qq:commit-push` host run still stopped after push instead of continuing automatically into merge-back / cleanup
- the explicit merge-back blocker we saw during this probe (`scripts/__pycache__` in the source worktree) has since been fixed in `qq-worktree.py`

Important host condition for this lifecycle probe:

- temporarily move the project-local `.mcp.json` aside, because the current built-in Claude MCP connection still times out during host startup
- run Claude with the qq plugin directory explicitly so the host path stays focused on qq rather than unrelated user plugins

## Real Claude Host `/qq:test` Limitation

We also probed real `claude -p "/qq:test"` behavior in clean `project_pirate_demo` git worktrees.

Current finding:

- the host path reaches the test skill correctly
- but execution falls back to Unity batch mode in the detached worktree
- that batch path is not representative in this environment because:
  - the worktree has no `Library/` cache
  - the project declares `2022.3.51f1c1` while the local installed editor is `2022.3.56f1`

Result:

- `policy_profile=core` worktree: Claude correctly treats the failure as an environment limitation and does not misreport it as a code failure
- `policy_profile=hardening` worktree: Claude also reports the batch/environment limitation and recommends running tests from a real Editor-backed project context

So `/qq:test` is only partially covered in worktree mode:

- skill entry and fallback handling: covered
- real successful Editor-backed execution in a clean collaboration worktree: not covered yet

This suite should stay green as the controller, policy, and install flow evolve.
