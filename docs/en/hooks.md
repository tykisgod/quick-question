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

- **PreToolUse** -- runs before a tool executes. Exit code 2 (stderr is fed back to Claude) or a `"decision":"block"` / `permissionDecision: deny` response prevents the tool from running. Any other non-zero exit is only a non-blocking error: Claude Code shows it and runs the tool anyway, so gate checks must exit 2.
- **PostToolUse** -- runs after a tool completes. Can inject context back into the conversation via `hookSpecificOutput`.
- **Stop** -- runs when the session is about to end. Can block session termination.
- **SessionStart** -- runs when a session starts (`startup`) or after context compaction (`compact`). Can inject startup context.

## Compile Gate

The compile gate blocks edits to engine source files while this session's last compile is red, and until the project has been opened at least once in its editor. Both checks block with exit 2.

**Script:** `scripts/hooks/compile-gate-check.sh`
**Trigger:** PreToolUse for `Edit|Write`
**Timeout:** 5 seconds

The hook runs two checks against the file path being edited (only when the file matches an engine source pattern via `qq_engine.py matches-source`):

1. **Virgin project check** -- a project-level fact, read from the filesystem. Unity projects need `Library/`; Godot projects need `.godot/`; Unreal projects need `Intermediate/`. If the marker is missing, the agent is told to open the project in its editor first and let the initial import finish. Linked git worktrees (`.git` is a file) are exempt. These directories are gitignored, so a worktree never has them, and that doesn't mean the editor was never opened. Use `qq-worktree.py seed-runtime-cache` to give a worktree a cache.
2. **Compile gate check** -- scoped by session id *and* project. After a definitively red compile, `auto-compile.sh` writes `$QQ_TEMP_DIR/compile-gate-<session_id>-<project hash>`. A compile counts as definitively red when the compile script exits 1 and its output points at errors in files inside the project. Because the gate is per project, another project or worktree the session touches is never blocked or released by this one.

   While the gate is up, these files stay editable:
   - files with errors, and the files whose edits triggered compiles; the list accumulates over a red streak, so an earlier change can still be reverted
   - files of types the error messages name, e.g. `Service.cs` for `'Service' does not contain a definition for 'Foo'`
   - new files
   - files outside the project

   Without these, the errors could not be fixed through Edit. `qq_compile_gate.py check` blocks edits to every other existing engine source file in the project until the gate clears. It clears on the next green auto-compile, on a green manual `qq-compile.sh` run in the same session (`--help` doesn't count), or after 1 hour.

No gate is opened when the compile produced no verdict (exit 2: editor closed, timeout, refused batch fallback), or when it exited 1 without error locations (a toolchain or environment problem). A gate that is already up is left alone in both cases. No gate is opened either while the `compile_gate` hook is disabled. The hook still reports the outcome to the agent. Godot `WARNING` blocks don't count as error locations.

Before 1.19.4 this check called an undefined `qq_detect_engine` and exited 127 before either check ran. It also used exit 1 to block. Neither the virgin check nor the compile gate ever blocked anything.

The gate is keyed by session id and project, so concurrent Claude Code sessions never see each other's compile state. The output is forced to UTF-8, so the ⛔ messages survive a non-UTF-8 Windows code page.

## Auto-Compile

**Script:** `scripts/hooks/auto-compile.sh`
**Trigger:** PostToolUse for `Write|Edit`
**Timeout:** 120 seconds

When a file is written or edited, this hook checks whether the file is an engine source file (decided by `qq_engine.py matches-source` against the active engine). If so, it calls `qq-compile.sh`, which delegates to the right engine path:

- **Unity** → `unity-compile-smart.sh`, which picks tykit HTTP, editor trigger (osascript / PowerShell), or batch mode
- **Godot** → `godot-compile.sh` (headless GDScript validation)
- **Unreal** → `unreal-compile.sh` (UnrealBuildTool + editor commandlet)
- **S&box** → `sbox-compile.sh` (`dotnet build`)

The compile log goes to the hook's stderr. Its stdout carries exactly one JSON object, whose `additionalContext` brings the errors, the gate status, and the files that stay editable to the agent. Earlier versions mixed the log into stdout, so Claude Code never parsed the JSON and the agent never saw it. On a definitively red compile, the hook writes `compile-gate-<session_id>` (see above). On a green compile, the gate file is removed. When the compile produced no verdict, the gate is left as it was.

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

Before any edit or write, this hook checks whether a gate file exists for the current session. If the gate is active and not all verification subagents have completed (`completed < expected`), it blocks the edit with exit 2. The gate only blocks edits to relevant file types (`.cs` and `Docs/*.md`; Windows backslash paths and upper-case extensions included). Gates expire automatically after 2 hours.

The gate governs the main agent only. A subagent's tool calls carry an `agent_id` but share the main session's id, so a gate that also blocked subagents would lock every parallel subagent the moment one of them finished a review. Verification subagents only read anyway.

### Counting Verifications

**Script:** `scripts/hooks/review-gate.sh count`
**Trigger:** PostToolUse for `Agent`

Each time an Agent call made by the main agent completes, this hook increments the completed counter in the gate file. Agent calls made by subagents don't count. Once `completed >= expected`, the gate releases edits. The hook injects context confirming the count.

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

Only paths inside the project root count. `matches-source` / `matches-verification` first make the path absolute (a relative path is read against the project root) and answer `false` when it lies outside the root, including a relative path whose `..` climbs out of it — so writing a `.cs` into a scratch directory neither triggers a compile nor hits the compile gate. Drive-letter case, `C:/` vs `C:\` spellings, 8.3 short names, a root reached through a symlink or junction, and a differently cased spelling on a case-insensitive volume all count as the same location, and a project subdirectory that links outside the project (e.g. `Assets/Shared` as a junction) still counts as inside. Two refinements:

- A git worktree created under the project root (such as `<root>/.claude/worktrees/<name>`) is a separate checkout, so its files count as outside. Git submodules and nested clones under the root still count as inside.
- Unity local packages referenced from `Packages/manifest.json` as `file:<dir>` count as inside even when the directory lives outside the project root, because Unity compiles them into the project.

## Related Docs

- [Architecture Overview](../dev/architecture/overview.md)
- [Cross-Model Review](cross-model-review.md) -- how the review gate fits into the tribunal flow
- [Configuration](configuration.md) -- controlling which hooks run via the active profile
