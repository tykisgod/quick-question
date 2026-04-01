# Hook System

Claude Code hooks are shell scripts that fire automatically in response to tool use events. qq uses hooks for auto-compilation, review gating, skill modification tracking, and session cleanup. All hooks are defined in [`hooks/hooks.json`](../hooks/hooks.json).

## Hook Summary

| Trigger | Matcher | Script | Purpose |
|---------|---------|--------|---------|
| PreToolUse | `Edit\|Write` | `codex-review-gate-check.sh` | Block edits while review verification is pending |
| PostToolUse | `Write\|Edit` | `auto-compile.sh` | Auto-compile engine source files after edits |
| PostToolUse | `Write\|Edit` | `skill-modified-track.sh` | Record when skill files are modified |
| PostToolUse | `Bash` | `codex-review-gate-set.sh` | Activate the review gate after a code/plan review |
| PostToolUse | `Agent` | `codex-review-gate-count.sh` | Count verification subagent completions |
| Stop | (all) | `check-skill-review.sh` | Block session end if skills were modified without review |
| Stop | (all) | `session-cleanup.sh` | Remove temp files for the session |

## Hook Types

There are three trigger types:

- **PreToolUse** -- runs before a tool executes. A non-zero exit or a `"decision":"block"` response prevents the tool from running.
- **PostToolUse** -- runs after a tool completes. Can inject context back into the conversation via `hookSpecificOutput`.
- **Stop** -- runs when the session is about to end. Can block session termination.

## Auto-Compile Hook

**Script:** `scripts/hooks/auto-compile.sh`
**Trigger:** PostToolUse for `Write|Edit`
**Timeout:** 120 seconds

When a file is written or edited, this hook checks whether the file is an engine source file (`.cs` or engine-specific, determined by `qq_engine.py matches-source`). If so, it calls the smart compilation stack via `qq-compile.sh`:

1. **tykit mode** -- HTTP call to the in-process Unity server (fastest, non-blocking).
2. **Editor trigger** -- osascript (macOS) or PowerShell (Windows) to trigger compile in an open Unity Editor.
3. **Batch mode** -- `Unity -quit -batchmode` when the Editor is closed.

Compile output appears in the terminal. Claude reads any errors and fixes them automatically in the same turn. The hook is gated by the `auto_compile` setting in the active qq profile -- if disabled, it exits immediately.

## Review Gate

Three scripts coordinate to enforce verification before edits resume after a cross-model code review.

### Activating the Gate

**Script:** `scripts/hooks/codex-review-gate-set.sh`
**Trigger:** PostToolUse for `Bash`

After a Bash command completes, this hook checks whether the command invoked `code-review.sh` or `plan-review.sh`. If so, it creates a gate file at `$QQ_TEMP_DIR/claude-codex-review-gate-$PPID` with the format `<unix_timestamp>:0` (timestamp and zero verified subagents). It also injects context telling Claude to dispatch verification subagents for each finding.

### Checking the Gate

**Script:** `scripts/hooks/codex-review-gate-check.sh`
**Trigger:** PreToolUse for `Edit|Write`
**Timeout:** 5 seconds

Before any edit or write, this hook checks whether a gate file exists for the current session. If the gate is active and no verification subagent has completed yet (`count == 0`), it blocks the edit. The gate only blocks edits to relevant file types (`.cs` files and `Docs/*.md`). Gates expire automatically after 2 hours.

### Counting Verifications

**Script:** `scripts/hooks/codex-review-gate-count.sh`
**Trigger:** PostToolUse for `Agent`

Each time a subagent completes, this hook increments the counter in the gate file. Once the count reaches 1, the gate allows edits to proceed. The hook injects context confirming verification was recorded.

## Skill Modification Tracking

**Script:** `scripts/hooks/skill-modified-track.sh`
**Trigger:** PostToolUse for `Write|Edit`

When a skill file is written or edited (paths matching `*/.claude/commands/*.md` or `*/skills/*/SKILL.md`), this hook appends the file path to a marker file at `$QQ_TEMP_DIR/claude-skill-modified-marker-$PPID`.

At session end, the Stop hook `check-skill-review.sh` checks whether the marker file exists. If skills were modified but `/qq:self-review` was never run, the hook blocks session termination with an error listing the modified files. Running `/qq:self-review` deletes the marker file, clearing the gate.

## Session Cleanup

**Script:** `scripts/hooks/session-cleanup.sh`
**Trigger:** Stop
**Timeout:** 2 seconds

Removes all temp files for the current session: gate files, skill modification markers, and any other session-scoped state. Also triggers a context capsule build (`pre_clear`) and prunes stale runtime data.

## Session Isolation

All temp files use the `$PPID` suffix (the parent process ID of the hook shell). This ensures concurrent Claude Code sessions do not interfere with each other -- each session's gate, counters, and markers are independent.

## Pre-Push Hook (Optional)

**Script:** `scripts/hooks/pre-push-test.sh`

Not registered in `hooks.json` by default. When installed (via `install.sh --with-pre-push`), this PreToolUse hook intercepts `git push` commands and runs the test suite first. If tests fail, the push is blocked.

## Related Docs

- [Architecture Overview](architecture/overview.md)
- [Cross-Model Review](cross-model-review.md) -- how the review gate fits into the tribunal flow
- [Configuration](configuration.md) -- controlling hook behavior
