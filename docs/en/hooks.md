# Hook System

Claude Code hooks are shell scripts that fire automatically in response to tool-use and session events. qq uses hooks for auto-compilation, compile and review gating, skill modification tracking, auto-sync, session cleanup, and post-compaction resume hints. All plugin-level hooks are defined in [`hooks/hooks.json`](../../hooks/hooks.json); a few project-local hooks (e.g. `pre-push-test.sh`) are wired through `.claude/settings.json` instead.

## Hook Summary

| Trigger | Matcher | Script | Purpose |
|---------|---------|--------|---------|
| PreToolUse | `Edit\|Write` | `compile-gate-check.sh` | Block edits to engine source files when compile is red, or when the project has never been opened in its editor |
| PreToolUse | `Edit\|Write` | `review-gate.sh check` | Block edits while review verification is pending |
| PreToolUse | `Bash` *(project-local)* | `pre-push-test.sh` | Block `git push` until `./test.sh` passes |
| PostToolUse | `Write\|Edit` | `auto-compile.sh` | Auto-compile engine source files via `qq-compile.sh` (multi-engine dispatcher) |
| PostToolUse | `Write\|Edit` | `skill-modified-track.sh` | Record when skill files are modified |
| PostToolUse | `Bash` | `review-gate.sh set` | Announce the review gate a code/plan review script just opened |
| PostToolUse | `Agent` | `review-gate.sh count` | Count verification subagent completions to release the review gate |
| Stop | (all) | `check-skill-review.sh` | Block session end if skills were modified without `/qq:self-review` |
| Stop | (all) | `review-gate.sh stop` | Block session exit if review verification is incomplete |
| Stop | (all) | `auto-pipeline-stop.sh` | Block session exit during an active `/qq:execute --auto` pipeline |
| Stop | (all) | `session-cleanup.sh` | Remove temp files, clear gate, prune stale runtime data |
| SessionStart | (startup) | `auto-sync.sh` | Sync plugin scripts into the target project after a plugin upgrade |
| SessionStart | `compact` | `execute-resume-hint.sh` | Surface in-flight `/qq:execute` progress after context compaction |
| SessionStart | `compact` | `auto-pipeline-resume-hint.sh` | Surface in-flight auto-pipeline state after context compaction |

## Hook Trigger Types

- **PreToolUse** -- runs before a tool executes. A non-zero exit or `"decision":"block"` response prevents the tool from running.
- **PostToolUse** -- runs after a tool completes. Can inject context back into the conversation via `hookSpecificOutput`.
- **Stop** -- runs when the session is about to end. Can block session termination.
- **SessionStart** -- runs when a session starts (`startup`) or after context compaction (`compact`). Can inject startup context.

## Compile Gate

The compile gate is a project-level guard that blocks edits to engine source files until the compile is green and the project has been opened at least once in its editor.

**Script:** `scripts/hooks/compile-gate-check.sh`
**Trigger:** PreToolUse for `Edit|Write`
**Timeout:** 5 seconds

The hook runs two checks against the file path being edited (only when the file matches an engine source pattern via `qq_engine.py matches-source`):

1. **Virgin project check** -- a project-level fact, read from the filesystem. Unity projects need `Library/`; Godot projects need `.godot/`; Unreal projects need `Intermediate/`. If the marker is missing, the agent is told to open the project in its editor first and let the initial import finish.
2. **Compile gate check** -- a session-level state, scoped by the session id. After a failed compile, `auto-compile.sh` writes `$QQ_TEMP_DIR/compile-gate-<session_id>`. The check hook reads the file, verifies it has not aged out (1 hour), and blocks the edit until the gate clears. The gate clears automatically on the next successful compile, or expires after 1 hour.

The gate is keyed by the session id so concurrent Claude Code sessions never see each other's compile state.

## Auto-Compile

**Script:** `scripts/hooks/auto-compile.sh`
**Trigger:** PostToolUse for `Write|Edit`
**Timeout:** 120 seconds

When a file is written or edited, this hook checks whether the file is an engine source file (decided by `qq_engine.py matches-source` against the active engine). If so, it calls `qq-compile.sh`, which delegates to the right engine path:

- **Unity** → `unity-compile-smart.sh`, which picks tykit HTTP, editor trigger (osascript / PowerShell), or batch mode
- **Godot** → `godot-compile.sh` (headless GDScript validation)
- **Unreal** → `unreal-compile.sh` (UnrealBuildTool + editor commandlet)
- **S&box** → `sbox-compile.sh` (`dotnet build`)

Compile output appears in the terminal. The agent reads any errors and fixes them automatically in the same turn. On a red compile, the hook writes `compile-gate-<session_id>` so the next edit is blocked by the compile gate. On a green compile, the gate file is removed.

The hook is gated by the `auto_compile` setting in the active qq profile -- if disabled, it exits immediately.

## Review Gate

A unified script (`review-gate.sh`) coordinates four subcommands that together enforce verification before code edits resume after a code or plan review.

> Earlier installs may still have legacy `review-gate-{check,set,count,stop}.sh` files; new hook bindings should use the unified `review-gate.sh <subcommand>` form.

### Activating the Gate

**Script:** `scripts/hooks/review-gate.sh set`
**Trigger:** PostToolUse for `Bash`

The gate is opened by the review scripts themselves, not guessed from command text. When `code-review.sh`, `claude-review.sh`, `plan-review.sh`, or `claude-plan-review.sh` finishes a review, it calls `qq_review_gate_open` (`scripts/platform/detect.sh`), which writes `$QQ_TEMP_DIR/review-gate-<session_id>` in the three-field format `<unix_timestamp>:<completed>:<expected>` (timestamp, zero completed verifications, expected verification count) plus a one-shot `.announce` marker. A failed review, or one with nothing to review, opens no gate; without a session id (e.g. an MCP host) no gate is opened either.

After each Bash command, this hook looks for that marker. If it is there, the hook consumes it and injects context telling the agent to dispatch verification subagents for each finding. A command that merely mentions a review script (an `echo`, a `grep`, a heredoc) never opens the gate. The older version matched `./scripts/code-review.sh` in the command text, so those mentions did open it. Meanwhile, the `${CLAUDE_PLUGIN_ROOT}/bin/...` calls the skills actually make never matched.

### Checking the Gate

**Script:** `scripts/hooks/review-gate.sh check`
**Trigger:** PreToolUse for `Edit|Write`
**Timeout:** 5 seconds

Before any edit or write, this hook checks whether a gate file exists for the current session. If the gate is active and not all verification subagents have completed (`completed < expected`), it blocks the edit. The gate only blocks edits to relevant file types (`.cs` files and `Docs/*.md`). Gates expire automatically after 2 hours.

### Counting Verifications

**Script:** `scripts/hooks/review-gate.sh count`
**Trigger:** PostToolUse for `Agent`

Each time a subagent completes, this hook increments the completed counter in the gate file. Once `completed >= expected`, the gate releases edits. The hook injects context confirming the count.

### Blocking Session Exit on Incomplete Verification

**Script:** `scripts/hooks/review-gate.sh stop`
**Trigger:** Stop

When the session is about to end, this hook checks whether the review gate is active with incomplete verifications (`completed < expected`). If so, it blocks termination so verification subagents can finish.

## Skill Modification Tracking

**Script:** `scripts/hooks/skill-modified-track.sh`
**Trigger:** PostToolUse for `Write|Edit`

When a skill file is written or edited (paths matching `*/.claude/commands/*.md` or `*/skills/*/SKILL.md`), this hook appends the file path to `$QQ_TEMP_DIR/claude-skill-modified-marker-<session_id>`.

At session end, the Stop hook `check-skill-review.sh` checks the marker file. If skills were modified but `/qq:self-review` was never run, the hook blocks termination with an error listing the modified files. Running `/qq:self-review` clears the marker.

## Auto-Pipeline Stop Guard

**Script:** `scripts/hooks/auto-pipeline-stop.sh`
**Trigger:** Stop

When `/qq:execute --auto` is running an unattended pipeline (`.qq/state/auto-pipeline.json` is present and active), this hook prevents the session from ending mid-pipeline. The actual circuit-breaker logic lives in `qq-execute-checkpoint.py pipeline-block`, which decides whether the pipeline is still in progress.

## Session Cleanup

**Script:** `scripts/hooks/session-cleanup.sh`
**Trigger:** Stop
**Timeout:** 2 seconds

Removes this session's review gate file (and only this session's) and prunes stale runtime data via `qq_runtime_prune`.

## SessionStart Hooks

### Auto-Sync (startup)

**Script:** `scripts/hooks/auto-sync.sh`
**Timeout:** 10 seconds

When a session starts, this hook calls `qq-auto-sync.py` to mirror the latest plugin scripts into the target project's `scripts/` directory. This is how a plugin upgrade reaches an installed project without forcing the user to re-run `install.sh`.

### Resume Hints (compact)

After context compaction, two hooks read state files written by long-running skills and inject resume hints so the agent picks up where it left off:

- **`execute-resume-hint.sh`** -- reads `.qq/state/execute-progress.json` (written by `/qq:execute`) and reports the in-flight phase, completed steps, and what to run next.
- **`auto-pipeline-resume-hint.sh`** -- reads `.qq/state/auto-pipeline.json` (written by `/qq:execute --auto`) and reports the in-flight pipeline stage so the unattended loop continues correctly.

Both hooks exit silently if the corresponding state file is absent.

## Pre-Push Test Gate (Optional)

**Script:** `scripts/hooks/pre-push-test.sh`

This is a project-local hook registered through `.claude/settings.json` (not the plugin's `hooks.json`), so it only fires for projects that opt in. When installed via `install.sh --with-pre-push` (or by hand), it intercepts `git push` commands and runs `./test.sh` before allowing the push. If tests fail, the push is blocked.

## Session Isolation

All gate and marker files use the Claude Code session id as their suffix. Hooks read `session_id` from their stdin JSON; skill Bash snippets read `CLAUDE_CODE_SESSION_ID` (the same value -- subagents carry their parent session's id, so a session and its subagents share one gate). Both go through `qq_session_id` in `scripts/platform/detect.sh`, which only accepts filename-safe ids. This ensures concurrent Claude Code sessions do not interfere with each other -- each session's compile gate, review gate, and skill markers are scoped to its own id. Shared hook state would cause one session's red compile to block another session's edits.

Earlier versions keyed these files by `$PPID`. Under Windows Git Bash that is always 1, so every session on the machine shared one gate file. When no session id is available, hooks create and check no gate at all rather than fall back to a shared file.

## Implementation Notes

### Hook Input Parsing

Hook scripts read tool input from stdin via the shared `qq_hook_input` helper in [`scripts/qq-runtime.sh`](../../scripts/qq-runtime.sh). The helper prefers `jq` when available and falls back to `$QQ_PY` (python3) otherwise -- so hooks work on Windows boxes that have python3 but not jq, without crashing the host script under `set -euo pipefail`.

```bash
file_path="$(qq_hook_input tool_input.file_path)"
cmd="$(qq_hook_input tool_input.command)"
```

New hook scripts should never call `jq` directly.

### Idempotency

Hooks may fire twice for the same input (Claude Code retries on transient failures). Side effects (writing gate files, appending to markers, recording run state) must be idempotent. Most current hooks achieve this by writing-then-overwriting rather than appending, or by guarding appends with a marker check.

### Engine Detection

Hooks that care about engine type call `qq_engine.py matches-source` rather than hardcoding `*.cs`. This is how the same `auto-compile.sh` and `compile-gate-check.sh` work correctly across Unity, Godot, Unreal, and S&box.

## Related Docs

- [Architecture Overview](../dev/architecture/overview.md)
- [Cross-Model Review](cross-model-review.md) -- how the review gate fits into the tribunal flow
- [Configuration](configuration.md) -- controlling which hooks run via the active profile
