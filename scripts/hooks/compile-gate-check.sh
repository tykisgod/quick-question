#!/usr/bin/env bash
# PreToolUse hook (Edit|Write): 编译红灯或 virgin project 时阻止写引擎源文件
# 按 $PPID 隔离：只检查本 session 的 gate
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/platform/detect.sh"
source "$SCRIPT_DIR/qq-runtime.sh"

if [ "$(qq_hook_enabled compile_gate)" != "true" ]; then
  exit 0
fi

file_path="$(jq -r '.tool_input.file_path // ""')"
if [[ -z "$file_path" ]]; then
  exit 0
fi

# 只拦截引擎源文件
if [[ "$($QQ_PY "$SCRIPT_DIR/qq_engine.py" matches-source --project "$(qq_project_dir)" "$file_path" 2>/dev/null || printf 'false\n')" != "true" ]]; then
  exit 0
fi

PROJECT="$(qq_project_dir)"
ENGINE="$(qq_detect_engine)"

# ── Check 1: virgin project（项目级事实，直接查文件系统）──
case "$ENGINE" in
  unity)
    if [[ ! -d "$PROJECT/Library" ]]; then
      echo "⛔ BLOCKED: Virgin project — Library/ 不存在，Unity 从未打开过此项目。请先用 Unity Hub 打开项目并等待初始导入完成，然后再继续。" >&2
      exit 1
    fi
    ;;
  godot)
    if [[ ! -d "$PROJECT/.godot" ]]; then
      echo "⛔ BLOCKED: Virgin project — .godot/ 不存在，Godot 从未打开过此项目。请先打开 Godot Editor，然后再继续。" >&2
      exit 1
    fi
    ;;
  unreal)
    if [[ ! -d "$PROJECT/Intermediate" ]]; then
      echo "⛔ BLOCKED: Virgin project — Intermediate/ 不存在，Unreal Editor 从未打开过此项目。请先打开 Unreal Editor，然后再继续。" >&2
      exit 1
    fi
    ;;
esac

# ── Check 2: compile gate（session 级，按 PPID 隔离）──
GATE_FILE="$QQ_TEMP_DIR/compile-gate-$PPID"
[[ -f "$GATE_FILE" ]] || exit 0

IFS=: read -r ts reason < "$GATE_FILE"

# 超过 1 小时自动过期
now=$(date +%s)
age=$(( now - ${ts:-0} ))
if [[ $age -gt 3600 ]]; then
  rm -f "$GATE_FILE"
  exit 0
fi

echo "⛔ BLOCKED: 上次编译失败（${reason:-unknown}）。请先修复编译错误再继续写代码。运行 qq-compile.sh --project \"$PROJECT\" 查看详情。" >&2
exit 1
