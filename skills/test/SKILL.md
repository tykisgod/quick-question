---
description: "Run Unity unit/integration tests and check for runtime errors."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

> Run qq scripts as `${CLAUDE_PLUGIN_ROOT}/bin/<name>`: they are not on PATH, so a bare `unity-test.sh` exits 127.

> The test scripts drive the open Unity Editor from the CLI (the official `unity command` / `unity job`, or tykit HTTP), so the tests can run from here — don't skip them assuming they can't. If the scripts cannot reach an Editor they exit **2** and say why; there is no batch-mode fallback. Report that message and let the user decide (open the Editor, or confirm nothing holds the project lock and ask for `--batch`). **Never add `--batch` yourself**: `-batchmode` grabs the project lock and corrupts the Library of an Editor that is open but undetectable.

> **Channel:** the test scripts pick it themselves; you need it only for Steps 1–2. `qq-unity-cli.py channel --project "$PWD"` prints `unity-cli`, `tykit` or `none` ([`shared/unity-live-state.md`](../../shared/unity-live-state.md) explains them; never open or print `Library/Pipeline/.unity-pipeline-port` — it holds an eval token). On `tykit`, or when the Editor is reached only through MCP tools (`tykit_mcp`, mcp-unity, Unity-MCP), read [`shared/tykit-test-steps.md`](../../shared/tykit-test-steps.md) now: it holds Step 1B and the MCP variants of Steps 2–3.

Arguments: $ARGUMENTS
- (no arguments): the project's default scope (Step 0)
- `editmode` / `edit`: EditMode only
- `playmode` / `play`: PlayMode only
- `--filter "TestName"`: Filter by test name (tykit: semicolon-separated for multiple; official CLI: one value)
- `--assembly "Asm.Tests"`: Filter by assembly (tykit: semicolon-separated for multiple; official CLI: one value, not together with `--filter`)
- `--timeout 300`: How long to wait for results, in seconds (default chosen by the script per channel)
- `--job <jobId>`: Official CLI, EditMode only — resume waiting for a run that was already submitted (use the exact resume command the script printed; it keeps the same filter)

## Steps

### 0. Read project state

```bash
qq-project-state.py --pretty
```

Explicit arguments (mode, `--filter`, `--assembly`) always win. With no mode argument, `default_test_scope` (the repo's effective default, derived from `policy_profile` unless configured) picks the command in Step 3: `editmode` → EditMode only, `all` → EditMode, then PlayMode. Tell the user which default you used and why.

### 1. Editor health check (by channel)

Run the check for the project's channel: 1A below, or Step 1B in [`shared/tykit-test-steps.md`](../../shared/tykit-test-steps.md) on `tykit`. **If the channel is none, skip to Step 3** — the test script makes the final call and exits 2 with a reason if it cannot reach an Editor.

#### 1A. Official Unity CLI

```bash
unity command --project-path "$PWD" --json --no-banner --timeout 20 editor_status
```

- Healthy: top-level `success` is `true`, `data.result.projectPath` is this project, `data.result.compiling` is `false` and `data.result.playMode` is `stopped` (Step 3's script waits for a compile to finish and stops Play mode itself, and says so).
- Always pass `--project-path`: without it the CLI picks *some* open Editor, possibly another worktree's. Do not use `unity status --project-path` to decide ownership — it is a substring filter.
- `No Pipeline instance found for project` → the Pipeline server is not running for this project: ask the user to start it (Unity menu **Window/Pipeline/Start Server**).
- `timed out after …` → the Editor's CLI execution gate is occupied: a test run in progress, a modal dialog, or a wedged command. The Editor GUI may still respond. Ask the user to look for a dialog in the Unity window; exiting Play mode or restarting the Editor frees a wedged gate (Window/Pipeline/Stop Server goes through the same gate and will not get in).
- A response with `busyReason: "blocked_by_dialog"` (Unity 6000.7+) lists the dialogs: report their titles and buttons to the user.

**Rules (every channel):**
- **Never `kill` Unity** (including Workers) — risks Library corruption and cascade failures
- Never launch Unity from the command line (easy to pick the wrong version); ask the user to open it via Unity Hub
- If the health check fails, stop and report — do not attempt workarounds

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

### 3. Run tests

Select command based on arguments:

| Argument | Command |
|----------|---------|
| (none) + `default_test_scope=all` | `unity-unit-test.sh` |
| (none) + `default_test_scope=editmode` | `unity-test.sh editmode` |
| `editmode` | `unity-test.sh editmode` |
| `playmode` | `unity-test.sh playmode` |
| with filter/assembly | `unity-test.sh <mode> --filter "X"` or `unity-test.sh <mode> --assembly "Y"` |

- With arguments, call `unity-test.sh` and pass all arguments through
- The script picks the channel and the default wait (`--timeout`) itself; only pass `--timeout` when the user asks for one
- **Official CLI: a full EditMode run can take 10+ minutes.** Run the script with the Bash tool's `run_in_background`, or, if a wait is cut short, resume the same run with the command the script printed at submission (`unity-test.sh editmode --job <jobId>`, plus the same filter). **Never re-run to "retry" a wait** — that submits the whole suite again and cancels the run in flight. PlayMode cannot be resumed: let the run finish in Unity before re-running. **Do not edit scripts while an official-CLI EditMode run is in flight**: the auto-compile hook cannot see a detached test job, and its recompile stays queued in Unity — once the run ends it may reload the domain before the script has collected the result (`test_job_lost`).
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

### 4. Check runtime errors

Check Editor.log even when all tests pass (it does not depend on the console buffer):

```bash
tail -n +$((BASELINE + 1)) "$EDITOR_LOG" | \
  grep -iE "NullReferenceException|Exception:|Error\b" | \
  grep -v "^UnityEngine\.\|^Cysharp\.\|^System\.Threading\.\|^  at \|CompilerError\|StackTrace" | \
  sort -u
```

**Show all errors to the user — do not filter or omit any.** Give each a source assessment (e.g. "from a safety test, likely expected") and let the user decide whether to act.

## On test failure

Read the failing test and the code under test, say whether the current changes introduced the failure or it was pre-existing, propose a concrete fix, and ask whether to apply it.

## Handoff

After tests complete, recommend the next step:

- **All tests pass, no runtime errors** → "All green. Next step: `<recommended_next>`." (from project state)
- **Tests pass but runtime errors found** → "Tests passed but found N runtime errors. Want me to investigate, or continue with the next recommended step?"
- **Test failures were fixed** → "Fixed N failures. Want to re-run `/qq:test` to confirm, or proceed to `/qq:doc-drift`?"

**`--auto` mode:** skip asking:
- All pass → run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:test" --next-skill "<recommended_next>"` (use the actual `recommended_next` from project state, not a hardcoded value), then continue with `recommended_next`
- Failures → auto-fix → re-run `/qq:test` (max 3 attempts, then stop and ask user)
