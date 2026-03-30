# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**quick-question** is a Claude Code plugin that provides a Unity developer-loop runtime: artifact-driven control (`/qq:go`), auto-compilation hooks, test pipelines, executable policy checks, cross-model and Claude-only code review, and 22 skills (`/qq:*`). It targets macOS + Windows (Windows requires Git for Windows) with Unity 2021.3+.

## Repository Structure

- `hooks/hooks.json` — Hook definitions (PreToolUse, PostToolUse, Stop) loaded by the Claude Code plugin system
- `scripts/` — Bash scripts for compilation, testing, and review (run inside the target Unity project)
- `.qq/` — Runtime data written in target Unity projects (`runs/`, `state/`, `telemetry/`)
- `skills/` — 22 skill definitions (each has a `SKILL.md`), invoked as `/qq:<name>`
- `packages/com.tyk.tykit/` — UPM package providing tykit (in-process HTTP server for Unity Editor control)
- `.claude-plugin/` — Plugin manifest (`plugin.json`, `marketplace.json`)
- `templates/` — `CLAUDE.md.example` and `AGENTS.md.example` copied into target projects by `install.sh`
- `install.sh` — Installs scripts, templates, and tykit into a Unity project

## Key Architecture

### Hook System

Defined in `hooks/hooks.json`, hooks are the plugin's runtime behavior:

- **PreToolUse (Edit|Write):** Codex Review Gate — blocks code edits while cross-model review verification is pending
- **PostToolUse (Write|Edit):** Auto-compiles `.cs` files via `unity-compile-smart.sh`; tracks skill file modifications for review enforcement
- **PostToolUse (Bash):** Activates review gate when `code-review.sh` or `plan-review.sh` runs
- **PostToolUse (Agent):** Increments verification subagent counter (to release review gate)
- **Stop:** Blocks session end if skills were modified without running `/qq:self-review`; cleans up gate files

All temp files are keyed by `$PPID` for session isolation (e.g., `/tmp/claude-codex-review-gate-$PPID`).

### Artifact-driven Controller

`/qq:go` should prefer `scripts/qq-project-state.py` when available. It is a controller, not an implementation engine:

1. Read project state from artifacts and recent run records
2. Recommend the next skill
3. Only fall back to prompt/context heuristics when state is ambiguous

### Runtime Data + Policy

- `scripts/qq-run-record.py` and `scripts/qq-runtime.sh` write structured runtime data to `.qq/`
- `scripts/qq-policy-check.sh` runs deterministic Unity checks before deeper best-practice or review workflows
- `.qq/state/*.json` is the preferred source for latest compile/test state; raw `.qq/runs/*.json` logs are for debugging or CI-style consumption

### Smart Compilation Stack

`unity-compile-smart.sh` is the orchestrator, choosing the best path:
1. **tykit mode** — HTTP call to in-process Unity server (fastest, non-blocking)
2. **Editor trigger** — osascript (macOS) or PowerShell (Windows) to trigger compile in open Unity (fallback)
3. **Batch mode** — `Unity -quit -batchmode` (when Editor is closed)

Shared utilities live in `unity-common.sh` (Editor detection, Unity path lookup, tykit port discovery).

### tykit

UPM package at `packages/com.tyk.tykit/`. An HTTP server auto-starting in Unity Editor, exposing commands: status, compile, run-tests, play/stop, console, find/inspect. Port stored in `Temp/tykit.json` (hash of project path).

### Cross-Model Review (Codex Tribunal)

`/qq:codex-code-review` implements a verification loop:
1. Codex CLI reviews the diff
2. Subagents verify each finding against actual source
3. Over-engineering check — is the fix proportionate?
4. Fix confirmed critical issues, loop until clean (max 5 rounds)

The review gate (`scripts/hooks/codex-review-gate-*.sh`) blocks code edits until at least one verification subagent completes.

## Development Commands

```bash
# Test the installer against a Unity project
./install.sh /path/to/unity-project

# Validate shell scripts
shellcheck scripts/*.sh

# Validate hook JSON
python3 -m json.tool hooks/hooks.json > /dev/null
```

There is no build step or package manager for this repo itself. Run `./test.sh` for self-tests (shellcheck, JSON validation, structural checks, README consistency). The scripts and skills are consumed as-is by the plugin system.

## Conventions

- Scripts use `set -euo pipefail` and source `unity-common.sh` for shared functions
- Skills are each a directory under `skills/<name>/` containing `SKILL.md`
- Hook scripts in `scripts/hooks/` follow the naming pattern `codex-review-gate-{check,set,count}.sh`
- Comments in shell scripts are in Chinese (author preference); code and user-facing output are in English
- The `install.sh` output now uses the current plugin skill names (`/qq:test`, `/qq:commit-push`, etc.)
