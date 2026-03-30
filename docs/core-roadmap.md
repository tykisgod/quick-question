# Core Roadmap

_Last updated: 2026-03-30_

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

We are not building:

- a generic super-agent platform
- a cloud control plane
- a product whose core value is just a large skill catalog
- a workflow that forces every task through design -> plan -> execute -> review

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

- shared defaults in `qq-policy.json`
- per-worktree / per-task override in `.qq/local-policy.json`

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

- team-wide defaults live in `qq-policy.json`
- each engineer/task can override mode locally in `.qq/local-policy.json`
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

## Roadmap

### Phase 1: Runtime + Policy Repositioning

Goal:

- make the product read as runtime/policy first, not workflow-first

Actions:

- keep README and install flow centered on runtime, policy, and doctor
- keep `/qq:go` as a controller, not a methodology pusher
- keep work modes/profile language visible in diagnostics and state

Status:

- in progress

### Phase 2: Profile-Based Installation and Defaults

Goal:

- make install and daily use clearly reflect `prototype / feature / hardening`

Actions:

- add install-time profile selection such as `core`, `feature`, `hardening`
- map profile defaults onto shared `qq-policy.json`
- make `qq-doctor` explain the active profile, effective mode, and why capabilities resolve the way they do

Why this is next:

- high ROI
- low infrastructure risk
- immediate user-facing clarity

Status:

- in progress: `policy_profile` now exists in starter policy, diagnostics, and controller recommendation pressure

### Phase 3: Policy Productization

Goal:

- make policy a first-class, configurable product surface

Actions:

- expand policy beyond `enabled_rules`
- define test/review/verification expectations by profile
- classify which checks are always-on vs advisory vs hardening-only
- keep policy engine-agnostic at the core

### Phase 4: Workflow Demotion

Goal:

- keep workflow useful without letting it dominate the product

Actions:

- retain `/qq:go`
- retain doc/plan/review flows as optional packs
- reduce skill-count-centric messaging
- make workflow selection depend on project state and task risk, not a fixed lifecycle ideology

### Phase 5: Adapter Hardening

Goal:

- make multi-engine, multi-host, and multi-transport support a real architectural property

Actions:

- keep evolving the adapter contract
- add adapter contract tests
- ensure new features land as capabilities/provider mappings first
- avoid leaking Unity-specific assumptions into controller or policy core

### Phase 6: Second Engine Spike

Goal:

- validate that the architecture can actually extend beyond Unity

Actions:

- do a minimal non-Unity adapter spike
- prove that core state/policy/controller can survive that spike without rewrites

This is not a near-term shipping goal. It is an architecture validation goal.

## Highest-ROI Next Step

The highest-ROI next step is:

> make install and diagnostics profile-first

Concretely:

- install with explicit `core / feature / hardening` defaults
- keep `prototype / feature / hardening / fix` readable in state and doctor
- make the active mode and verification expectations visible without reading docs

Why:

- users will feel the new product direction immediately
- it reduces confusion faster than adding new skills
- it strengthens runtime/policy positioning without destabilizing the current Unity loop

## Success Criteria

We should keep investing if:

- teams actually keep the runtime active during normal development
- doctor/state/policy make the system easier to trust, not noisier
- profile/mode differences reduce friction instead of increasing configuration burden
- Unity remains a strong wedge without forcing Unity glue into the core

We should narrow or rethink if:

- adoption still depends mostly on heavyweight workflow packs
- users do not understand when or why to use different profiles
- new features keep leaking engine-specific assumptions into the core
- the runtime cannot demonstrate measurable verification value
