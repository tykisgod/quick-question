#!/usr/bin/env bash
# PreToolUse hook (Edit|Write): 编译红灯或 virgin project 时阻止写引擎源文件
# 按 $PPID 隔离：只检查本 session 的 gate
set -euo pipefail

_qq_self="${BASH_SOURCE[0]//\\//}"; [[ "$_qq_self" == */* ]] || _qq_self="./$_qq_self"
_qq_dir="${_qq_self%/*}"; [[ "$_qq_dir" == /* || "$_qq_dir" == [A-Za-z]:/* ]] || _qq_dir="$PWD/$_qq_dir"   # 纯 bash 取目录，不 fork；Claude Code 在 Windows 上用 C:/… 调钩子，盘符路径也是绝对路径
SCRIPT_DIR="$_qq_dir/.."
source "$SCRIPT_DIR/platform/detect.sh"

# 快路径：两道检查都只针对引擎源文件；目标文件的扩展名不属于任何引擎的源文件模式
# （qq_engine.py 各引擎 sourcePatterns 的并集：cs cpp h gd gdshader gdshaderinc razor）就直接放行，
# 不起 python 读配置、解析输入、匹配模式——这串进程机器一忙就超过本钩子 5 秒的上限（2026-10-04 实测）。
# 用 bash 内建从原始输入里取 tool_input.file_path：内容里的同名文本在 JSON 里是 \"file_path\"，不会误中。
# 取不到、或值里带反斜杠转义的引号这类拿不准的情况，一律落回下面的完整判定。
if [[ -t 0 ]]; then
  _QQ_HOOK_INPUT_CACHE=""
else
  IFS= read -r -d '' _QQ_HOOK_INPUT_CACHE || true   # 内建读完 stdin，并作为 qq_hook_input 的缓存沿用
fi
if [[ "$_QQ_HOOK_INPUT_CACHE" =~ \"file_path\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
  shopt -s nocasematch   # Windows 上 python 的 fnmatch 不分大小写，这里同样不分
  case "${BASH_REMATCH[1]}" in
    *\\) ;;
    *.cs|*.cpp|*.h|*.gd|*.gdshader|*.gdshaderinc|*.razor) ;;
    *) exit 0 ;;
  esac
  shopt -u nocasematch
fi

source "$SCRIPT_DIR/qq-runtime.sh"

if [ "$(qq_hook_enabled compile_gate)" != "true" ]; then
  exit 0
fi

file_path="$(qq_hook_input tool_input.file_path)"
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
