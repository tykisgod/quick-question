---
description: "Run Unity unit/integration tests and check for runtime errors."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Run Unity unit/integration tests and check for runtime errors.

> **This skill can ALWAYS run.** It supports three execution backends (tykit HTTP → Editor trigger → Unity batch mode). When Unity Editor is not open, the scripts automatically fall back to batch mode. Never skip this skill with the assumption that tests "cannot run from CLI" — they can.

> **Unity Backend:** This skill supports multiple backends. If the built-in `tykit_mcp` tools are available (`unity_health`, `unity_console`, `unity_run_tests`), use them first. If only third-party MCP tools are available (`run_tests` from mcp-unity, or `tests-run` from Unity-MCP), use those instead of the tykit/script commands below. If no MCP tools are available, use tykit as documented here. To discover tykit commands: `curl -s -X POST http://localhost:$PORT/ -d '{"command":"commands"}' -H 'Content-Type: application/json'` where PORT comes from `Temp/tykit.json`.

Arguments: $ARGUMENTS
- (no arguments): Run both EditMode and PlayMode
- `editmode` / `edit`: EditMode only
- `playmode` / `play`: PlayMode only
- `--filter "TestName"`: Filter by test name (semicolon-separated for multiple)
- `--assembly "Asm.Tests"`: Filter by assembly (semicolon-separated for multiple)
- `--timeout 300`: Custom timeout in seconds

Examples:
- `/qq:test` → Run EditMode + PlayMode
- `/qq:test play` → PlayMode only
- `/qq:test editmode --filter "Health"` → Filter by name
- `/qq:test --assembly "Game.PlayerSystem.Tests"` → Filter by assembly

## Platform Notes

- **Script invocation**: All qq scripts are available as bare commands (e.g. `unity-test.sh`) via the plugin `bin/` directory on PATH. If a bare command fails with "command not found", fall back to `${CLAUDE_PLUGIN_ROOT}/bin/<command>`.
- **Python command**: Use `python3` on macOS/Linux. On Windows (Git Bash), use `python` instead (`python3` is not available). The `bin/` wrappers handle this automatically.
- **Process inspection**: `ps -p PID -o args=` is macOS/Linux only. On Windows, use `wmic process where "ProcessId=$PID" get CommandLine` or `tasklist`.
- **Editor.log path**: Use `source "${CLAUDE_PLUGIN_ROOT}/scripts/platform/detect.sh" && qq_get_editor_log_path` to get the correct path for the current OS.

## Steps

### 0. Read qq project state first when available

If `qq-project-state.py` is available, read it before choosing test scope:

```bash
qq-project-state.py --pretty
```

Interpret the result like this:

- `policy_profile=core` → keep the default lighter
- `policy_profile=feature` → normal default
- `policy_profile=hardening` → prefer the stronger default
- `default_test_scope` is the current repo's effective no-argument default

Rules:

- Explicit user arguments always win
- `--filter` / `--assembly` always win
- With no explicit mode:
  - `default_test_scope=editmode` → run EditMode only
  - `default_test_scope=all` → run EditMode first, then PlayMode
- Tell the user which default you chose and why if it came from `policy_profile`

### 1. tykit Health Check

Before using tykit, verify it's reachable and talking to the correct Unity instance. **If `tykit.json` is missing, skip this entire step** — the test scripts (Step 3) automatically fall back to batch mode when Unity Editor is not running.

#### 1a. Read port + PID

```bash
TYKIT_JSON="Temp/tykit.json"
if [ ! -f "$TYKIT_JSON" ]; then
  echo "tykit.json not found — skipping health check, scripts will use batch mode"
  # SKIP to Step 2 — batch mode does not need tykit
fi
PORT=$("${QQ_PY:-python3}" -c "import json; print(json.load(open('$TYKIT_JSON'))['port'])")
TYKIT_PID=$("${QQ_PY:-python3}" -c "import json; print(json.load(open('$TYKIT_JSON'))['pid'])")
```

#### 1b. Verify PID is the main Unity Editor (not a Worker)

The most common port-stealing culprit is `AssetImportWorker` — it can overwrite `tykit.json` with its own PID, leaving the port pointing at a process that isn't running TykitServer.

```bash
# macOS; on Windows use: wmic process where "ProcessId=$TYKIT_PID" get CommandLine
PROC_ARGS=$(ps -p "$TYKIT_PID" -o args= 2>/dev/null || true)
if [ -z "$PROC_ARGS" ]; then
  echo "PID $TYKIT_PID is dead — tykit.json is stale"
  # STOP: delete stale tykit.json, ask user to reopen Unity
fi
IS_WORKER=$(echo "$PROC_ARGS" | grep -cE "AssetImportWorker|UnityPackageManager|UnityHelper" || true)
if [ "$IS_WORKER" -ne 0 ]; then
  echo "PID $TYKIT_PID is a subprocess ($PROC_ARGS), not the main Unity Editor"
  # STOP: ask user to restart Unity manually (never kill — risks Library corruption)
fi
```

#### 1c. GET health check (`/ping`)

```bash
PING=$(curl -s --connect-timeout 3 --max-time 5 "http://localhost:$PORT/ping" 2>/dev/null) || true
if [ -z "$PING" ]; then
  echo "tykit on port $PORT not responding to /ping"
  # STOP: ask user to check Unity window for modal dialogs
fi
```

#### 1d. POST health check (`compile-status`)

`/ping` responds from the listener thread without touching Unity API. A modal dialog or domain reload can block the main thread, causing POST commands to hang while `/ping` still works. Verify POST works:

```bash
CS=$(curl -s --connect-timeout 5 --max-time 15 -X POST "http://localhost:$PORT/" \
  -d '{"command":"compile-status"}' -H 'Content-Type: application/json' 2>/dev/null) || true
if [ -z "$CS" ]; then
  echo "tykit POST timed out — ping works but commands do not"
  # STOP: Diagnose by priority:
  # 1. Re-check PID (step 1b) — Worker is the #1 cause
  # 2. Check for Unity modal dialogs blocking the main thread
  # 3. Wait 30s for domain reload to finish, then retry
else
  echo "tykit healthy: port=$PORT pid=$TYKIT_PID"
fi
```

**Diagnostic table:**

| Symptom | Likely cause | Action |
|---------|-------------|--------|
| `tykit.json` missing | Unity not running or never opened this project | Skip health check — scripts fall back to batch mode |
| PID dead | Unity closed but `tykit.json` not cleaned up | Delete stale `tykit.json`, ask user to reopen |
| PID is AssetImportWorker | Worker subprocess stole the port on restart | Ask user to restart Unity manually |
| PID is UnityPackageManager/UnityHelper | Other Unity subprocess inherited the port | Ask user to restart Unity manually |
| `/ping` timeout | Unity hung or not listening | Ask user to check Unity window |
| `/ping` OK but POST timeout | Modal dialog blocking main thread, or domain reload in progress | Re-verify PID (step 1b) → check for dialogs → wait 30s retry |

**Rules:**
- **Never `kill` Unity** (including Workers) — risks Library corruption and cascade failures
- **Never hardcode Unity paths** — use `find_unity` from `unity-common.sh` or let the user specify
- **Never launch Unity from command line** — easy to pick wrong version; ask user to open via Unity Hub
- If health check fails (except missing `tykit.json`), **stop and report** — do not attempt workarounds
- If `tykit.json` is missing, **skip to Step 2** — test scripts handle batch mode fallback automatically

> **Built-in `tykit_mcp`:** Prefer `unity_health` and stop if it reports `ok: false`.
>
> **Third-party MCP backends:** Skip this step entirely — their tools manage their own connection.

### 2. Clear Console + Mark Editor.log position

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/platform/detect.sh"
EDITOR_LOG="$(qq_get_editor_log_path)"
BASELINE=$(wc -l < "$EDITOR_LOG")
if [ -n "$PORT" ]; then
  curl -s --connect-timeout 5 --max-time 15 -X POST http://localhost:$PORT/ \
    -d '{"command":"clear-console"}' -H 'Content-Type: application/json'
fi
```

> **Built-in `tykit_mcp`:** Use `unity_console` with `action: "clear"` when available.
>
> **Third-party MCP backends:** Skip this step — neither mcp-unity nor Unity-MCP has a console-clear equivalent. Runtime error checking (Step 4) uses Editor.log directly and does not depend on console state.

### 3. Run tests

Select command based on arguments:

| Argument | Command |
|----------|---------|
| (none) + `default_test_scope=all` | `unity-unit-test.sh` |
| (none) + `default_test_scope=editmode` | `unity-test.sh editmode --timeout 180` |
| `editmode` | `unity-test.sh editmode --timeout 180` |
| `playmode` | `unity-test.sh playmode --timeout 180` |
| with filter/assembly | `unity-test.sh <mode> --filter "X" --assembly "Y" --timeout Z` |

- With no arguments, use `default_test_scope` from project state
- With arguments, call `unity-test.sh` and pass all arguments through
- On failure, analyze the cause and determine whether it was introduced by the current changes or was pre-existing

> **Built-in `tykit_mcp`:** Use `unity_run_tests` first. Pass mode, filter, assembly, and timeout as tool parameters. When no mode argument is given, preserve the sequencing: run EditMode first, check the result, and only proceed to PlayMode if EditMode passes. On failure, apply the same analysis as below.
>
> **Third-party MCP backends:** If the built-in bridge is not available, use `run_tests` (mcp-unity) or `tests-run` (Unity-MCP) instead of the scripts above. Pass mode, filter, assembly, and timeout as tool parameters. When no mode argument is given, preserve the sequencing: run EditMode first, check the result, and only proceed to PlayMode if EditMode passes. On failure, apply the same analysis as below.

### 4. Check runtime errors

Even if all tests pass, runtime errors may still occur. Check via Editor.log (not dependent on the console API buffer):

```bash
tail -n +$((BASELINE + 1)) "$EDITOR_LOG" | \
  grep -iE "NullReferenceException|Exception:|Error\b" | \
  grep -v "^UnityEngine\.\|^Cysharp\.\|^System\.Threading\.\|^  at \|CompilerError\|StackTrace" | \
  sort -u
```

**Show all errors to the user — do not filter or omit any.** For each error, include a source assessment (e.g., "exception from TaskEdgeCaseTests safety test, likely expected behavior"), and let the user decide whether action is needed.

## On test failure

1. Analyze the failure output and identify the failing test name and assertion
2. Read the failing test's source file and the code under test
3. Propose a concrete fix
4. Ask the user whether to apply the fix automatically

## Handoff

After tests complete, recommend the next step:

- **All tests pass, no runtime errors**:
  - if `recommended_next` is `/qq:doc-drift` → "All green. Next up is `/qq:doc-drift` before shipping."
  - if `recommended_next` is `/qq:commit-push` → "All green. Ready for `/qq:commit-push`."
  - otherwise → "All green. Based on current state, the next step is `<recommended_next>`."
- **Tests pass but runtime errors found** → "Tests passed but found N runtime errors. Want me to investigate, or continue with the next recommended step?"
- **Test failures were fixed** → "Fixed N failures. Want to re-run `/qq:test` to confirm, or proceed to `/qq:doc-drift`?"

**`--auto` mode:** skip asking:
- All pass → run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:test" --next-skill "/qq:commit-push"`, then continue with `recommended_next`
- Failures → auto-fix → re-run `/qq:test` (max 3 attempts, then stop and ask user)
