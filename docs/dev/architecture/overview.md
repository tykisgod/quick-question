# Architecture Overview

qq is the agent control plane for game-dev work — a Claude Code plugin **and** an engine-agnostic runtime. It supports Unity, Godot, Unreal, and S&box, providing artifact-driven control (`/qq:go`), auto-compile hooks, test pipelines, deterministic policy checks (`qq-policy-check.sh`), cross-skill decision journaling (`session-decisions.json`), and dual-mode (Codex + Claude) code review with a verification loop. Although Claude Code gets the deepest integration, the runtime core is agent-agnostic — Codex CLI, Cursor, Continue, and any MCP-compatible host can use the same scripts and bridges through HTTP and MCP.

## Four-Layer Architecture

qq operates as four layers, each with a single responsibility.

```
Controller (/qq:go)       Reads state, recommends next step
        |
Hooks (hooks.json)        Fire automatically on tool use / session end
        |
Runtime Data (.qq/)       Structured logs, state, telemetry
        |
Engine Bridges            In-process execution per engine
```

### Layer 1 -- Controller (`/qq:go`)

The controller reads project state from `.qq/state/` and recommends the right next skill. It consumes:

- `work_mode` and `policy_profile` from configuration
- Last compile and test results
- Design docs, plans, uncommitted code
- Review gate state

Configuration flows from shared defaults in `qq.yaml`, with local overrides in `.qq/local.yaml`.

The controller is a router, not an implementation engine. It delegates all real work to skills.

### Layer 2 -- Hooks

Hooks fire automatically via the Claude Code hook system, defined in `hooks/hooks.json`:

| Trigger | Condition | Action |
|---------|-----------|--------|
| PreToolUse | Edit or Write engine source files | Block on virgin project / red compile via `compile-gate-check.sh` |
| PreToolUse | Edit or Write while review gate is active | Block edits until review verification completes |
| PostToolUse | Write or Edit engine source files | Auto-compile via `qq-compile.sh` (multi-engine dispatcher) |
| PostToolUse | Write or Edit skill files | Track via `skill-modified-track.sh` |
| PostToolUse | Bash (after a review script opened the gate) | Announce the review gate (edits stay locked until verified) |
| PostToolUse | Agent subagent completes | Increment verification counter (release gate) |
| Stop | Session ending | Block if skills modified without `/qq:self-review`, if review verification incomplete, or if `--auto` pipeline still running; clean up temp files |
| SessionStart | (startup) | Sync plugin scripts via `auto-sync.sh` after plugin upgrade |
| SessionStart | `compact` | Inject `/qq:execute` and auto-pipeline resume hints from `.qq/state/` |

All temp files are keyed by the Claude Code session id for session isolation (e.g., `$QQ_TEMP_DIR/review-gate-<session_id>`, `$QQ_TEMP_DIR/compile-gate-<session_id>`; see `qq_session_id` in `scripts/platform/detect.sh`). Hook scripts read tool input from stdin via the shared `qq_hook_input` helper in `scripts/qq-runtime.sh` (jq-first, with a python3 fallback).

### Layer 3 -- Runtime Data

Structured data lives under `.qq/` in the target project:

- `.qq/runs/` -- Execution logs (JSON), one per skill invocation
- `.qq/state/` -- Latest status snapshots (compile, test, project state)
- `.qq/telemetry/` -- Usage and timing data

Both the controller and hooks read and write here. `qq-run-record.py` and `qq-runtime.sh` handle writes; `qq-project-state.py` is the primary reader.

### Layer 4 -- Engine Bridges

Each engine has a verified, in-process execution path:

| Engine | Primary Path | Fallbacks |
|--------|-------------|-----------|
| Unity | tykit HTTP server (in-process, ms response) | osascript/PowerShell editor trigger, then batch mode |
| Godot | Editor addon + headless GDScript check | -- |
| Unreal | Editor command via Python, UnrealBuildTool | -- |
| S&box | Editor bridge, `dotnet build` | -- |

## Work Mode Routing

The controller selects a workflow based on `work_mode`:

```mermaid
flowchart LR
    A["prototype"] --> B["build directly / /qq:changes"]
    C["feature"] --> D["design --> plan --> execute"]
    E["fix"] --> F["reproduce --> minimal fix --> /qq:test"]
    G["hardening"] --> H["/qq:test --> review --> /qq:doc-drift --> ship"]
```

## Hook Firing Patterns

```mermaid
flowchart LR
    A["Edit .cs"] -->|PostToolUse| B["Auto-compile"]
    C["Run review"] -->|PostToolUse| D["Lock edits"]
    E["Subagent done"] -->|PostToolUse| F["Unlock edits"]
    G["Session end"] -->|Stop| H["Check: skills reviewed?"]
```

## Claude-tykit Communication (Unity)

```mermaid
flowchart LR
    A["Claude Code"] -->|"HTTP"| B["tykit"]
    B --> C["Compile"]
    B --> D["Test"]
    B --> E["Play/Stop"]
    B --> F["Console"]
    B --> G["Inspect"]
```

## Smart Compile Dispatch

`scripts/qq-compile.sh` is the multi-engine entry point. It detects the active engine and delegates to the engine-specific compiler:

- **Unity** → `unity-compile-smart.sh`, which itself picks the best path:
  1. **tykit mode** -- HTTP call to the in-process tykit server running inside Unity Editor. This is the fastest path: non-blocking, millisecond response times, no process spawning.
  2. **Editor trigger** -- When tykit is unavailable, the script uses `osascript` on macOS or PowerShell on Windows to send a compile command to the running Unity Editor. Slower than tykit but avoids a full batch invocation.
  3. **Batch mode** -- When the Editor is not open at all, the script falls back to `Unity -quit -batchmode`. This is the slowest path but works headlessly and is the only option for CI or closed-Editor scenarios.
- **Godot** → `godot-compile.sh` (headless `--check-only` GDScript validation)
- **Unreal** → `unreal-compile.sh` (UnrealBuildTool + editor commandlet)
- **S&box** → `sbox-compile.sh` (`dotnet build`)

Shared utilities live in per-engine common files: `unity-common.sh`, `godot-common.sh`, `unreal-common.sh`, `sbox-common.sh` (Editor detection, paths, port discovery).

## State-Driven Routing

`qq-project-state.py` is the primary source of truth for `/qq:go`. It assembles a state snapshot that includes:

- **work_mode** -- prototype, feature, fix, or hardening
- **policy_profile** -- which checks to enforce
- **trust_level** -- controls review gate strictness
- **compile status** -- last result, timestamp, error count
- **test status** -- pass/fail/skip counts, last run timestamp
- **worktree state** -- uncommitted changes, branch, divergence from remote

The controller uses this snapshot to recommend the next skill. It falls back to git heuristics (branch name, diff size, recent commits) only when `.qq/state/` data is unavailable or stale.

## Related Documentation

- [Adapter Contract](adapter-contract.md) -- engine adapter interface spec
- [S&box Adapter Spec](sbox-adapter-spec.md) -- S&box-specific implementation
- [Hook System](../../en/hooks.md) -- detailed hook documentation
- [Cross-Model Review](../../en/cross-model-review.md) -- Codex Tribunal flow
- [Configuration](../../en/configuration.md) -- qq.yaml reference
