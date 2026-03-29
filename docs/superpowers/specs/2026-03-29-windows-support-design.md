# Windows Support Design

**Date:** 2026-03-29
**Scope:** Full parity — all scripts, hooks, install, and tykit C# work on Windows
**Strategy:** Hybrid — cross-platform `.sh` scripts (via Git Bash on Windows) with platform-specific helpers

## 1. Architecture Overview

One set of main scripts (`.sh`, cross-platform via Git Bash), with platform-specific helpers called conditionally.

```
scripts/
├── unity-common.sh              # Refactored: sources platform/detect.sh, delegates to helpers
├── unity-compile.sh             # Cross-platform (uses unity-common.sh)
├── unity-compile-smart.sh       # Cross-platform (uses unity-common.sh)
├── unity-check.sh               # Cross-platform (uses unity-common.sh)
├── unity-test.sh                # Cross-platform (uses unity-common.sh)
├── unity-unit-test.sh           # Cross-platform
├── code-review.sh               # Already platform-agnostic
├── plan-review.sh               # Already platform-agnostic
├── platform/
│   ├── detect.sh                # Sets QQ_PLATFORM=macos|windows|linux, QQ_TEMP_DIR
│   ├── macos.sh                 # macOS: Unity paths, process detection, window focus, log paths
│   └── windows.sh               # Windows: Unity paths, process detection, window focus, log paths
├── hooks/
│   ├── hook-dispatch.sh         # Unified entry point for all hooks
│   ├── hook-dispatch.cmd        # Windows fallback: finds Git Bash, forwards to hook-dispatch.sh
│   ├── codex-review-gate-check.sh
│   ├── codex-review-gate-set.sh
│   ├── codex-review-gate-count.sh
│   └── pre-push-test.sh
├── check-skill-review.sh           # Lives at scripts/ level, not in hooks/
```

### Prerequisite on Windows

- **Git for Windows** (ships bash, curl, GNU stat, grep, sed, awk)
- `python3` and `jq` installed via `winget` or manually

## 2. Platform Detection (`scripts/platform/detect.sh`)

Sources at the top of `unity-common.sh`. Sets exported variables and loads the correct platform helper.

```bash
#!/usr/bin/env bash

case "$(uname -s)" in
  Darwin*)              QQ_PLATFORM="macos"   ;;
  MINGW*|MSYS*|CYGWIN*) QQ_PLATFORM="windows" ;;
  Linux*)               QQ_PLATFORM="linux"   ;;
  *)                    QQ_PLATFORM="unknown"  ;;
esac

if [[ "$QQ_PLATFORM" == "windows" ]]; then
  QQ_TEMP_DIR="${TEMP:-/tmp}"
else
  QQ_TEMP_DIR="/tmp"
fi

export QQ_PLATFORM QQ_TEMP_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/${QQ_PLATFORM}.sh" ]]; then
  source "$SCRIPT_DIR/${QQ_PLATFORM}.sh"
fi
```

If `QQ_PLATFORM=unknown`, functions print a warning and return failure (graceful degradation).

## 3. Platform Helper Interface

Both `macos.sh` and `windows.sh` export identical function signatures:

| Function | Purpose | macOS | Windows |
|----------|---------|-------|---------|
| `qq_find_unity_binary` | Path to Unity executable | `/Applications/Unity/Hub/Editor/*/Unity.app/Contents/MacOS/Unity` | `C:/Program Files/Unity/Hub/Editor/*/Editor/Unity.exe` |
| `qq_is_unity_running` | Is Unity running (optionally for a project) | `pgrep -af "/Unity.app/Contents/MacOS/Unity"` | `tasklist /FI "IMAGENAME eq Unity.exe"` or `ps -W` |
| `qq_is_file_locked` | Is a file locked by a process | `lsof "$file"` | PowerShell `[IO.File]::Open()` try/catch |
| `qq_get_file_mtime` | File modification time (epoch seconds) | `stat -f %m "$file"` | `stat -c %Y "$file"` (GNU stat from Git Bash) |
| `qq_activate_unity_window` | Bring Unity to front, restore focus | `osascript` (AppleScript) | PowerShell `Add-Type` + Win32 `SetForegroundWindow` |
| `qq_get_editor_log_path` | Path to Unity Editor.log | `~/Library/Logs/Unity/Editor.log` | `$LOCALAPPDATA/Unity/Editor/Editor.log` |


> **Note:** Temp file paths are constructed directly using `$QQ_TEMP_DIR` (set by `detect.sh`) rather than a helper function, since the pattern is trivial: `$QQ_TEMP_DIR/$PREFIX-$$`.

Windows helpers call `powershell.exe -NoProfile -Command "..."` for operations Git Bash can't do natively (window focus, file lock checks).

**Note:** The `find_unity_eval` function in `unity-common.sh` uses `find` to locate `unity-eval.sh` in `Library/PackageCache`. This works as-is in Git Bash (which ships GNU find) and does not need a platform helper. The forward-slash paths used in Unity's `Library/PackageCache` are also valid in Git Bash on Windows.

## 4. Script Migration Details

### 4.1 `unity-common.sh`

**Before:** Contains macOS-specific logic inline (stat -f, pgrep -af, lsof, /Applications paths).

**After:** Sources `platform/detect.sh` at the top. All platform-specific logic replaced with `qq_*` function calls. The file becomes a thin dispatcher + shared logic only.

Key replacements:
- `stat -f %m` → `qq_get_file_mtime`
- `lsof "$lock_file"` → `qq_is_file_locked`
- `pgrep -af "/Unity.app/Contents/MacOS/Unity"` → `qq_is_unity_running`
- Hardcoded Unity paths → `qq_find_unity_binary`

### 4.2 `unity-check.sh`

**Before:** Contains `osascript` block for window activation (lines 167-174).

**After:** Replaced with `qq_activate_unity_window` call. The rest of the script logic (HTTP calls to tykit, compile checking) is already platform-agnostic.

### 4.3 `unity-compile-smart.sh`

**Before:** References osascript in comments (lines 104, 114), uses `unity-check.sh` as fallback.

**After:** Update comments to remove osascript references (cosmetic). No functional changes — it delegates to `unity-check.sh` and `unity-common.sh` which are now cross-platform.

### 4.4 `unity-compile.sh`

**Before:** Sources `unity-common.sh`, uses `/tmp` for log files.

**After:** Replace `/tmp` with `$QQ_TEMP_DIR`. Rest works via `unity-common.sh`.

### 4.5 `unity-test.sh`

**Before:** Sources `unity-common.sh`, uses `/tmp` for test result XML files, references `~/Library/Logs/Unity/Editor.log`.

**After:** Replace `/tmp` with `$QQ_TEMP_DIR`, replace log path with `qq_get_editor_log_path`.

### 4.6 `unity-unit-test.sh`

**Before:** Standalone, may use `/tmp`.

**After:** Replace `/tmp` with `$QQ_TEMP_DIR` if present.

### 4.7 Hook scripts (standalone `.sh` files)

**Before:** Use `/tmp/claude-*-$PPID` paths.

**After:** Replace with `$QQ_TEMP_DIR/claude-*-$PPID`. Source `platform/detect.sh` if not already sourced.

### 4.7.1 `hooks.json` inline commands

Two hooks in `hooks.json` embed `/tmp` directly in inline shell commands (not in separate `.sh` files):

- PostToolUse (Write|Edit) skill tracker: `echo "$f" >> /tmp/claude-skill-modified-marker-$PPID`
- Stop cleanup: `rm -f /tmp/claude-codex-review-gate-$PPID`

**Fix:** Extract these into standalone scripts (`scripts/hooks/skill-modified-track.sh` and `scripts/hooks/session-cleanup.sh`) that source `platform/detect.sh` and use `$QQ_TEMP_DIR`. Update `hooks.json` to call these scripts instead of inline commands.

### 4.8 `scripts/githooks/pre-push`

**Before:** Hardcodes `$HOME/Library/Logs/Unity/Editor.log`.

**After:** Source `platform/detect.sh` and use `qq_get_editor_log_path`.

### 4.9 `code-review.sh`

**Before:** Uses `mktemp /tmp/code-review-diff-XXXXXXXX` hardcoded to `/tmp`.

**After:** Replace with `mktemp "$QQ_TEMP_DIR/code-review-diff-XXXXXXXX"`. Source `platform/detect.sh` at the top.

### 4.10 Scripts requiring NO changes

- `plan-review.sh` — platform-agnostic

### 4.11 Skill SKILL.md files with hardcoded paths

Several skill definitions contain hardcoded `/tmp` or `~/Library/Logs` paths in their prompt text. Since Claude follows these literally, they must be updated:

| Skill | Hardcoded Path | Fix |
|-------|---------------|-----|
| `skills/test/SKILL.md` | `~/Library/Logs/Unity/Editor.log` | Use `qq_get_editor_log_path` output or platform-conditional language |
| `skills/claude-plan-review/SKILL.md` | `/tmp/claude-codex-review-gate-$PPID` | Replace with `$QQ_TEMP_DIR/claude-codex-review-gate-$PPID` |
| `skills/codex-code-review/SKILL.md` | `/tmp/claude-codex-review-gate-$PPID` | Same |
| `skills/claude-code-review/SKILL.md` | `/tmp/claude-codex-review-gate-$PPID` | Same |
| `skills/codex-plan-review/SKILL.md` | `/tmp/claude-codex-review-gate-$PPID` | Same |
| `skills/self-review/SKILL.md` | `/tmp/claude-skill-modified-marker-$PPID` | Same |

**Approach:** Replace literal `/tmp` with `$TMPDIR` (which Git Bash and macOS both set) or instruct Claude to use `$QQ_TEMP_DIR` by referencing the detect.sh output. Alternatively, skill prompts can instruct Claude to call `qq_get_temp_file` when constructing paths.

## 5. Hook Compatibility on Windows

### Problem

`hooks.json` commands like `bash scripts/hooks/codex-review-gate-check.sh` may fail if Claude Code on Windows uses `cmd.exe` or PowerShell.

### Solution: Two-layer approach

**Layer 1:** Unified dispatcher entry point.

```json
{ "command": "bash scripts/hooks/hook-dispatch.sh codex-review-gate-check" }
```

Works if Claude Code can invoke `bash` (Git Bash on PATH).

**Layer 2:** `hook-dispatch.cmd` fallback for Windows.

```cmd
@echo off
where git >nul 2>nul && (
  for /f "delims=" %%i in ('where git') do set "GIT_DIR=%%~dpi.."
)
"%GIT_DIR%\bin\bash.exe" "%~dp0hook-dispatch.sh" %*
```

**hooks.json strategy:** If `hooks.json` supports `command_windows`, use it. Otherwise, document that Git Bash must be on PATH.

## 6. `install.sh` Changes

Remove the Darwin gatekeeper. Add platform-aware dependency checking:

```bash
case "$(uname -s)" in
  Darwin*)              QQ_PLATFORM="macos" ;;
  MINGW*|MSYS*|CYGWIN*) QQ_PLATFORM="windows" ;;
  *)                    echo "Error: unsupported platform ($(uname -s))"; exit 1 ;;
esac

MISSING=""
for cmd in curl python3 jq; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING="$MISSING $cmd"
done

if [[ -n "$MISSING" ]]; then
  if [[ "$QQ_PLATFORM" == "macos" ]]; then
    echo "Install with: brew install$MISSING"
  else
    echo "Install with: winget install$MISSING"
    echo "Or ensure Git for Windows is installed (provides bash, curl)"
  fi
  exit 1
fi
```

Additional `install.sh` changes:
- Copy `scripts/platform/*.sh` into the target project (new directory)
- Copy `scripts/hooks/hook-dispatch.cmd` alongside the hook scripts
- Copy new extracted hook scripts (`skill-modified-track.sh`, `session-cleanup.sh`)

## 7. C# Fix (`CompileWatcher.cs`)

Replace hardcoded macOS log path with Unity's cross-platform API:

```csharp
// Before:
var logPath = Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
    "Library/Logs/Unity/Editor.log");

// After:
var logPath = Application.consoleLogPath;
```

`Application.consoleLogPath` returns the correct path on macOS, Windows, and Linux.

## 8. Files Changed Summary

| File | Change Type |
|------|-------------|
| **New files** | |
| `scripts/platform/detect.sh` | **New** — platform detection + variable export |
| `scripts/platform/macos.sh` | **New** — macOS platform helper functions |
| `scripts/platform/windows.sh` | **New** — Windows platform helper functions |
| `scripts/hooks/hook-dispatch.sh` | **New** — unified hook entry point |
| `scripts/hooks/hook-dispatch.cmd` | **New** — Windows fallback for hook dispatch |
| `scripts/hooks/skill-modified-track.sh` | **New** — extracted from hooks.json inline command |
| `scripts/hooks/session-cleanup.sh` | **New** — extracted from hooks.json inline command |
| **Modified scripts** | |
| `scripts/unity-common.sh` | **Modified** — source detect.sh, replace inline platform code with qq_* calls |
| `scripts/unity-check.sh` | **Modified** — osascript → qq_activate_unity_window |
| `scripts/unity-compile.sh` | **Modified** — /tmp → $QQ_TEMP_DIR |
| `scripts/unity-compile-smart.sh` | **Modified** — minor comment updates |
| `scripts/unity-test.sh` | **Modified** — /tmp → $QQ_TEMP_DIR, log path → qq_get_editor_log_path |
| `scripts/unity-unit-test.sh` | **Modified** — /tmp → $QQ_TEMP_DIR if applicable |
| `scripts/code-review.sh` | **Modified** — mktemp /tmp → $QQ_TEMP_DIR |
| **Modified hooks** | |
| `scripts/hooks/codex-review-gate-check.sh` | **Modified** — /tmp → $QQ_TEMP_DIR |
| `scripts/hooks/codex-review-gate-set.sh` | **Modified** — /tmp → $QQ_TEMP_DIR |
| `scripts/hooks/codex-review-gate-count.sh` | **Modified** — /tmp → $QQ_TEMP_DIR |
| `scripts/hooks/pre-push-test.sh` | **Modified** — /tmp → $QQ_TEMP_DIR |
| `scripts/check-skill-review.sh` | **Modified** — /tmp → $QQ_TEMP_DIR if applicable |
| `scripts/githooks/pre-push` | **Modified** — log path → qq_get_editor_log_path |
| `hooks/hooks.json` | **Modified** — extract inline commands to scripts, update hook commands |
| **Modified skills** | |
| `skills/test/SKILL.md` | **Modified** — ~/Library/Logs path → cross-platform |
| `skills/claude-plan-review/SKILL.md` | **Modified** — /tmp → $QQ_TEMP_DIR |
| `skills/codex-code-review/SKILL.md` | **Modified** — /tmp → $QQ_TEMP_DIR |
| `skills/claude-code-review/SKILL.md` | **Modified** — /tmp → $QQ_TEMP_DIR |
| `skills/codex-plan-review/SKILL.md` | **Modified** — /tmp → $QQ_TEMP_DIR |
| `skills/self-review/SKILL.md` | **Modified** — /tmp → $QQ_TEMP_DIR |
| **Other** | |
| `install.sh` | **Modified** — remove Darwin gate, add platform-aware logic, copy platform/ dir |
| `test.sh` | **Modified** — update assertion that checks for Darwin gatekeeper in install.sh |
| `packages/com.tyk.tykit/Editor/CompileWatcher.cs` | **Modified** — Application.consoleLogPath |

## 9. Testing Strategy

- **macOS:** All existing behavior must remain unchanged (regression test via `./test.sh`)
- **`test.sh` update:** The self-test currently asserts `grep -q 'uname.*Darwin' install.sh` — this will break when the Darwin gatekeeper is replaced. Update to check for the new `case "$(uname -s)"` platform detection pattern instead.
- **Windows (Git Bash):** Run `install.sh` against a Unity project, verify compile/test workflows
- **Unit tests for platform detection:** `detect.sh` returns correct platform on each OS
- **Hook dispatch:** Verify `.cmd` fallback finds Git Bash and forwards correctly
- **Skill paths:** Verify skills reference correct temp paths on both platforms
