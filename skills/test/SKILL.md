---
description: "Run Unity unit/integration tests and check for runtime errors."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Run Unity unit/integration tests and check for runtime errors.

> **This skill can ALWAYS run** while a Unity Editor is open on the project — it drives the running Editor (the official Unity CLI `unity command` / `unity job` on projects that run Unity's Pipeline server, or tykit HTTP on tykit projects). Never skip it with the assumption that tests "cannot run from CLI" — they can.
>
> **There is no automatic batch-mode fallback.** If the scripts cannot reach an Editor they exit **2** and print why. That is the intended answer, not an obstacle to work around: `-batchmode` grabs the project lock and corrupts the Library of an Editor that is open but undetectable. **Do not re-run with `--batch` on your own initiative** — report the exit-2 message and let the user decide (open the Editor, or confirm nothing holds the lock and ask for `--batch`).

> **Which channel the project uses** — the test scripts pick it themselves; you only need it for the health check in Step 1 and the console clear in Step 2:
>
> | Project has | Channel | Reference |
> |---|---|---|
> | `Library/Pipeline/.unity-pipeline-port` (Unity's Pipeline server is running) and the `unity` CLI | **official Unity CLI** | [`shared/unity-cli-reference.md`](../../shared/unity-cli-reference.md); `unity command --project-path "$PWD" --query <keyword> --detail full --json` lists a command's parameters |
> | `Temp/tykit.json` (and no live Pipeline descriptor, or no `unity` CLI to drive it) | **tykit** | [`shared/tykit-reference.md`](../../shared/tykit-reference.md) |
> | neither | none — Step 3's script exits 2 and says why | — |
>
> Exact answer (descriptor valid, owned by this project, its pid alive; the CLI found): `qq-unity-cli.py channel --project "$PWD"`. Overview of both channels (and when to query the live Editor at all): [`shared/unity-live-state.md`](../../shared/unity-live-state.md).
>
> 🔴 **Never open, `cat`, `grep` or print `Library/Pipeline/.unity-pipeline-port`.** It holds an eval token that grants arbitrary C# execution inside the Editor. Check only that it exists; qq's scripts read just its `port` / `pid` / `projectPath` fields.
>
> **MCP backends** (tykit channel, or no channel): if the built-in `tykit_mcp` tools are available (`unity_health`, `unity_console`, `unity_run_tests`, and — new in v0.5.0 — `unity_main_thread_health`, `unity_focus_window`, `unity_dismiss_dialog` for recovery), use them first. If only third-party MCP tools are available (`run_tests` from mcp-unity, or `tests-run` from Unity-MCP), use those instead of the tykit/script commands below. On the official-CLI channel use the scripts in Step 3 — they carry the safeguards described there.

Arguments: $ARGUMENTS
- (no arguments): Run both EditMode and PlayMode
- `editmode` / `edit`: EditMode only
- `playmode` / `play`: PlayMode only
- `--filter "TestName"`: Filter by test name (tykit: semicolon-separated for multiple; official CLI: one value)
- `--assembly "Asm.Tests"`: Filter by assembly (tykit: semicolon-separated for multiple; official CLI: one value, not together with `--filter`)
- `--timeout 300`: How long to wait for results, in seconds (default chosen by the script per channel)
- `--job <jobId>`: Official CLI, EditMode only — resume waiting for a run that was already submitted (use the exact resume command the script printed; it keeps the same filter)

Examples:
- `/qq:test` → Run EditMode + PlayMode
- `/qq:test play` → PlayMode only
- `/qq:test editmode --filter "Health"` → Filter by name
- `/qq:test --assembly "Game.PlayerSystem.Tests"` → Filter by assembly

## Platform Notes

- **Script invocation**: All qq scripts are available as bare commands (e.g. `unity-test.sh`) via the plugin `bin/` directory on PATH. If a bare command fails with "command not found", fall back to `${CLAUDE_PLUGIN_ROOT}/bin/<command>`.
- **Python command**: Use `python3` on macOS/Linux. On Windows (Git Bash), use `python` instead (`python3` is not available). The `bin/` wrappers handle this automatically.
- **Process inspection**: `ps -p PID -o args=` is macOS/Linux only. On Windows `wmic` has been removed since Windows 11 24H2; use `tasklist //FI "PID eq $PID" //V` (in Git Bash the switches need a double slash, or MSYS rewrites `/FI` into a path). On the official-CLI channel you never need this: qq's scripts check the Editor pid recorded in the Pipeline descriptor themselves.
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

### 1. Editor health check (by channel)

Run the check for the project's channel (see the table above). **If the channel is none, skip to Step 3** — the test script makes the final call and exits 2 with a reason if it cannot reach an Editor.

#### 1A. Official Unity CLI

```bash
unity command --project-path "$PWD" --json --no-banner --timeout 20 editor_status
```

- Healthy: top-level `success` is `true`, `data.result.projectPath` is this project, `data.result.compiling` is `false` and `data.result.playMode` is `stopped` (Step 3's script waits for a compile to finish and stops Play mode itself, and says so).
- Always pass `--project-path`: without it the CLI picks *some* open Editor, possibly another worktree's. Do not use `unity status --project-path` to decide ownership — it is a substring filter.
- `No Pipeline instance found for project` → the Pipeline server is not running for this project: ask the user to start it (Unity menu **Window/Pipeline/Start Server**).
- `timed out after …` → the Editor's CLI execution gate is occupied: a test run in progress, a modal dialog, or a wedged command. The Editor GUI may still respond. Ask the user to look for a dialog in the Unity window; exiting Play mode or restarting the Editor frees a wedged gate (Window/Pipeline/Stop Server goes through the same gate and will not get in). **Do not kill Unity yourself.**
- A response with `busyReason: "blocked_by_dialog"` (Unity 6000.7+) lists the dialogs: report their titles and buttons to the user.

#### 1B. tykit (only when the channel is tykit)

Verify tykit is reachable and talking to the correct Unity instance.

##### 1B-a. Read port + PID

```bash
TYKIT_JSON="Temp/tykit.json"
PORT=$("${QQ_PY:-python3}" -c "import json; print(json.load(open('$TYKIT_JSON'))['port'])")
TYKIT_PID=$("${QQ_PY:-python3}" -c "import json; print(json.load(open('$TYKIT_JSON'))['pid'])")
```

##### 1B-b. Verify PID is the main Unity Editor (not a Worker)

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

##### 1B-c. GET health check (`/ping`)

```bash
PING=$(curl -s --connect-timeout 3 --max-time 5 "http://localhost:$PORT/ping" 2>/dev/null) || true
if [ -z "$PING" ]; then
  echo "tykit on port $PORT not responding to /ping"
  # STOP: ask user to check Unity window for modal dialogs
fi
```

##### 1B-d. POST health check (`compile-status`)

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

To discover tykit commands: `curl -s -X POST http://localhost:$PORT/ -d '{"command":"commands"}' -H 'Content-Type: application/json'` or `'{"command":"describe-commands"}'` for full schemas. For tykit usage beyond tests (scene editing, prefab workflow, runtime reflection, recovery from hangs), see [`shared/tykit-reference.md`](../../shared/tykit-reference.md).

**Diagnostic table:**

| Symptom | Likely cause | Action |
|---------|-------------|--------|
| PID dead | Unity closed but `tykit.json` not cleaned up | Delete stale `tykit.json`, ask user to reopen |
| PID is AssetImportWorker | Worker subprocess stole the port on restart | Ask user to restart Unity manually |
| PID is UnityPackageManager/UnityHelper | Other Unity subprocess inherited the port | Ask user to restart Unity manually |
| `/ping` timeout | Unity hung or not listening | Ask user to check Unity window |
| `/ping` OK but POST timeout | Modal dialog / stalled domain reload / package resolve blocking main thread | Call **`GET /health`** to confirm → run recovery flow below |

##### 1B-e. Recovery when main thread is blocked (tykit v0.5.0+ only)

When POST commands time out but `/ping` still works, the main thread is blocked. **These endpoints run on the HTTP listener thread and bypass the queue**, so they work even when POST commands don't:

```bash
# 1. Confirm main thread is blocked
curl -s --connect-timeout 3 --max-time 5 "http://localhost:$PORT/health"
# Look at mainThreadBlocked and hint fields

# 2. Try bringing Unity to foreground (Windows only) — fixes 90% of stalls
#    (Unity background-throttles domain reload / package resolve when unfocused)
curl -s --connect-timeout 3 --max-time 5 "http://localhost:$PORT/focus-unity"

# 3. If that fails, try dismissing a modal dialog (Windows only)
curl -s --connect-timeout 3 --max-time 5 "http://localhost:$PORT/dismiss-dialog"

# 4. After recovery, retry your POST command
```

**Built-in `tykit_mcp` equivalent:** `unity_main_thread_health`, `unity_focus_window`, `unity_dismiss_dialog` MCP tools. Prefer `unity_health` and stop if it reports `ok: false`.

**Third-party MCP users (`mcp-unity` / `Unity-MCP`):** These recovery endpoints are tykit-specific and have no equivalent in third-party MCPs. If POST hangs, the only options are (a) manually clicking/closing the Unity window, (b) waiting for domain reload to finish, or (c) switching to tykit direct HTTP / built-in `tykit_mcp`. Third-party backends manage their own connection, so skip the rest of this step for them.

**Rules (every channel):**
- **Never `kill` Unity** (including Workers) — risks Library corruption and cascade failures
- **Never hardcode Unity paths** — use `find_unity` from `unity-common.sh` or let the user specify
- **Never launch Unity from command line** — easy to pick wrong version; ask user to open via Unity Hub
- If the health check fails, **stop and report** — do not attempt workarounds
- If the channel is none, **skip to Step 3** — the test script will exit 2 with a reason if it cannot reach an Editor
- **Never add `--batch` yourself.** It is an explicit opt-in to grabbing the project lock; only the user can accept that risk

### 2. Clear Console + Mark Editor.log position

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/platform/detect.sh"
EDITOR_LOG="$(qq_get_editor_log_path)"
BASELINE=$(wc -l < "$EDITOR_LOG")
# official Unity CLI channel:
unity command --project-path "$PWD" --json --no-banner clear_console
# tykit channel (PORT from Step 1B):
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
| (none) + `default_test_scope=editmode` | `unity-test.sh editmode` |
| `editmode` | `unity-test.sh editmode` |
| `playmode` | `unity-test.sh playmode` |
| with filter/assembly | `unity-test.sh <mode> --filter "X"` or `unity-test.sh <mode> --assembly "Y"` |

- With no arguments, use `default_test_scope` from project state
- With arguments, call `unity-test.sh` and pass all arguments through
- The script picks the channel and the default wait (`--timeout`) itself; only pass `--timeout` when the user asks for one
- **Official CLI: a full EditMode run can take 10+ minutes.** Run the script with the Bash tool's `run_in_background`, or, if a wait is cut short, resume the same run with the command the script printed at submission (`unity-test.sh editmode --job <jobId>`, plus the same filter). **Never re-run to "retry" a wait** — that submits the whole suite again and cancels the run in flight. PlayMode cannot be resumed: let the run finish in Unity before re-running. **Do not edit scripts while an official-CLI EditMode run is in flight**: the auto-compile hook cannot see a detached test job (it only sees PlayMode runs). Its recompile waits on the busy channel (the hook gives up after ~50 s) but stays queued in Unity, and once the run ends it may recompile and reload the domain before the script has collected the result (`test_job_lost`).
- **Do not drive the run yourself on the official-CLI channel** — no hand-written `run_tests` through `unity command`, and none of the `unity` CLI's own test / build / run subcommands (they start a second, batch-mode Editor on the same project). The script passes `-- --timeout 86400` (the command's own 300 s default wedges the Editor's whole CLI channel when it fires on a long suite) and judges the result by `Summary.Failed` and the skip count — exit codes and `success` fields alone report green for a run with failures.
- Official CLI only: skipped tests must be listed in the expected-skips file (`unity.expected_skips` in `qq.yaml`, default `.qq/unity-expected-skips.txt`; one NUnit FullName per line), otherwise a skip fails the run. `unity.min_tests.editmode` / `unity.min_tests.playmode` in `qq.yaml` set a minimum test count for unfiltered runs.
- **Exit codes:** 0 passed; 1 tests failed (or fewer than the minimum ran); **2 no trustworthy verdict**. Before deciding what to do with a non-zero exit, read `failure_category` in `.qq/state/test.json`:
  - `editor_not_detected` / `unity_cli_unavailable` — zero tests ran; not a test failure and not something to retry with `--batch`. Relay the script's message and stop.
  - `test_failed` / `test_count_below_floor` — a real red result (named in the output).
  - `test_in_flight` / `editor_mismatch` — nothing was submitted (another run in progress, or the Editor answering belongs to another project). Report it; do not loop.
  - `editor_busy` — the Editor's CLI channel was busy or blocked by a modal dialog. This can happen **after** the submission too: if the script printed an EditMode jobId, the run may still be going — answer any dialog in Unity, then resume with the `--job` command the script printed (never re-run). A busy reply to a PlayMode submission may still have queued the run: check Unity before re-running. Otherwise nothing was submitted; report it and do not loop.
  - `test_timeout_or_blocked` / `test_job_lost` / `test_run_error` / `test_verdict_untrusted` / `unity_cli_transport` — the run may have happened but there is no verdict. Report it; on `test_timeout_or_blocked` for EditMode, resume with `--job`; on `test_job_lost` (a compile or domain reload in Unity dropped the job), wait until Unity is idle before re-running.
  - `unsupported_filter` / `invalid_arguments` — fix the arguments (nothing was submitted). `config_error` — fix `qq.yaml`, or the expected-skips file (UTF-8 text, or UTF-16 with a BOM); when it is reported after the run, the tests ran but the skips could not be checked.
  - `all` reports a definite failure (exit 1) even when the other mode gave no verdict; that mode's reason is in `runs[]` and in the summary.
- On failure, analyze the cause and determine whether it was introduced by the current changes or was pre-existing

> **Built-in `tykit_mcp`** (tykit channel): Use `unity_run_tests` first. Pass mode, filter, assembly, and timeout as tool parameters. When no mode argument is given, preserve the sequencing: run EditMode first, check the result, and only proceed to PlayMode if EditMode passes. On failure, apply the same analysis as below.
>
> **Third-party MCP backends** (tykit channel or no channel): If the built-in bridge is not available, use `run_tests` (mcp-unity) or `tests-run` (Unity-MCP) instead of the scripts above. Pass mode, filter, assembly, and timeout as tool parameters. When no mode argument is given, preserve the sequencing: run EditMode first, check the result, and only proceed to PlayMode if EditMode passes. On failure, apply the same analysis as below.

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
- All pass → run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:test" --next-skill "<recommended_next>"` (use the actual `recommended_next` from project state, not a hardcoded value), then continue with `recommended_next`
- Failures → auto-fix → re-run `/qq:test` (max 3 attempts, then stop and ask user)
