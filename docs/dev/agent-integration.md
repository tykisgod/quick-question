# Agent Integration

> **Outdated (2026-10-13):** written for the tykit era. qq no longer installs tykit or ships the tykit MCP bridge; Unity projects reach the open Editor through the official Unity CLI (see [`shared/unity-live-state.md`](../../shared/unity-live-state.md)). Kept for history.

This document defines how `quick-question`, `tykit`, and third-party Unity MCP servers should coexist.

## Core Rule

Do not force all agents onto one transport.

Use:

- **direct path** for qq's high-frequency local workflows
- **MCP** for general-purpose agent compatibility

## Transport Strategy

### qq / Claude

Prefer direct local workflows:

- hooks
- `scripts/qq-compile.sh` (multi-engine dispatcher; delegates to `unity-compile-smart.sh` / `godot-compile.sh` / `unreal-compile.sh` / `sbox-compile.sh`)
- `scripts/qq-test.sh` (same multi-engine dispatch for tests)
- local repo context and skill prompts

This keeps compile/test latency low and avoids unnecessary MCP schema overhead.

If qq / Claude is using MCP anyway, prefer the built-in `tykit_mcp` / `qq_mcp` bridge before third-party MCP servers.

### Codex / Cursor / Continue / other MCP clients

Prefer:

- `scripts/tykit_mcp.py`

For Codex specifically, prefer the project-local helper instead of asking users to hand-edit global MCP config:

```bash
python3 ./scripts/qq-codex-mcp.py install --pretty
```

Then prefer:

```bash
python3 ./scripts/qq-codex-exec.py "Call unity_health and reply true or false only."
```

This gives them a stable, typed tool interface without teaching them custom `curl` flows. `qq-codex-exec.py` stays intentionally thin: it normalizes the project root, defaults Codex to `workspace-write`, and adds the source worktree path when the current project is a qq-managed linked worktree.

`trust_level` controls source-worktree access:

- `trusted`: automatic source-worktree widening
- `balanced`: only widen to the source worktree for closeout-like flows
- `strict`: require `--allow-source-worktree` before Codex gets source-worktree write scope

Example:

```bash
python3 ./scripts/qq-codex-exec.py --allow-source-worktree "Run qq-worktree closeout for this managed worktree."
```

## Capability Routing

Use capabilities, not vendor-specific tool names, as the abstraction boundary.

| Capability | Preferred path | Fallbacks |
|---|---|---|
| `compile` | qq direct script | `tykit_mcp`, third-party MCP, raw `tykit` |
| `test` | qq direct script | `tykit_mcp`, third-party MCP |
| `console.read` | `tykit` or `tykit_mcp` | third-party MCP |
| `console.clear` | `tykit` | `tykit_mcp` |
| `scene.query` | `tykit_mcp` or `tykit` | third-party MCP, `unity_raw_command` |
| `scene.mutate` | `tykit_mcp` | `unity_raw_command` |

The current core routing registry lives at [`scripts/qq-capabilities.json`](../../scripts/qq-capabilities.json).

Bridge-specific tool exposure still lives at [`scripts/tykit_capabilities.json`](../../scripts/tykit_capabilities.json).

When `trust_level` is `balanced` or `strict`, the standard qq MCP surface hides raw engine commands (`unity_raw_command`, `godot_raw_command`). They remain available only through the richer/full bridge profile.

## Third-Party MCP Coexistence

Compatibility depends on four rules:

1. Do not reuse third-party tool names
2. Do not assume only one Unity MCP backend is configured
3. Keep capability mappings in data, not hardcoded shell logic
4. Make per-capability routing possible

Coexistence does **not** mean equal priority. qq's default MCP route should be the built-in `tykit_mcp` bridge because its tool behavior matches qq's own scripts and tykit semantics.

This is why the bridge uses names like:

- `unity_compile`
- `unity_run_tests`
- `unity_query`

instead of:

- `run_tests`
- `assets-refresh`
- `recompile_scripts`

## Why Not MCP-First Everywhere

High-frequency coding workflows are different from portable agent integration.

For qq, direct local scripts are still better for:

- compile on every `.cs` edit
- test loops
- hook-triggered automation

For portable agents, MCP is better for:

- discoverability
- typed schemas
- host-native tool calling
- multi-agent interoperability

The bridge exists so both can be true at the same time.

## Adapter Boundary

`quick-question` is structured as:

- `qq-core`
- engine adapters
- host adapters
- transport adapters

All four engines (Unity, Godot, Unreal, S&box) now have direct + built-in `qq-mcp` bridge adapters. Unity has the deepest integration (tykit in-process HTTP, third-party MCP fallbacks); Godot, Unreal, and S&box are at runtime parity through Python bridges. Capability routing is engine-agnostic core infrastructure.

The current contract is documented in [Adapter Contract](architecture/adapter-contract.md). The S&box adapter shape is documented in [S&box Adapter Spec](architecture/sbox-adapter-spec.md).

## Profiles

### `standard`

Use this for most agents.

It keeps the tool surface compact and reduces model selection overhead.

### `full`

Use this when an agent needs more of the long tail:

- input simulation
- visual editing
- UI creation
- animation tools
- screenshots

## Operational Guidance

The guidance below uses Unity tool names for concreteness, but the same patterns apply to the other engines via `godot_*`, `unreal_*`, and `sbox_*` tools exposed by their respective bridges.

If the project has qq scripts installed:

- `unity_compile` / `godot_compile` / `unreal_compile` / `sbox_compile` (and the corresponding `*_run_tests`) should use the local `qq-compile.sh` / `qq-test.sh` paths first

If a built-in qq MCP bridge is available (`tykit_mcp` for Unity, `qq_mcp` for the rest):

- prefer engine-prefixed tools (`unity_*`, `godot_*`, `unreal_*`, `sbox_*`) before third-party MCP tool names
- treat third-party MCP servers as explicit compatibility fallbacks

If the project only has the engine bridge directly (e.g. only `tykit`):

- compile and test fall back to direct HTTP / direct script invocation while the Editor is open

If you need a command that is not wrapped yet:

- use `unity_raw_command` (Unity) or the equivalent raw command escape on the other engines, when `trust_level` allows it

If the agent is chatty and MCP round trips are becoming a bottleneck:

- prefer coarse tools (e.g. `unity_batch`) over raw command chains
