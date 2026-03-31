# tykit MCP Bridge

`tykit_mcp.py` exposes `tykit` as a stdio MCP server for Codex, Cursor, Continue, and other MCP clients.

It does **not** replace qq's existing fast path:

- qq / Claude hooks still use local scripts directly
- MCP clients get the same Unity capabilities through a standard tool interface
- compile and test tools prefer the existing qq scripts when they are installed in the target project

If qq / Claude is using MCP, this built-in bridge should be the default MCP backend. Third-party Unity MCP servers remain compatible fallbacks, not the first choice.

If you are validating this in a demo or sample project, keep that project on the same install path as real users. See [Consumer Rollout](consumer-rollout.md).

For qq-managed consumer projects, `install.sh` now copies the bridge into `scripts/`, writes `.mcp.json` to point at the project-local `scripts/qq_mcp.py`, and adds `./scripts/qq-doctor.sh`.

## Why This Exists

`tykit` is intentionally fast and simple: local HTTP inside the Unity Editor process.

That is ideal for qq's high-frequency workflows, but many general-purpose agents expect MCP tools instead of handwritten `curl` commands. The bridge keeps both:

- **Fast path:** `scripts/unity-compile-smart.sh`, `scripts/unity-test.sh`, hooks
- **Portable path:** `scripts/tykit_mcp.py`

## Requirements

- Python 3
- A Unity project with `tykit` installed
- For the full qq fast path: quick-question scripts installed in the Unity project
- On Windows: Git for Windows, so `bash` is available for the qq scripts and `unity-eval.sh`

## Quick Start

### Codex

Preferred consumer path:

```bash
cd /path/to/unity-project
python3 ./scripts/qq-codex-mcp.py install --pretty
```

This registers a project-specific Codex MCP server name that points at that worktree's own `scripts/qq_mcp.py`.

For Codex task execution inside the project, prefer:

```bash
python3 ./scripts/qq-codex-exec.py "Call unity_health and reply true or false only."
```

That wrapper does not replace MCP registration. It just ensures `codex exec` runs against the current project root and automatically adds the source worktree as writable scope when a qq-managed linked worktree needs merge-back or closeout.

Manual fallback:

```bash
codex mcp add tykit -- python3 /path/to/quick-question/scripts/tykit_mcp.py --project /path/to/unity-project
```

### Cursor / other stdio MCP clients

Use the same command:

```bash
python3 /path/to/quick-question/scripts/tykit_mcp.py --project /path/to/unity-project
```

If your client launches from the Unity project root, `--project` is optional.

## Profiles

### `standard`

Default profile. Exposes the high-value tools most agents need:

- `unity_health`
- `unity_doctor`
- `unity_compile`
- `unity_run_tests`
- `unity_console`
- `unity_editor`
- `unity_query`
- `unity_object`
- `unity_assets`
- `unity_batch`
- `unity_raw_command`

### `full`

Adds lower-frequency domain tools:

- `unity_input`
- `unity_visual`
- `unity_ui`
- `unity_animation`
- `unity_screenshot`

Example:

```bash
python3 scripts/tykit_mcp.py --project /path/to/unity-project --profile full
```

## Tool Design

The bridge intentionally favors coarse tools for performance:

- `unity_compile` completes the whole compile workflow in one tool call
- `unity_run_tests` completes the whole test workflow in one tool call
- `unity_batch` lets the client combine multiple operations into one MCP round trip
- `unity_raw_command` keeps the full `tykit` command surface reachable

This avoids the "MCP death by a thousand tiny calls" problem.

## Fast-Path Routing

### Compile

Priority order:

1. Project-local qq script: `scripts/unity-compile-smart.sh`
2. `tykit` package helper: `Packages/com.tyk.tykit/Scripts~/unity-eval.sh`
3. Direct `tykit` HTTP polling

### Tests

Priority order:

1. Project-local qq script: `scripts/unity-test.sh`
2. Direct `tykit` HTTP `run-tests` / `get-test-result`

This means qq-installed projects keep their existing behavior, while plain `tykit` projects still work when the Editor is open.

## Example Tools

### Health

```json
{
  "name": "unity_health",
  "arguments": {
    "project_dir": "/path/to/project"
  }
}
```

### Doctor

```json
{
  "name": "unity_doctor",
  "arguments": {
    "project_dir": "/path/to/project"
  }
}
```

### Compile

```json
{
  "name": "unity_compile",
  "arguments": {
    "timeout_sec": 20,
    "mode": "auto"
  }
}
```

### Tests

```json
{
  "name": "unity_run_tests",
  "arguments": {
    "mode": "editmode",
    "filter": "Health",
    "timeout_sec": 180
  }
}
```

### Batch

```json
{
  "name": "unity_batch",
  "arguments": {
    "operations": [
      {
        "tool": "unity_query",
        "arguments": {
          "action": "status"
        }
      },
      {
        "tool": "unity_query",
        "arguments": {
          "action": "find",
          "name": "Player"
        }
      }
    ]
  }
}
```

## Third-Party MCP Compatibility

The bridge is designed to coexist with third-party Unity MCP servers:

- It uses its own tool namespace: `unity_*`
- It does not try to override `mcp-unity` or `Unity-MCP` tool names
- Bridge-specific tool profiles live in [`scripts/tykit_capabilities.json`](../scripts/tykit_capabilities.json)
- Core capability routing now lives in [`scripts/qq-capabilities.json`](../scripts/qq-capabilities.json)

That means you can run:

- `mcp-unity`
- `Unity-MCP`
- `tykit_mcp.py`

in the same host, then let the host or your agent prompt decide which capability to prefer. For qq-managed workflows, the preferred order is still `qq direct` first, then `tykit_mcp`, then third-party MCP.

At the architecture level, `tykit_mcp` is a Unity provider under the broader adapter model. See [Adapter Contract](architecture/adapter-contract.md).

## Windows Notes

Windows is supported under the same assumptions as the rest of qq:

- Git for Windows installed
- `bash` on `PATH`
- Python 3 installed

The bridge itself is Python, but qq fast-path scripts and `unity-eval.sh` still run through `bash`.
