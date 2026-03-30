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

- real Unity host execution inside Claude or Codex for all three engineers at once
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

This suite should stay green as the controller, policy, and install flow evolve.
