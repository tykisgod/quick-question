# Core Roadmap

_Last updated: 2026-03-31_

## Product Definition

`quick-question` should be:

> a verifiable execution runtime for game-development agents

That means:

- **Runtime first**: real compile/test/console/scene execution
- **Policy second**: project rules, verification, and safety defaults
- **Workflow third**: lightweight orchestration, not mandatory methodology

Unity is the current wedge and strongest implementation surface, but the core must stay adapter-friendly so the same runtime/policy model can later support Unreal, Godot, or custom engines.

## What We Are Building

We are building:

- a local developer-loop runtime grounded in real execution
- a policy layer that can validate agent work instead of trusting claims
- a controller that routes based on project state instead of prompt guesswork
- a capability-based architecture that can swap engines, hosts, and transports
- a code-side execution harness that can plan, execute, evaluate, and resume long-running work

We are not building:

- a generic super-agent platform
- a cloud control plane
- a product whose core value is just a large skill catalog
- a workflow that forces every task through design -> plan -> execute -> review
- an art or music automation stack before the code-side runtime is solid

## Layer Model

### 1. Runtime Core

Owns:

- capability registry
- provider resolution
- run records / telemetry
- project state
- doctor / diagnostics
- failure and recovery surfaces

Examples in the repo:

- [`scripts/qq-capabilities.json`](../scripts/qq-capabilities.json)
- [`scripts/qq-capability.py`](../scripts/qq-capability.py)
- [`scripts/qq-run-record.py`](../scripts/qq-run-record.py)
- [`scripts/qq-project-state.py`](../scripts/qq-project-state.py)
- [`scripts/qq-doctor.py`](../scripts/qq-doctor.py)

### 2. Engine Adapters

Each engine adapter is responsible for:

- project detection
- compile/build
- tests
- console/log access
- scene or asset operations where applicable
- engine-specific policy checks

Current strong adapter family:

- Unity via `tykit`, direct scripts, and `tykit_mcp`

Future adapters should fit the same capability contract:

- `unity/*`
- `godot/*`
- `unreal/*`
- `custom/*`

### 3. Policy

Policy is where verifiable execution becomes team-safe.

Owns:

- compile expectations
- test expectations
- deterministic checks
- review expectations
- doc/code consistency expectations
- shared defaults vs local task overrides

Current config model:

- shared defaults in `qq.yaml`
- per-worktree / per-task override in `.qq/local.yaml`

### 4. Workflow Packs

Workflow packs are convenience layers:

- `/qq:go`
- `/qq:plan`
- `/qq:design`
- review flows
- doc-first flows

These should remain thin and optional. They consume runtime + policy; they are not the product core.

## Architectural Principles

1. **Capability over tool names**
   - Core logic should speak in capabilities like `compile`, `test`, `scene.query`, not `tykit` command names or third-party MCP tool names.
2. **Adapter boundaries stay hard**
   - Engine, host, and transport differences must stay below the core.
3. **Default light, escalate by risk**
   - Runtime is always on. Policy starts light. Workflow stays advisory unless risk justifies more ceremony.
4. **Observe -> Act -> Verify -> Recover**
   - Agent work should always be executable, checkable, and recoverable.
5. **Unity validation, multi-engine design**
   - Near-term validation should stay Unity-heavy, but the core should not ossify around Unity-only assumptions.

## Working Modes

Externally, the product should emphasize three profiles:

| Profile | Use When | Default Expectations |
|---|---|---|
| `prototype` | New mechanic, greybox, fun check | Compile, basic validation, state tracking, lightweight summaries |
| `feature` | Retainable system work | Compile, targeted tests, lightweight review, optional concise plan |
| `hardening` | Risky refactor, stability push, release prep | Compile, stronger tests, review, doc/code consistency |

Internally, keep `fix` as a task mode for narrow bug/regression work:

- reproduce first
- make the smallest safe fix
- run the regression path

## Team Model

The correct collaboration model is:

- team-wide defaults now live in `qq.yaml`
- each engineer/task can override mode locally in `.qq/local.yaml`
- unrelated work should use separate branches/worktrees
- `.qq/` remains local runtime state, not a committed collaboration surface

This allows one project to support:

- prototype exploration
- feature iteration
- bug fixing
- stability-heavy refactors

at the same time, without forcing the whole repository into one workflow intensity.

## Current Position

Already in place:

- Unity runtime surface via `tykit`
- direct compile/test fast path
- built-in `tykit_mcp` bridge
- capability registry and provider resolution
- run records / project state / doctor
- local/shared work mode handling
- starter `policy_profile` via install flow
- artifact-driven controller direction

Still too prominent in the product narrative:

- skill count
- heavy workflow language
- doc-first assumptions as if they were universal defaults

Still missing in the runtime itself:

- explicit task contracts between planning and execution
- a first-class evaluator that owns pass / block / continue decisions
- standardized run evidence that explains why a task is or is not done
- resume / recover flows that continue from runtime state instead of conversation memory
- explicit worktree orchestration as part of the runtime model, not just a git habit

## Roadmap

### Short Term: Code-Side Execution Reliability

Goal:

- make code execution explicit, evaluable, and recoverable without making low-risk work feel heavy

Actions:

- formalize a lightweight `Task Contract` artifact for code work
- promote `Evaluator` to a first-class runtime layer that unifies compile, test, policy, review, and doc-drift checks
- standardize `Run Evidence` in `.qq/` so each task records planned files, touched files, verification results, and final disposition
- add `Resume / Recover` flows that continue from the last contract and evidence instead of relying on conversation history
- keep install, README, and `qq-doctor` centered on runtime, policy, contract state, and evidence state
- keep `/qq:go` as a controller, not a methodology pusher
- add adapter contract tests as a guardrail before more runtime features land

Why this is first:

- this is the highest-leverage trust improvement on the code side
- it makes "done / not done / blocked" legible to users
- it improves long-running execution without requiring a heavier default workflow

Status:

- in progress

Scope boundary for v0:

- code-side tasks only
- authoritative result is `pass / block / continue`
- first evaluator pass should rely on compile, test, and deterministic policy before expanding further
- do not let v0 grow into a heavyweight DAG planner, memory system, or review-orchestration rewrite

### Mid Term: Planning, Policy, and Workflow Demotion

Goal:

- separate planning from execution cleanly while keeping workflow intensity proportional to task risk

Actions:

- split planner and executor responsibilities more clearly
- keep task contracts lightweight by mode: `prototype`, `fix`, `feature`, `hardening`
- productize policy beyond `enabled_rules`
- define which checks are always-on, advisory, expected, or blocking by profile
- make qq-managed worktrees a deliberate product surface for parallel code execution and merge-back safety
- keep `/qq:go`, design, plan, and review flows as optional packs on top of runtime + evaluator
- reduce skill-count-centric messaging further so the product reads as runtime/policy first

Why this is second:

- it keeps the system flexible while adding more explicit execution structure
- it prevents "contract + evaluator" from turning into a heavyweight one-size-fits-all workflow
- it turns policy into a product surface instead of hidden configuration

Status:

- partly in progress: `policy_profile` and mode-aware routing already exist, but planner / executor boundaries and evaluator ownership are still weak

### Long Term: Adapter Hardening and Second-Engine Validation

Goal:

- prove that the runtime core survives beyond Unity once the code-side loop is stable

Actions:

- keep evolving the adapter contract
- ensure new features land as capabilities/provider mappings first
- avoid leaking Unity-specific assumptions into controller or policy core
- do a minimal non-Unity adapter spike
- prove that core state / policy / contract / evaluator / evidence can survive that spike without rewrites
- keep art and music generation out of scope until the code-side runtime is mature

This is not a near-term shipping goal. It is an architecture validation goal.

## Highest-ROI Next Step

The highest-ROI next step is:

> make code execution explicit and recoverable

Concretely:

- add a minimal `Task Contract` artifact for code work
- make evaluator output the authoritative pass / block / continue decision
- record structured run evidence in `.qq/`
- make `qq-doctor` and project state expose the current contract, current evidence, and current blocker without reading docs

Why:

- users will feel the trust improvement immediately
- it reduces ambiguity faster than adding new skills or new workflow packs
- it strengthens runtime / policy positioning without forcing heavy process on prototype work

## Success Criteria

We should keep investing if:

- teams actually keep the runtime active during normal development
- doctor/state/policy make the system easier to trust, not noisier
- users can tell why a task is blocked, passing, or incomplete without reading raw logs
- resume / recover meaningfully reduce repeated setup and re-explaining after interruptions
- profile/mode differences reduce friction instead of increasing configuration burden
- Unity remains a strong wedge without forcing Unity glue into the core

We should narrow or rethink if:

- task contracts feel like paperwork on low-risk tasks
- evaluator output duplicates existing tools without making decisions clearer
- adoption still depends mostly on heavyweight workflow packs
- users do not understand when or why to use different profiles
- new features keep leaking engine-specific assumptions into the core
- the runtime cannot demonstrate measurable verification value
