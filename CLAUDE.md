# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**quick-question** is the agent control plane for game-dev work. It is a Claude Code plugin **and** an engine-agnostic runtime: artifact-driven control (`/qq:go`), auto-compile hooks, test pipelines, deterministic policy checks, dual-mode cross-model / Claude-only code review with a verification loop, and 26 skills (`/qq:*`). It targets macOS and Windows (Windows requires Git for Windows for bash + core utilities). Engines at runtime parity: **Unity 2021.3+**, **Godot 4.x**, **Unreal 5.x**, **S&box**. Unity has the deepest integration via tykit (in-process HTTP server); the other three reach parity through Python bridges.

Although Claude Code gets the deepest integration (slash commands, hooks, review gates), the runtime core is agent-agnostic: scripts and bridges are plain shell + Python, and `.qq/` state is plain JSON. Codex CLI, Cursor, Continue, and any MCP-compatible host can use the same runtime through `qq_mcp.py` / `tykit_mcp.py` / direct HTTP.

## Repository Structure

- `hooks/hooks.json` — Hook definitions (PreToolUse, PostToolUse, Stop, SessionStart) loaded by the Claude Code plugin system
- `scripts/` — Bash + Python runtime: compile / test / review dispatchers, hook helpers, MCP bridges, controller, runtime helpers
  - `scripts/hooks/` — Hook implementations (`auto-compile.sh`, `compile-gate-check.sh`, `review-gate.sh`, `pre-push-test.sh`, `skill-modified-track.sh`, `auto-sync.sh`, `session-cleanup.sh`, `auto-pipeline-*`, `execute-resume-hint.sh`)
  - `scripts/platform/` — OS detection helpers
  - `scripts/qq_engine.py` — multi-engine source-file matcher (`matches-source`)
  - `scripts/qq-compile.sh` — multi-engine compile dispatcher (delegates to `unity-compile-smart.sh` / `godot-compile.sh` / `unreal-compile.sh` / `sbox-compile.sh`)
  - `scripts/qq-test.sh` — multi-engine test dispatcher
  - `scripts/qq-project-state.py` — artifact-driven controller (preferred path for `/qq:go`)
  - `scripts/qq-policy-check.sh` — deterministic policy checks (run before deeper review workflows)
  - `scripts/qq-decisions.py` — cross-skill decision journal (`session-decisions.json`)
- `engines/` — Per-engine assets (`unreal/`, `godot/`, `sbox/`); referenced by the install flow
- `shared/` — Shared prompt fragments (e.g. `verification-prompt.md`)
- `bin/` — Wrapper executables added to Claude Code's PATH so `SKILL.md` can call commands by bare name
- `.qq/` — Runtime data written **inside target projects** (`runs/`, `state/`, `telemetry/`), not in this repo
- `skills/` — 26 skill directories, each with a `SKILL.md`, invoked as `/qq:<name>`
- `packages/com.tyk.tykit/` — UPM package providing tykit (in-process HTTP server inside Unity Editor)
- `.claude-plugin/` — Plugin manifest (`plugin.json`, `marketplace.json`)
- `templates/` — `CLAUDE.md.example`, `AGENTS.md.example`, `qq.yaml.example` copied into target projects by `install.sh`
- `install.sh` — Installs scripts, templates, bridges, and tykit into a target project (auto-detects engine; supports `--wizard`, `--preset`, `--profile`, `--modules`, `--without`)
- `test.sh` — Self-tests: shellcheck, JSON validation, executable bits, README consistency (skill count + per-skill `/qq:` reference), benchmark suites

## Key Architecture

### Hook System

Defined in `hooks/hooks.json`. Hooks are the plugin's runtime behavior:

- **PreToolUse (Edit | Write):** Compile Gate (`compile-gate-check.sh`) blocks edits to engine source files when compile is red or the project has never been opened in its editor; Review Gate (`review-gate.sh check`) blocks code/doc edits while review verification is pending.
- **PostToolUse (Write | Edit):** Auto-compile (`auto-compile.sh`) compiles via `qq-compile.sh` after edits to engine source files. The dispatcher handles `.cs` (Unity / S&box), `.gd` (Godot), and C++ (Unreal). Skill file changes are tracked by `skill-modified-track.sh`.
- **PostToolUse (Bash):** `review-gate.sh set` activates the review gate when `code-review.sh`, `claude-review.sh`, `plan-review.sh`, or `claude-plan-review.sh` runs.
- **PostToolUse (Agent):** `review-gate.sh count` increments the verification subagent counter to release the review gate once all expected verifiers complete.
- **Stop:** `check-skill-review.sh` blocks session end if skills were modified without `/qq:self-review`; `review-gate.sh stop` blocks if verification is incomplete; `auto-pipeline-stop.sh` and `session-cleanup.sh` finalize state.
- **SessionStart:** `auto-sync.sh` syncs plugin scripts into the target project; on `compact`, `execute-resume-hint.sh` and `auto-pipeline-resume-hint.sh` surface in-flight work.

All gate / temp files are keyed by the Claude Code session id for session isolation (e.g. `$QQ_TEMP_DIR/review-gate-<session_id>`, `$QQ_TEMP_DIR/compile-gate-<session_id>`). Hooks read `session_id` from their stdin JSON, skill Bash snippets read `CLAUDE_CODE_SESSION_ID` (same value; subagents carry the parent session's id); both go through `qq_session_id` in `scripts/platform/detect.sh`. Never key on `$PPID` — under Windows Git Bash it is always 1, so every session would share one gate file. No session id → no gate (never fall back to a shared file).

Hook scripts read tool input from stdin via the shared `qq_hook_input` helper in `scripts/qq-runtime.sh` (jq-first, with a `$QQ_PY` python fallback so hooks work even when jq is missing).

### Artifact-driven Controller

`/qq:go` should prefer `scripts/qq-project-state.py` when available. It is a controller, not an implementation engine:

1. Read project state from artifacts and recent run records
2. Recommend the next skill
3. Only fall back to prompt / context heuristics when state is ambiguous

The decision journal (`scripts/qq-decisions.py`) records cross-skill decisions in `.qq/state/session-decisions.json` so later skills can stay coherent with earlier ones.

### Runtime Data + Policy

- `scripts/qq-run-record.py` and `scripts/qq-runtime.sh` write structured runtime data to `.qq/`
- `scripts/qq-policy-check.sh` runs deterministic engine checks (compile / test / asset hygiene) before deeper best-practice or review workflows
- `.qq/state/*.json` is the preferred source for the latest compile / test state; raw `.qq/runs/*.json` logs are for debugging or CI-style consumption
- `.qq/state/session-decisions.json` is the cross-skill decision journal

### Smart Compile Dispatch

`scripts/qq-compile.sh` is the multi-engine entry point. It detects the active engine and delegates:

- **Unity** → `unity-compile-smart.sh`, which picks the best path:
  1. **tykit mode** — HTTP call to in-process Unity server (fastest, non-blocking)
  2. **Editor trigger** — osascript (macOS) or PowerShell (Windows) to trigger compile in an open Editor
  3. **Batch mode** — `Unity -quit -batchmode` (when the Editor is closed)
- **Godot** → `godot-compile.sh` (headless `--check-only` GDScript validation)
- **Unreal** → `unreal-compile.sh` (UnrealBuildTool + editor commandlet)
- **S&box** → `sbox-compile.sh` (`dotnet build`)

Shared utilities live in `unity-common.sh` / `godot-common.sh` / `unreal-common.sh` / `sbox-common.sh` (Editor detection, paths, port discovery).

### tykit

UPM package at `packages/com.tyk.tykit/`. An HTTP server auto-starting in Unity Editor, exposing commands: status, compile, run-tests, play / stop, console, find / inspect. Port stored in `Temp/tykit.json` (hash of project path). Works standalone without qq; the Python bridge `tykit_bridge.py` and the MCP wrapper `tykit_mcp.py` expose the same surface to non-Unity hosts.

### Code Review

Two symmetric review modes share the same verification loop:

- **Claude review** (`/qq:claude-code-review`): `claude-review.sh` → `claude -p` (process-isolated), then verification subagents check each finding
- **Codex review** (`/qq:codex-code-review`): `code-review.sh` → `codex exec` (cross-model), then verification subagents check each finding

Both modes: over-engineering check, fix confirmed issues, loop until clean (max 5 rounds). The unified review gate (`scripts/hooks/review-gate.sh`) blocks code edits until ALL verification subagents complete (three-field gate format: `<ts>:<completed>:<expected>`). MCP exposes one-shot `qq_code_review` and `qq_plan_review` tools for non-Claude hosts.

There are also legacy `review-gate-{check,set,count,stop}.sh` scripts kept for backward compatibility with already-installed projects; new hook bindings should use `review-gate.sh <subcommand>`.

## Development Commands

```bash
# Test the installer against a project
./install.sh /path/to/your-project

# Validate shell scripts
shellcheck scripts/*.sh scripts/hooks/*.sh

# Validate hook JSON
python3 -m json.tool hooks/hooks.json > /dev/null

# Run the full self-test suite (shellcheck, JSON, structural checks, README consistency, benchmark suites)
./test.sh
```

There is no build step or package manager for this repo itself. The scripts and skills are consumed as-is by the Claude Code plugin system.

## Conventions

- Scripts use `set -euo pipefail` and source `qq-runtime.sh` / `platform/detect.sh` / engine-specific common files for shared functions
- Skills are each a directory under `skills/<name>/` containing `SKILL.md`
- Hook scripts in `scripts/hooks/` parse stdin JSON via `qq_hook_input` (jq-first, python3 fallback) — never call `jq` directly in new hook scripts
- Comments in shell scripts are in Chinese (author preference); code identifiers and user-facing output are in English
- `install.sh` output uses the current plugin skill names (`/qq:test`, `/qq:commit-push`, etc.)
- `.gitattributes` enforces LF line endings for `.sh` and `.py` so Windows checkouts don't corrupt hook scripts
- Comments and side-effects in hook scripts must remain idempotent; hooks may fire twice on the same input
- **Chinese README has one canonical source** — `docs/zh-CN/README.md` is the canonical file; the Chinese half embedded in the root `README.md` is auto-generated by `scripts/qq-sync-readme-zh.py` (it strips the title + lang nav and rewrites relative paths to be repo-rooted). Workflow: edit `docs/zh-CN/README.md`, then run `python scripts/qq-sync-readme-zh.py --write` to mirror, then commit both. `test.sh` section 4 enforces the contract via `--check` and fails CI with a `DRIFT` message if you skip the sync. Do not edit the root README's Chinese half directly — your changes will be clobbered the next time someone runs the sync.

## Windows release gotchas

Two recurring traps when releasing from a Windows host. Both have bitten CI more than once — see commits `eedebe2`, `64bce1d`.

- **`chmod +x` on Windows does not write the git index mode bit.** New `.sh` / `.py` scripts ship as `100644` even after a successful local `chmod`, and `test.sh` section 7 (Script permissions) catches it on Linux CI as `NOT executable`. When adding any new executable script, run `git update-index --chmod=+x <path>` and verify with `git ls-files --stage <path>` (look for `100755`, not `100644`) **before** committing. The Edit / Write tool path is the most common offender — Bash `chmod` is invisible to git index.
- **`qq-release.sh --watch` has a fetch race.** It calls `gh run list` *before* the new commit's CI run has been registered, so the "CI green" message at the end of `qq-release.sh patch ...` may be reporting the *previous* release's run, not the one you just triggered. After the script claims success, always re-confirm with `gh run list --limit 2 --branch main` to make sure the latest run on top is actually green for the commit you just pushed.
