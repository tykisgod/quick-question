# Windows Support Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add full Windows support to quick-question so all scripts, hooks, install, and tykit C# work on both macOS and Windows (via Git Bash).

**Architecture:** Hybrid approach — existing `.sh` scripts become cross-platform by sourcing a platform detection layer. Platform-specific logic (Unity paths, process detection, window focus, log paths) is extracted into `scripts/platform/macos.sh` and `scripts/platform/windows.sh` with identical function signatures. A hook dispatcher handles Windows shell compatibility.

**Tech Stack:** Bash (Git Bash on Windows), PowerShell (for Windows-specific operations), C# (Unity)

**Spec:** `docs/superpowers/specs/2026-03-29-windows-support-design.md`

---

### Task 1: Create Platform Detection Layer

**Files:**
- Create: `scripts/platform/detect.sh`
- Create: `scripts/platform/macos.sh`
- Create: `scripts/platform/windows.sh`

- [ ] **Step 1: Create `scripts/platform/detect.sh`**

```bash
#!/usr/bin/env bash
# detect.sh — Platform detection and routing
# Sources the correct platform helper (macos.sh / windows.sh)
# Exports: QQ_PLATFORM, QQ_TEMP_DIR

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

_QQ_PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_QQ_PLATFORM_DIR/${QQ_PLATFORM}.sh" ]]; then
  source "$_QQ_PLATFORM_DIR/${QQ_PLATFORM}.sh"
else
  # Graceful degradation: define stubs that warn and fail
  for _fn in qq_find_unity_binary qq_is_unity_running qq_is_file_locked \
             qq_get_file_mtime qq_activate_unity_window qq_get_editor_log_path; do
    eval "$_fn() { echo \"[qq] WARNING: $_fn not implemented for $QQ_PLATFORM\" >&2; return 1; }"
  done
fi
```

- [ ] **Step 2: Create `scripts/platform/macos.sh`**

This extracts all macOS-specific logic from `unity-common.sh` and `unity-check.sh` into platform helper functions:

```bash
#!/usr/bin/env bash
# macos.sh — macOS platform helpers

qq_find_unity_binary() {
    local project_dir="${1:-$PROJECT_DIR}"

    # 1. Environment variable
    if [ -n "${UNITY_PATH:-}" ] && [ -f "$UNITY_PATH" ]; then
        echo "$UNITY_PATH"; return
    fi

    # 2. Direct installation
    local direct="/Applications/Unity/Unity.app/Contents/MacOS/Unity"
    if [ -f "$direct" ]; then
        echo "$direct"; return
    fi

    # 3. Unity Hub (by version)
    local hub_base="/Applications/Unity/Hub/Editor"
    if [ -d "$hub_base" ]; then
        local project_version=""
        local version_file="$project_dir/ProjectSettings/ProjectVersion.txt"
        if [ -f "$version_file" ]; then
            project_version=$(grep "m_EditorVersion:" "$version_file" | sed 's/.*: //')
        fi
        if [ -n "$project_version" ] && [ -f "$hub_base/$project_version/Unity.app/Contents/MacOS/Unity" ]; then
            echo "$hub_base/$project_version/Unity.app/Contents/MacOS/Unity"; return
        fi
        local latest
        latest=$(ls -1 "$hub_base" 2>/dev/null | sort -V | tail -1)
        if [ -n "$latest" ] && [ -f "$hub_base/$latest/Unity.app/Contents/MacOS/Unity" ]; then
            echo "$hub_base/$latest/Unity.app/Contents/MacOS/Unity"; return
        fi
    fi
    echo ""
}

qq_is_unity_running() {
    local project_dir="${1:-$PROJECT_DIR}"
    local lock_file="$project_dir/Temp/UnityLockfile"

    # 1) Lock file held by a process
    if [ -f "$lock_file" ] && command -v lsof >/dev/null 2>&1; then
        if lsof "$lock_file" >/dev/null 2>&1; then
            return 0
        fi
    fi

    # 2) Process args contain projectPath
    if command -v pgrep >/dev/null 2>&1; then
        if pgrep -af "/Unity.app/Contents/MacOS/Unity" | grep -F -- "-projectPath $project_dir" >/dev/null 2>&1; then
            return 0
        fi
    fi

    # 3) Weak signal: lock file + recent compile_status + Unity process exists
    local status_file="$project_dir/Temp/compile_status.json"
    if [ -f "$lock_file" ] && [ -f "$status_file" ] && command -v pgrep >/dev/null 2>&1; then
        if pgrep -af "/Unity.app/Contents/MacOS/Unity" >/dev/null 2>&1; then
            local now mtime age
            now="$(date +%s)"
            mtime="$(qq_get_file_mtime "$status_file")"
            age=$((now - mtime))
            if [ "$age" -le 300 ]; then
                return 0
            fi
        fi
    fi
    return 1
}

qq_is_file_locked() {
    local file="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof "$file" >/dev/null 2>&1
        return $?
    fi
    return 1
}

qq_get_file_mtime() {
    stat -f %m "$1" 2>/dev/null || echo 0
}

qq_activate_unity_window() {
    osascript -e '
        tell application "System Events"
            set frontApp to name of first application process whose frontmost is true
        end tell
        tell application "Unity" to activate
        delay 0.5
        tell application frontApp to activate
    ' 2>/dev/null || true
}

qq_get_editor_log_path() {
    echo "$HOME/Library/Logs/Unity/Editor.log"
}
```

- [ ] **Step 3: Create `scripts/platform/windows.sh`**

```bash
#!/usr/bin/env bash
# windows.sh — Windows platform helpers (runs in Git Bash)

qq_find_unity_binary() {
    local project_dir="${1:-$PROJECT_DIR}"

    # 1. Environment variable
    if [ -n "${UNITY_PATH:-}" ] && [ -f "$UNITY_PATH" ]; then
        echo "$UNITY_PATH"; return
    fi

    # 2. Unity Hub (standard path)
    local hub_base="/c/Program Files/Unity/Hub/Editor"
    if [ -d "$hub_base" ]; then
        local project_version=""
        local version_file="$project_dir/ProjectSettings/ProjectVersion.txt"
        if [ -f "$version_file" ]; then
            project_version=$(grep "m_EditorVersion:" "$version_file" | sed 's/.*: //')
        fi
        if [ -n "$project_version" ] && [ -f "$hub_base/$project_version/Editor/Unity.exe" ]; then
            echo "$hub_base/$project_version/Editor/Unity.exe"; return
        fi
        local latest
        latest=$(ls -1 "$hub_base" 2>/dev/null | sort -V | tail -1)
        if [ -n "$latest" ] && [ -f "$hub_base/$latest/Editor/Unity.exe" ]; then
            echo "$hub_base/$latest/Editor/Unity.exe"; return
        fi
    fi

    # 3. Check PATH
    if command -v Unity.exe >/dev/null 2>&1; then
        command -v Unity.exe; return
    fi

    echo ""
}

qq_is_unity_running() {
    local project_dir="${1:-$PROJECT_DIR}"
    local lock_file="$project_dir/Temp/UnityLockfile"

    # 1) Lock file exists + Unity.exe is running
    if [ -f "$lock_file" ]; then
        if tasklist.exe //FI "IMAGENAME eq Unity.exe" 2>/dev/null | grep -qi "Unity.exe"; then
            # Check if this Unity is for our project
            if wmic.exe process where "name='Unity.exe'" get CommandLine 2>/dev/null | grep -qF "$project_dir"; then
                return 0
            fi
            # Fallback: lock file exists + some Unity is running
            local status_file="$project_dir/Temp/compile_status.json"
            if [ -f "$status_file" ]; then
                local now mtime age
                now="$(date +%s)"
                mtime="$(qq_get_file_mtime "$status_file")"
                age=$((now - mtime))
                if [ "$age" -le 300 ]; then
                    return 0
                fi
            fi
        fi
    fi
    return 1
}

qq_is_file_locked() {
    local file="$1"
    powershell.exe -NoProfile -Command "
        try { \$s = [IO.File]::Open('$file','Open','ReadWrite','None'); \$s.Close(); exit 1 }
        catch { exit 0 }
    " 2>/dev/null
    return $?
}

qq_get_file_mtime() {
    # Git Bash ships GNU stat
    stat -c %Y "$1" 2>/dev/null || echo 0
}

qq_activate_unity_window() {
    powershell.exe -NoProfile -Command "
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WinFocus {
    [DllImport(\"user32.dll\")] public static extern IntPtr GetForegroundWindow();
    [DllImport(\"user32.dll\")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport(\"user32.dll\")] public static extern IntPtr FindWindow(string cls, string title);
}
'@
        \$prev = [WinFocus]::GetForegroundWindow()
        \$unity = Get-Process Unity -ErrorAction SilentlyContinue | Select-Object -First 1
        if (\$unity) {
            [WinFocus]::SetForegroundWindow(\$unity.MainWindowHandle) | Out-Null
            Start-Sleep -Milliseconds 500
            [WinFocus]::SetForegroundWindow(\$prev) | Out-Null
        }
    " 2>/dev/null || true
}

qq_get_editor_log_path() {
    echo "$LOCALAPPDATA/Unity/Editor/Editor.log"
}
```

- [ ] **Step 4: Make all three files executable**

Run: `chmod +x scripts/platform/detect.sh scripts/platform/macos.sh scripts/platform/windows.sh`

- [ ] **Step 5: Commit**

```bash
git add scripts/platform/detect.sh scripts/platform/macos.sh scripts/platform/windows.sh
git commit -m "feat: add platform detection layer for Windows support"
```

---

### Task 2: Refactor `unity-common.sh` to Use Platform Helpers

**Files:**
- Modify: `scripts/unity-common.sh`

- [ ] **Step 1: Rewrite `unity-common.sh`**

Replace the entire file with the following. The `find_unity` and `is_editor_open_for_project` functions now delegate to `qq_*` helpers. `find_unity_eval` and `get_eval_port` are already cross-platform and stay as-is.

```bash
#!/usr/bin/env bash
# unity-common.sh — Unity 脚本公共函数
# 被 unity-compile-smart.sh, unity-check.sh, unity-test.sh, unity-compile.sh 共享
#
# 使用方式: source "$(dirname "$0")/unity-common.sh"
# 前提: 调用方必须先设置 PROJECT_DIR 变量

# ── 加载平台检测层 ──
source "$(dirname "${BASH_SOURCE[0]}")/platform/detect.sh"

# ── 检测 Unity Editor 是否为当前项目打开 ──
is_editor_open_for_project() {
    qq_is_unity_running "$PROJECT_DIR"
}

# ── 查找 Unity Editor 可执行文件路径 ──
find_unity() {
    qq_find_unity_binary "$PROJECT_DIR"
}

# ── 查找 tykit 的 unity-eval.sh（兼容 PackageCache 和嵌入包） ──
find_unity_eval() {
    # 优先搜嵌入包
    local embedded="$PROJECT_DIR/Packages/com.tyk.tykit/Scripts~/unity-eval.sh"
    if [ -f "$embedded" ]; then
        echo "$embedded"
        return
    fi

    # 回退搜 PackageCache
    find "$PROJECT_DIR/Library/PackageCache" -name "unity-eval.sh" -path "*/com.tyk.tykit*" 2>/dev/null | head -1
}

# ── 获取 tykit 端口 ──
get_eval_port() {
    local json_file="$PROJECT_DIR/Temp/eval_server.json"
    if [ -f "$json_file" ]; then
        python3 -c "import json; print(json.load(open('$json_file'))['port'])" 2>/dev/null
    fi
}
```

- [ ] **Step 2: Verify no syntax errors**

Run: `bash -n scripts/unity-common.sh`
Expected: no output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add scripts/unity-common.sh
git commit -m "refactor: delegate platform-specific logic in unity-common.sh to qq_* helpers"
```

---

### Task 3: Update `unity-check.sh` — Replace osascript

**Files:**
- Modify: `scripts/unity-check.sh:167-174`

- [ ] **Step 1: Replace osascript block**

The platform layer is already available via `unity-common.sh` (sourced at line 43), which loads `platform/detect.sh`. No extra source needed.

Replace lines 165-174 (the osascript block):
```bash
    # 短暂激活 Unity 窗口触发 Auto Refresh，然后切回原窗口
    echo -e "${CYAN}Triggering Unity refresh...${NC}"
    osascript -e '
        tell application "System Events"
            set frontApp to name of first application process whose frontmost is true
        end tell
        tell application "Unity" to activate
        delay 0.5
        tell application frontApp to activate
    ' 2>/dev/null || true
```

With:
```bash
    # 短暂激活 Unity 窗口触发 Auto Refresh，然后切回原窗口
    echo -e "${CYAN}Triggering Unity refresh...${NC}"
    qq_activate_unity_window
```

- [ ] **Step 2: Verify no syntax errors**

Run: `bash -n scripts/unity-check.sh`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add scripts/unity-check.sh
git commit -m "refactor: replace osascript with qq_activate_unity_window in unity-check.sh"
```

---

### Task 3b: Update `unity-compile-smart.sh` — Comment Updates

**Files:**
- Modify: `scripts/unity-compile-smart.sh:104,114`

- [ ] **Step 1: Update comments referencing osascript**

Line 104: Replace `# 优先尝试 tykit（不抢焦点、不依赖 osascript）` with `# 优先尝试 tykit（不抢焦点、最快路径）`

Line 114: Replace `# tykit 不可用或状态未知，回退到 unity-check（osascript 触发）` with `# tykit 不可用或状态未知，回退到 unity-check（窗口激活触发）`

- [ ] **Step 2: Commit**

```bash
git add scripts/unity-compile-smart.sh
git commit -m "docs: update osascript references in unity-compile-smart.sh comments"
```

---

### Task 4: Update `unity-compile.sh` — Replace /tmp

**Files:**
- Modify: `scripts/unity-compile.sh:26`

- [ ] **Step 1: Add platform detection source**

After line 24 (`source "$(dirname "$0")/unity-common.sh"`), the platform layer is already loaded (unity-common.sh sources detect.sh). No extra source needed.

Replace line 26:
```bash
LOG_FILE="/tmp/unity-compile-$(date +%s).log"
```
With:
```bash
LOG_FILE="$QQ_TEMP_DIR/unity-compile-$(date +%s).log"
```

- [ ] **Step 2: Verify no syntax errors**

Run: `bash -n scripts/unity-compile.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/unity-compile.sh
git commit -m "fix: use cross-platform temp dir in unity-compile.sh"
```

---

### Task 5: Update `unity-test.sh` — Replace /tmp and Log Path

**Files:**
- Modify: `scripts/unity-test.sh:228-229` (batch test temp files)
- Modify: any `~/Library/Logs/Unity/Editor.log` references

- [ ] **Step 1: Replace /tmp paths**

The platform layer is already sourced via `unity-common.sh` (line 29). Replace all `/tmp/unity-test-` occurrences:

```bash
# Before (lines 228-229):
local results_file="/tmp/unity-test-${platform}-$(date +%s).xml"
local log_file="/tmp/unity-test-${platform}-$(date +%s).log"

# After:
local results_file="$QQ_TEMP_DIR/unity-test-${platform}-$(date +%s).xml"
local log_file="$QQ_TEMP_DIR/unity-test-${platform}-$(date +%s).log"
```

- [ ] **Step 2: Replace any Editor.log hardcoded paths**

Search for `Library/Logs/Unity/Editor.log` in the file. If found, replace with `$(qq_get_editor_log_path)`.

- [ ] **Step 3: Verify no syntax errors**

Run: `bash -n scripts/unity-test.sh`

- [ ] **Step 4: Commit**

```bash
git add scripts/unity-test.sh
git commit -m "fix: use cross-platform temp dir and log path in unity-test.sh"
```

---

### Task 6: Update `code-review.sh` — Replace /tmp in mktemp

**Files:**
- Modify: `scripts/code-review.sh:73`

- [ ] **Step 1: Source platform detection at the top**

After `set -euo pipefail` (line 15), add:
```bash
source "$(dirname "$0")/platform/detect.sh"
```

- [ ] **Step 2: Replace mktemp path**

Replace line 73:
```bash
DIFF_FILE=$(mktemp /tmp/code-review-diff-XXXXXXXX)
```
With:
```bash
DIFF_FILE=$(mktemp "$QQ_TEMP_DIR/code-review-diff-XXXXXXXX")
```

- [ ] **Step 3: Commit**

```bash
git add scripts/code-review.sh
git commit -m "fix: use cross-platform temp dir in code-review.sh"
```

---

### Task 7: Update Hook Scripts — Replace /tmp

**Files:**
- Modify: `scripts/hooks/codex-review-gate-check.sh:5`
- Modify: `scripts/hooks/codex-review-gate-set.sh:9`
- Modify: `scripts/hooks/codex-review-gate-count.sh:5`
- Modify: `scripts/check-skill-review.sh:9`

- [ ] **Step 1: Update `codex-review-gate-check.sh`**

Add platform detection at line 4 (after the comment header):
```bash
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
```

Replace line 5:
```bash
GATE_FILE="/tmp/claude-codex-review-gate-$PPID"
```
With:
```bash
GATE_FILE="$QQ_TEMP_DIR/claude-codex-review-gate-$PPID"
```

- [ ] **Step 2: Update `codex-review-gate-set.sh`**

Add platform detection at line 4:
```bash
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
```

Replace line 9:
```bash
  echo "$(date +%s):0" > "/tmp/claude-codex-review-gate-$PPID"
```
With:
```bash
  echo "$(date +%s):0" > "$QQ_TEMP_DIR/claude-codex-review-gate-$PPID"
```

- [ ] **Step 3: Update `codex-review-gate-count.sh`**

Add platform detection at line 4:
```bash
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
```

Replace line 5:
```bash
GATE_FILE="/tmp/claude-codex-review-gate-$PPID"
```
With:
```bash
GATE_FILE="$QQ_TEMP_DIR/claude-codex-review-gate-$PPID"
```

- [ ] **Step 4: Update `check-skill-review.sh`**

Add platform detection after line 8 (comment header):
```bash
source "$(cd "$(dirname "$0")" && pwd)/platform/detect.sh"
```

Replace line 9:
```bash
MARKER="/tmp/claude-skill-modified-marker-$PPID"
```
With:
```bash
MARKER="$QQ_TEMP_DIR/claude-skill-modified-marker-$PPID"
```

- [ ] **Step 5: Verify all hook scripts parse cleanly**

Run:
```bash
bash -n scripts/hooks/codex-review-gate-check.sh
bash -n scripts/hooks/codex-review-gate-set.sh
bash -n scripts/hooks/codex-review-gate-count.sh
bash -n scripts/check-skill-review.sh
```

- [ ] **Step 6: Commit**

```bash
git add scripts/hooks/codex-review-gate-check.sh scripts/hooks/codex-review-gate-set.sh \
       scripts/hooks/codex-review-gate-count.sh scripts/check-skill-review.sh
git commit -m "fix: use cross-platform temp dir in all hook scripts"
```

---

### Task 8: Extract hooks.json Inline Commands to Scripts

**Files:**
- Create: `scripts/hooks/skill-modified-track.sh`
- Create: `scripts/hooks/session-cleanup.sh`
- Modify: `hooks/hooks.json:28,64`

- [ ] **Step 1: Create `scripts/hooks/skill-modified-track.sh`**

```bash
#!/usr/bin/env bash
# PostToolUse hook (Write|Edit): track skill file modifications
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"

jq -r '.tool_input.file_path' | {
  read -r f
  [[ $f == */.claude/commands/*.md || $f == */skills/*/SKILL.md ]] && {
    echo "$f" >> "$QQ_TEMP_DIR/claude-skill-modified-marker-$PPID"
    echo '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[skill-modified] Skill file change recorded. Will check for /qq:self-review before ending."}}'
  } || true
}
```

- [ ] **Step 2: Create `scripts/hooks/session-cleanup.sh`**

```bash
#!/usr/bin/env bash
# Stop hook: clean up session temp files
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"

rm -f "$QQ_TEMP_DIR/claude-codex-review-gate-$PPID"
```

- [ ] **Step 3: Make executable**

Run: `chmod +x scripts/hooks/skill-modified-track.sh scripts/hooks/session-cleanup.sh`

- [ ] **Step 4: Update `hooks/hooks.json`**

Replace the inline skill-tracking command (line 28) with:
```json
          {
            "type": "command",
            "command": "$(git rev-parse --show-toplevel)/scripts/hooks/skill-modified-track.sh"
          }
```

Replace the inline cleanup command (line 64) with:
```json
          {
            "type": "command",
            "command": "$(git rev-parse --show-toplevel)/scripts/hooks/session-cleanup.sh",
            "timeout": 2
          }
```

The full updated `hooks.json`:
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "$(git rev-parse --show-toplevel)/scripts/hooks/codex-review-gate-check.sh",
            "timeout": 5,
            "statusMessage": "Checking Codex Review Gate..."
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "jq -r '.tool_input.file_path' | { read -r f; [[ $f == *.cs ]] && $(git rev-parse --show-toplevel)/scripts/unity-compile-smart.sh --timeout 15 || true; }",
            "timeout": 120,
            "statusMessage": "Compiling Unity..."
          },
          {
            "type": "command",
            "command": "$(git rev-parse --show-toplevel)/scripts/hooks/skill-modified-track.sh"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$(git rev-parse --show-toplevel)/scripts/hooks/codex-review-gate-set.sh",
            "timeout": 5
          }
        ]
      },
      {
        "matcher": "Agent",
        "hooks": [
          {
            "type": "command",
            "command": "$(git rev-parse --show-toplevel)/scripts/hooks/codex-review-gate-count.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$(git rev-parse --show-toplevel)/scripts/check-skill-review.sh",
            "timeout": 5
          },
          {
            "type": "command",
            "command": "$(git rev-parse --show-toplevel)/scripts/hooks/session-cleanup.sh",
            "timeout": 2
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 5: Validate JSON**

Run: `python3 -m json.tool hooks/hooks.json > /dev/null`

- [ ] **Step 6: Commit**

```bash
git add scripts/hooks/skill-modified-track.sh scripts/hooks/session-cleanup.sh hooks/hooks.json
git commit -m "refactor: extract hooks.json inline commands to scripts for cross-platform support"
```

---

### Task 9: Create Hook Dispatch Layer for Windows

**Files:**
- Create: `scripts/hooks/hook-dispatch.sh`
- Create: `scripts/hooks/hook-dispatch.cmd`

- [ ] **Step 1: Create `scripts/hooks/hook-dispatch.sh`**

```bash
#!/usr/bin/env bash
# hook-dispatch.sh — Unified hook entry point
# Usage: bash scripts/hooks/hook-dispatch.sh <hook-name>
# Finds and runs the named hook script in the same directory

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_NAME="$1"
shift

if [ -z "$HOOK_NAME" ]; then
  echo "Usage: hook-dispatch.sh <hook-name>" >&2
  exit 1
fi

HOOK_SCRIPT="$HOOK_DIR/${HOOK_NAME}.sh"
if [ ! -f "$HOOK_SCRIPT" ]; then
  echo "Hook script not found: $HOOK_SCRIPT" >&2
  exit 1
fi

exec bash "$HOOK_SCRIPT" "$@"
```

- [ ] **Step 2: Create `scripts/hooks/hook-dispatch.cmd`**

```cmd
@echo off
REM hook-dispatch.cmd — Windows fallback: finds Git Bash and forwards to hook-dispatch.sh
REM Usage: hook-dispatch.cmd <hook-name> [args...]

setlocal

REM Try bash on PATH first (Git Bash installed with PATH option)
where bash >nul 2>nul
if %ERRORLEVEL% equ 0 (
    bash "%~dp0hook-dispatch.sh" %*
    exit /b %ERRORLEVEL%
)

REM Try to find Git Bash via git location
where git >nul 2>nul
if %ERRORLEVEL% equ 0 (
    for /f "delims=" %%i in ('where git') do set "GIT_EXE=%%i"
    for %%i in ("%GIT_EXE%") do set "GIT_DIR=%%~dpi.."
    "%GIT_DIR%\bin\bash.exe" "%~dp0hook-dispatch.sh" %*
    exit /b %ERRORLEVEL%
)

echo ERROR: Git Bash not found. Install Git for Windows. >&2
exit /b 1
```

- [ ] **Step 3: Make executable**

Run: `chmod +x scripts/hooks/hook-dispatch.sh`

- [ ] **Step 4: Commit**

```bash
git add scripts/hooks/hook-dispatch.sh scripts/hooks/hook-dispatch.cmd
git commit -m "feat: add hook dispatch layer for Windows compatibility"
```

---

### Task 10: Update `scripts/githooks/pre-push`

**Files:**
- Modify: `scripts/githooks/pre-push:15`

- [ ] **Step 1: Source platform detection and replace hardcoded log path**

After line 13 (`NC='\033[0m'`), add (reusing the existing `$SCRIPT_DIR` variable from line 7):
```bash
source "$SCRIPT_DIR/scripts/platform/detect.sh"
```

Replace line 15:
```bash
EDITOR_LOG="$HOME/Library/Logs/Unity/Editor.log"
```
With:
```bash
EDITOR_LOG="$(qq_get_editor_log_path)"
```

- [ ] **Step 2: Verify no syntax errors**

Run: `bash -n scripts/githooks/pre-push`

- [ ] **Step 3: Commit**

```bash
git add scripts/githooks/pre-push
git commit -m "fix: use cross-platform editor log path in pre-push hook"
```

---

### Task 11: Update `install.sh`

**Files:**
- Modify: `install.sh:16-31,48-53`

- [ ] **Step 1: Replace platform check (lines 16-20)**

Replace:
```bash
# ── Platform check ──
if [[ "$(uname)" != "Darwin" ]]; then
  echo "Error: quick-question v1 only supports macOS. Windows/Linux support planned for v2."
  exit 1
fi
```
With:
```bash
# ── Platform check ──
case "$(uname -s)" in
  Darwin*)              QQ_PLATFORM="macos" ;;
  MINGW*|MSYS*|CYGWIN*) QQ_PLATFORM="windows" ;;
  *)
    echo "Error: unsupported platform ($(uname -s)). quick-question supports macOS and Windows."
    exit 1
    ;;
esac
```

- [ ] **Step 2: Replace dependency check (lines 22-31)**

Replace:
```bash
# ── Dependency check ──
MISSING=""
command -v curl  &>/dev/null || MISSING="$MISSING curl"
command -v python3 &>/dev/null || MISSING="$MISSING python3"
command -v jq   &>/dev/null || MISSING="$MISSING jq"
if [ -n "$MISSING" ]; then
  echo "Error: missing required tools:$MISSING"
  echo "Install with: brew install$MISSING"
  exit 1
fi
```
With:
```bash
# ── Dependency check ──
MISSING=""
command -v curl  &>/dev/null || MISSING="$MISSING curl"
command -v python3 &>/dev/null || MISSING="$MISSING python3"
command -v jq   &>/dev/null || MISSING="$MISSING jq"
if [ -n "$MISSING" ]; then
  echo "Error: missing required tools:$MISSING"
  if [[ "$QQ_PLATFORM" == "macos" ]]; then
    echo "Install with: brew install$MISSING"
  else
    echo "Install with: winget install$MISSING"
    echo "Or ensure Git for Windows is installed (provides bash, curl)"
  fi
  exit 1
fi
```

- [ ] **Step 3: Add platform directory copy (after line 50)**

After the existing script copy lines, add the platform directory copy:

```bash
mkdir -p "$TARGET/scripts/platform"
cp "$SCRIPT_DIR"/scripts/platform/*.sh "$TARGET/scripts/platform/"
chmod +x "$TARGET/scripts/platform/"*.sh
```

And add the `.cmd` copy for Windows hook dispatch:

```bash
# Copy Windows hook dispatch wrapper
cp "$SCRIPT_DIR"/scripts/hooks/hook-dispatch.cmd "$TARGET/scripts/hooks/" 2>/dev/null || true
cp "$SCRIPT_DIR"/scripts/hooks/hook-dispatch.sh "$TARGET/scripts/hooks/" 2>/dev/null || true
```

- [ ] **Step 4: Verify no syntax errors**

Run: `bash -n install.sh`

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -m "feat: make install.sh cross-platform (macOS + Windows)"
```

---

### Task 12: Update `test.sh`

**Files:**
- Modify: `test.sh:155-158`

- [ ] **Step 1: Update platform check assertion**

Replace lines 154-158:
```bash
# Check platform guard exists
if grep -q 'uname.*Darwin' "$SCRIPT_DIR/install.sh"; then
  pass "install.sh has macOS platform check"
else
  fail "install.sh missing platform check"
fi
```
With:
```bash
# Check platform guard exists (cross-platform case statement)
if grep -q 'uname -s' "$SCRIPT_DIR/install.sh"; then
  pass "install.sh has platform check"
else
  fail "install.sh missing platform check"
fi
```

- [ ] **Step 2: Add platform directory check to structural checks (section 3)**

After the hook scripts existence check (around line 73), add:
```bash
# Platform helper scripts exist
for pf in detect.sh macos.sh windows.sh; do
  if [ -f "$SCRIPT_DIR/scripts/platform/$pf" ]; then
    pass "scripts/platform/$pf exists"
  else
    fail "scripts/platform/$pf NOT FOUND"
  fi
done
```

- [ ] **Step 3: Verify test.sh still passes**

Run: `./test.sh`
Expected: All checks pass

- [ ] **Step 4: Commit**

```bash
git add test.sh
git commit -m "fix: update test.sh assertions for cross-platform install.sh"
```

---

### Task 13: Fix `CompileWatcher.cs`

**Files:**
- Modify: `packages/com.tyk.tykit/Editor/CompileWatcher.cs:101-103`

- [ ] **Step 1: Replace hardcoded log path**

Replace lines 101-103:
```csharp
            var logPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "Library/Logs/Unity/Editor.log");
```
With:
```csharp
            var logPath = UnityEngine.Application.consoleLogPath;
```

- [ ] **Step 2: Remove unused `using` if `Environment` is no longer needed elsewhere**

Check if `System.Environment` or `System.IO.Path` are used elsewhere in the file. Only remove the `using` if nothing else references it.

- [ ] **Step 3: Commit**

```bash
git add packages/com.tyk.tykit/Editor/CompileWatcher.cs
git commit -m "fix: use Application.consoleLogPath for cross-platform editor log"
```

---

### Task 14: Update SKILL.md Files

**Files:**
- Modify: `skills/test/SKILL.md`
- Modify: `skills/claude-plan-review/SKILL.md`
- Modify: `skills/codex-code-review/SKILL.md`
- Modify: `skills/claude-code-review/SKILL.md`
- Modify: `skills/codex-plan-review/SKILL.md`
- Modify: `skills/self-review/SKILL.md`

- [ ] **Step 1: Update `skills/test/SKILL.md`**

Replace all `~/Library/Logs/Unity/Editor.log` references with a cross-platform approach. In the step 1 code block, replace:
```bash
BASELINE=$(wc -l < ~/Library/Logs/Unity/Editor.log)
```
With:
```bash
source "$(git rev-parse --show-toplevel)/scripts/platform/detect.sh"
EDITOR_LOG="$(qq_get_editor_log_path)"
BASELINE=$(wc -l < "$EDITOR_LOG")
```

In step 3, replace:
```bash
tail -n +$((BASELINE + 1)) ~/Library/Logs/Unity/Editor.log | \
```
With:
```bash
tail -n +$((BASELINE + 1)) "$EDITOR_LOG" | \
```

- [ ] **Step 2: Update review skills — replace `/tmp/claude-codex-review-gate-$PPID`**

In each of these files, replace all occurrences of `/tmp/claude-codex-review-gate-$PPID` with `$QQ_TEMP_DIR/claude-codex-review-gate-$PPID`:

- `skills/claude-plan-review/SKILL.md`
- `skills/codex-code-review/SKILL.md`
- `skills/claude-code-review/SKILL.md`
- `skills/codex-plan-review/SKILL.md`

For the `touch` and `rm -f` commands in these files, also add a platform detection source before the path is used:
```bash
source "$(git rev-parse --show-toplevel)/scripts/platform/detect.sh"
touch "$QQ_TEMP_DIR/claude-codex-review-gate-$PPID"
```
And:
```bash
source "$(git rev-parse --show-toplevel)/scripts/platform/detect.sh"
rm -f "$QQ_TEMP_DIR/claude-codex-review-gate-$PPID"
```

- [ ] **Step 3: Update `skills/self-review/SKILL.md`**

Replace:
```bash
rm -f /tmp/claude-skill-modified-marker-$PPID
```
With:
```bash
source "$(git rev-parse --show-toplevel)/scripts/platform/detect.sh"
rm -f "$QQ_TEMP_DIR/claude-skill-modified-marker-$PPID"
```

- [ ] **Step 4: Commit**

```bash
git add skills/test/SKILL.md skills/claude-plan-review/SKILL.md \
       skills/codex-code-review/SKILL.md skills/claude-code-review/SKILL.md \
       skills/codex-plan-review/SKILL.md skills/self-review/SKILL.md
git commit -m "fix: use cross-platform temp paths in all SKILL.md files"
```

---

### Task 15: Update `pre-push-test.sh`

**Files:**
- Modify: `scripts/hooks/pre-push-test.sh`

- [ ] **Step 1: Check for /tmp usage**

Read the file. It doesn't use `/tmp` directly (it calls `test.sh`), but verify. No changes needed if no `/tmp` references exist.

- [ ] **Step 2: Commit if changed**

Only commit if changes were made.

---

### Task 16: Run Full Test Suite

- [ ] **Step 1: Run shellcheck on all scripts**

Run: `shellcheck scripts/*.sh scripts/hooks/*.sh scripts/platform/*.sh install.sh test.sh`

Fix any issues found.

- [ ] **Step 2: Run the self-test**

Run: `./test.sh`
Expected: All checks pass

- [ ] **Step 3: Validate JSON**

Run: `python3 -m json.tool hooks/hooks.json > /dev/null`
Expected: no output (valid JSON)

- [ ] **Step 4: Fix any failures and commit**

```bash
git add -A
git commit -m "fix: address shellcheck and test failures from Windows support changes"
```

---

### Task 17: Update Documentation

**Files:**
- Modify: `CLAUDE.md` (if platform notes need updating)
- Modify: `README.md` (remove "macOS only" limitation)

- [ ] **Step 1: Update README.md**

Find all "macOS only (v1)" or "仅 macOS" references and update them to indicate Windows support. For example:
- "macOS only (v1) — scripts use `osascript`, `/Applications/Unity`, `~/Library/Logs`" → "macOS + Windows — requires Git for Windows on Windows"

- [ ] **Step 2: Update CLAUDE.md if needed**

Check if CLAUDE.md mentions macOS-only. Update to reflect cross-platform support.

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: update platform support from macOS-only to macOS + Windows"
```
