# Getting Started

qq is installed. Now what? Start with `/qq:go` — it reads your project state and recommends the next step. Or jump directly to any skill: `/qq:design`, `/qq:test`, `/qq:best-practice`. The controller adapts; you don't have to follow a fixed sequence.

---

## Scenario 1: Build a feature from scratch

Solo developer. One-line requirement: "add a food system."

```
/qq:go "add a food system"
```

qq suggests `/qq:design`. Asks three questions (reference games? data format? MVP scope?), writes a design doc.

→ "Design ready. Run `/qq:plan`?" — reads the design, explores your codebase, outputs a 6-step plan with file paths and interfaces.

→ "Plan ready. Run `/qq:execute`?" — creates `IFoodSource`, implements `HungerSystem` and `FoodContainer`, wires into existing `NeedSystem`. Each `.cs` save auto-compiles via hook.

→ "Run `/qq:best-practice`?" — catches `GetComponent` in `Update` and a missing event unsubscription. Fixed.

→ "Run `/qq:test`?" — all green. → "Run `/qq:commit-push`?"

Or skip all prompts: `/qq:go --auto "add a food system"` runs everything end-to-end.

---

## Scenario 2: Review code before merging

Team developer. 400 lines of C# across 5 files. Ready for review.

```
/qq:go
```

qq detects uncommitted `.cs` changes. Suggests `/qq:best-practice`. Catches a `public` field that should be `[SerializeField] private` and a missing `CompareTag`. Fixed in 30 seconds.

→ "Run `/qq:codex-code-review`?" — diff sent to Codex. Review Gate locks edits. Subagents verify: 1 critical confirmed (no `isDead` guard during respawn), 1 false positive rejected. Fix applied, gate unlocks.

→ "Run `/qq:doc-drift`?" — design doc says fire starts at 30% HP, code uses 25%. Doc updated.

→ "Run `/qq:commit-push`?" — pre-push hook runs tests. All green. Pushed.

---

## Scenario 3: Understand a large codebase

New team member. Day one on a 200k-line Unity project.

```
/qq:grandma "task system"
```

> "Imagine a restaurant. Each crew member is a waiter. The task system is the manager who looks at all the tables, decides who's closest and free, and assigns them. Urgent tables jump the queue."

Now the technical version:

```
/qq:explain TaskSystem
```

Outputs: responsibilities, key classes, data flow, lifecycle hooks, design decisions.

```
/qq:deps
```

Mermaid dependency graph of all `.asmdef` modules. `TaskSystem` depends on `NavigationSystem` and `NeedSystem` but not `CombatSystem` — clean boundaries.

---

## Controlling process intensity

Two knobs control how much ceremony qq applies:

**`work_mode`** answers "what kind of task is this?"

| Mode | When to use | Skips |
|------|-------------|-------|
| `prototype` | Greybox, fun check | Formal docs, full review |
| `feature` | Building a retainable system | Full regression on every change |
| `fix` | Bug fix, regression | Large refactors |
| `hardening` | Release prep, risky refactor | Prototype shortcuts |

**`policy_profile`** answers "how much verification does this project expect?" The two are independent — a prototype and a hardening pass can share the same policy profile, or not.

Set either in `qq.yaml` (shared default) or `.qq/local.yaml` (per-worktree override). Explicit test arguments still override the default test scope.

### Useful commands

```bash
/qq:go                                          # Where am I? What should I do next?
/qq:go "add health system"                      # Start from an idea
python3 ./scripts/qq-project-state.py --pretty  # Inspect controller state
./scripts/qq-doctor.sh --pretty                 # Discover providers and routing
```

---

## Related docs

- [Configuration](configuration.md) — qq.yaml reference
- [Work Modes](../../README.md#work-modes) — mode table
- [Commands](../../README.md#commands) — full command list
