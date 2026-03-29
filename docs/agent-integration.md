# Agent Integration

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
- `scripts/unity-compile-smart.sh`
- `scripts/unity-test.sh`
- local repo context and skill prompts

This keeps compile/test latency low and avoids unnecessary MCP schema overhead.

### Codex / Cursor / Continue / other MCP clients

Prefer:

- `scripts/tykit_mcp.py`

This gives them a stable, typed tool interface without teaching them custom `curl` flows.

## Capability Routing

Use capabilities, not vendor-specific tool names, as the abstraction boundary.

| Capability | Preferred path | Fallbacks |
|---|---|---|
| `compile` | qq direct script | third-party MCP, `tykit_mcp`, raw `tykit` |
| `tests.run` | qq direct script | third-party MCP, `tykit_mcp` |
| `console.read` | third-party MCP or `tykit` | `tykit_mcp` |
| `console.clear` | `tykit` | `tykit_mcp` |
| `scene.query` | any MCP or `tykit` | `unity_raw_command` |
| `scene.mutate` | `tykit_mcp` | `unity_raw_command` |

The current mapping file lives at [`scripts/tykit_capabilities.json`](../scripts/tykit_capabilities.json).

## Third-Party MCP Coexistence

Compatibility depends on four rules:

1. Do not reuse third-party tool names
2. Do not assume only one Unity MCP backend is configured
3. Keep capability mappings in data, not hardcoded shell logic
4. Make per-capability routing possible

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

If the project has qq scripts installed:

- `unity_compile` and `unity_run_tests` should use them first

If the project only has `tykit`:

- compile falls back to `unity-eval.sh` or direct HTTP
- tests fall back to `run-tests` / `get-test-result` while the Editor is open

If you need a command that is not wrapped yet:

- use `unity_raw_command`

If the agent is chatty and MCP round trips are becoming a bottleneck:

- use `unity_batch`
- prefer coarse tools over raw command chains
