# Host Shell V1

`quick-question` already has strong runtime-core pieces:

- engine-aware project state
- doctor and provider resolution
- worktree orchestration
- context capsule / resume handoff
- trust-level-based host behavior

What still feels thin is the host shell.

Today, too much of the user experience depends on:

- reading multiple JSON files or commands separately
- remembering what `qq-doctor`, `qq-project-state`, and `qq-context-capsule` each expose
- manually reconstructing blocker, resume, and permission state
- treating subagents and host behavior as prompt conventions instead of product surface

Host Shell V1 is the first pass at fixing that.

## Goal

Make `qq` feel like a coherent agent runtime shell, not just a collection of runtime scripts.

Concretely, Host Shell V1 should make these questions easy to answer without reading raw logs:

- where am I right now?
- what is blocked?
- what can this host do?
- what should happen next?
- what should be resumed or recovered?
- which agent role should own this task?

## Non-Goals

Host Shell V1 is not:

- a desktop cockpit
- a long-term memory or vector database system
- a replacement for engine adapters
- a rewrite of workflow packs into a heavy methodology
- a migration of `quick-question` into OpenGame

## Current Repo Position

These files already provide most of the raw ingredients:

- [`scripts/qq-project-state.py`](../scripts/qq-project-state.py)
- [`scripts/qq-doctor.py`](../scripts/qq-doctor.py)
- [`scripts/qq-context-capsule.py`](../scripts/qq-context-capsule.py)
- [`scripts/qq-codex-exec.py`](../scripts/qq-codex-exec.py)
- [`scripts/qq-worktree.py`](../scripts/qq-worktree.py)
- [`scripts/qq_internal_config.py`](../scripts/qq_internal_config.py)
- [`docs/core-roadmap.md`](./core-roadmap.md)
- [`docs/agent-integration.md`](./agent-integration.md)
- [`docs/context-capsule.md`](./context-capsule.md)

The problem is not missing raw state.

The problem is that the host experience still makes the user or wrapper reconstruct too much meaning from that state.

## Scope

Host Shell V1 includes:

1. a first-class runtime lane payload
2. a first-class status surface
3. a real permission model
4. checkpoint / recovery behavior
5. first-class agent profiles
6. an IDE sidecar contract

Host Shell V1 does not require:

- new engine bridges
- a GUI inside this repo
- moving OpenGame Desktop code into `quick-question`

## Workstreams

### 1. Runtime Lane Contract

Add one host-facing payload that combines the most important runtime state:

- engine
- profile
- work mode
- policy profile
- provider route
- compile status
- test status
- blockers
- recommended next step
- worktree role and branch
- resume eligibility
- current checkpoint / evidence summary
- permission summary

This should stop hosts from stitching together separate outputs from:

- `qq-project-state`
- `qq-doctor`
- `qq-context-capsule`

The contract should be stable enough for:

- terminal status tools
- Codex / Claude wrappers
- future IDE adapters
- OpenGame Desktop Build lane

### 2. Status Surface

Add a first-class status entry point, for example:

- `qq-statusline`
- `/qq:status`
- a machine-readable status payload for host UIs

The status surface should keep the most important runtime state visible:

- current engine
- compile/test freshness
- active blocker
- provider route
- managed-worktree state
- resume state
- permission mode

This is the highest-leverage UX upgrade because it makes the runtime legible at a glance.

### 3. Permission Model

The current `trust_level` model is useful but too coarse.

Host Shell V1 should evolve it into a permission policy that can express:

- raw engine tool exposure
- source-worktree widening
- auto-resume permission
- checkpoint restore permission
- writable path scope
- capability-specific allow/deny decisions

Keep the existing `trusted / balanced / strict` presets as shorthand if useful, but treat them as profile presets over a richer policy model, not as the final abstraction.

### 4. Checkpoint and Recovery

`Context Capsule` is already a thin resume handoff, but the product still lacks a broader checkpoint model.

Host Shell V1 should formalize:

- resume from latest blocker
- resume from worktree handoff
- recover after interrupted host session
- rewind to the last known green verification point

This should stay runtime-first:

- source of truth remains `.qq/state`, `.qq/runs`, and evidence artifacts
- prompt assembly stays downstream of state, not the reverse

### 5. Agent Profiles

Subagent behavior should stop living only in prompt conventions and skill prose.

Host Shell V1 should define first-class agent profiles such as:

- reviewer
- runtime-debugger
- test-writer
- handoff-coordinator

Each profile should be able to specify:

- allowed tools
- default output style
- verification expectations
- checkpoint behavior
- whether it can escalate to raw engine operations

### 6. IDE Sidecar Contract

`quick-question` should define a host-agnostic sidecar contract for:

- active file
- selection
- diagnostics
- diff summary
- recent terminal failures

This contract should be intentionally narrow.

The goal is not to build a full IDE product inside `qq`.
The goal is to let hosts consume the right local context without asking users to manually copy it.

## OpenGame Relationship

This work should make `quick-question` fit OpenGame better, not compete with it.

OpenGame's current shape is already clear:

- `quick-question` owns runtime / verification / engine adapters
- OpenGame Desktop owns the cockpit UI

That means the right split is:

- `qq` owns the runtime lane contract, permissions, checkpoint rules, and host/runtime semantics
- OpenGame Desktop consumes those contracts to render the Build lane

OpenGame should not reimplement:

- provider resolution
- permission policy
- worktree safety logic
- resume / checkpoint decisions
- evaluator or runtime evidence logic

Instead, OpenGame should read them from `qq`.

In practice, the first concrete coordination target should be:

1. expose a stable runtime lane payload from `qq`
2. let OpenGame `apps/desktop` Build lane render that payload directly
3. let future OpenGame Desktop shells stay focused on cockpit UX, multi-window state, and cross-lane orchestration

## First Delivery Slice

The first useful slice of Host Shell V1 should be small and highly visible:

1. runtime lane payload
2. status surface
3. richer permission summary

Why this slice first:

- it improves user trust immediately
- it reduces host-wrapper complexity immediately
- it gives OpenGame a better Build lane contract immediately

Checkpointing, agent profiles, and IDE sidecar should follow after the runtime lane contract is stable.

## Success Criteria

Host Shell V1 is working if:

- users can tell why work is blocked without opening raw logs
- hosts no longer need custom glue to reconstruct `qq` state
- resume / recover feels like a product feature instead of a wrapper trick
- permission behavior is explicit and inspectable
- OpenGame Build lane can consume `qq` state directly instead of re-deriving it

Host Shell V1 is failing if:

- it adds ceremony without improving clarity
- it creates a second workflow layer above runtime-core
- it pushes OpenGame to duplicate `qq` runtime logic
- it turns into a generic memory platform instead of a code/runtime shell
