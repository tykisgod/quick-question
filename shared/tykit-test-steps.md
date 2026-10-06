# /qq:test on the tykit channel or an MCP backend

Read this from `/qq:test` when the project's Editor channel is tykit (`Temp/tykit.json`), or when the Editor is reached only through MCP tools. Projects on the official Unity CLI use `/qq:test` Step 1A instead; how the channels are told apart: [`unity-live-state.md`](./unity-live-state.md). The rules at the end of `/qq:test` Step 1 apply here too.

## Which backend

If the built-in `tykit_mcp` tools are available (`unity_health`, `unity_console`, `unity_run_tests`, and `unity_main_thread_health`, `unity_focus_window`, `unity_dismiss_dialog` for recovery), use them first. If only third-party MCP tools are available (`run_tests` from mcp-unity, or `tests-run` from Unity-MCP), use those instead of the tykit/script commands below.

## Step 1B: tykit health check

Verify tykit is reachable and talking to the correct Unity instance.

### 1B-a. Read port + PID

```bash
TYKIT_JSON="Temp/tykit.json"
PORT=$("${QQ_PY:-python3}" -c "import json; print(json.load(open('$TYKIT_JSON'))['port'])")
TYKIT_PID=$("${QQ_PY:-python3}" -c "import json; print(json.load(open('$TYKIT_JSON'))['pid'])")
```
`QQ_PY` is set only after sourcing `detect.sh`; without it, on Windows (Git Bash) use `python` — `python3` is not available there.

### 1B-b. Verify PID is the main Unity Editor (not a Worker)

The most common port-stealing culprit is `AssetImportWorker` — it can overwrite `tykit.json` with its own PID, leaving the port pointing at a process that isn't running TykitServer.

```bash
# macOS / Linux; on Windows (Git Bash) use: tasklist //FI "PID eq $TYKIT_PID" //V
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
On Windows, `wmic` has been removed since Windows 11 24H2; in Git Bash the `tasklist` switches need a double slash, or MSYS rewrites `/FI` into a path.

### 1B-c. GET health check (`/ping`)

```bash
PING=$(curl -s --connect-timeout 3 --max-time 5 "http://localhost:$PORT/ping" 2>/dev/null) || true
if [ -z "$PING" ]; then
  echo "tykit on port $PORT not responding to /ping"
  # STOP: ask user to check Unity window for modal dialogs
fi
```

### 1B-d. POST health check (`compile-status`)

`/ping` responds from the listener thread without touching Unity API. A modal dialog or domain reload can block the main thread, causing POST commands to hang while `/ping` still works. Verify POST works:

```bash
CS=$(curl -s --connect-timeout 5 --max-time 15 -X POST "http://localhost:$PORT/" \
  -d '{"command":"compile-status"}' -H 'Content-Type: application/json' 2>/dev/null) || true
if [ -z "$CS" ]; then
  echo "tykit POST timed out — ping works but commands do not"
  # STOP: Diagnose by priority:
  # 1. Re-check PID (step 1B-b) — Worker is the #1 cause
  # 2. Check for Unity modal dialogs blocking the main thread
  # 3. Wait 30s for domain reload to finish, then retry
else
  echo "tykit healthy: port=$PORT pid=$TYKIT_PID"
fi
```

For tykit commands beyond tests (scene editing, prefab workflow, runtime reflection, command discovery with `commands` / `describe-commands`), see [`tykit-reference.md`](./tykit-reference.md).

**Diagnostic table:**

| Symptom | Likely cause | Action |
|---------|-------------|--------|
| PID dead | Unity closed but `tykit.json` not cleaned up | Delete stale `tykit.json`, ask user to reopen |
| PID is AssetImportWorker | Worker subprocess stole the port on restart | Ask user to restart Unity manually |
| PID is UnityPackageManager/UnityHelper | Other Unity subprocess inherited the port | Ask user to restart Unity manually |
| `/ping` timeout | Unity hung or not listening | Ask user to check Unity window |
| `/ping` OK but POST timeout | Modal dialog / stalled domain reload / package resolve blocking main thread | Call **`GET /health`** to confirm → run recovery flow below |

### 1B-e. Recovery when main thread is blocked (tykit v0.5.0+ only)

When POST commands time out but `/ping` still works, the main thread is blocked. **These endpoints run on the HTTP listener thread and bypass the queue**, so they work even when POST commands don't:

```bash
# 1. Confirm main thread is blocked
curl -s --connect-timeout 3 --max-time 5 "http://localhost:$PORT/health"
# Look at mainThreadBlocked and hint fields

# 2. Try bringing Unity to foreground (Windows only)
#    (Unity background-throttles domain reload / package resolve when unfocused)
curl -s --connect-timeout 3 --max-time 5 "http://localhost:$PORT/focus-unity"

# 3. If that fails, try dismissing a modal dialog (Windows only)
curl -s --connect-timeout 3 --max-time 5 "http://localhost:$PORT/dismiss-dialog"

# 4. After recovery, retry your POST command
```

**Built-in `tykit_mcp` equivalent:** `unity_main_thread_health`, `unity_focus_window`, `unity_dismiss_dialog` MCP tools. Prefer `unity_health` and stop if it reports `ok: false`.

**Third-party MCP users (`mcp-unity` / `Unity-MCP`):** These recovery endpoints are tykit-specific and have no equivalent in third-party MCPs. If POST hangs, the only options are (a) manually clicking/closing the Unity window, (b) waiting for domain reload to finish, or (c) switching to tykit direct HTTP / built-in `tykit_mcp`. Third-party backends manage their own connection, so skip the rest of this step for them.

## Step 2 on MCP backends

`/qq:test` Step 2's bash block clears the console over tykit HTTP when `PORT` is set.

- **Built-in `tykit_mcp`:** Use `unity_console` with `action: "clear"` when available.
- **Third-party MCP backends:** Skip this step — neither mcp-unity nor Unity-MCP has a console-clear equivalent. Runtime error checking (Step 4) uses Editor.log directly and does not depend on console state.

## Step 3 on MCP backends

Use `unity_run_tests` (built-in `tykit_mcp`) first; without it, use `run_tests` (mcp-unity) or `tests-run` (Unity-MCP) instead of the scripts. Pass mode, filter, assembly, and timeout as tool parameters. When no mode argument is given, preserve the sequencing: run EditMode first, check the result, and only proceed to PlayMode if EditMode passes. On failure, follow `/qq:test`'s On test failure section.
