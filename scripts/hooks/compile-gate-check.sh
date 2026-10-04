#!/usr/bin/env bash
# PreToolUse hook (Edit|Write): 编译红灯或 virgin project 时阻止写引擎源文件
# 按「会话 + 项目」隔离：只检查本会话在本项目的 gate（会话 id 见 detect.sh 的 qq_session_id，项目由 qq_compile_gate.py 哈希进文件名）
# 拦截必须 exit 2：PreToolUse 钩子退 1 只算「非阻断错误」，Claude Code 照样执行这次编辑（2026-10-04 实测）。
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
qq_hook_read_stdin   # 内建读完 stdin，并作为 qq_hook_input 的缓存沿用
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

PROJECT="$(qq_project_dir)"

# 只拦截引擎源文件
if [[ "$($QQ_PY "$SCRIPT_DIR/qq_engine.py" matches-source --project "$PROJECT" "$file_path" 2>/dev/null || printf 'false\n')" != "true" ]]; then
  exit 0
fi

# ── Check 1: virgin project（项目级事实，直接查文件系统）──
# 原来这里调的 qq_detect_engine 在 qq 里根本不存在：set -e 下退 127，Claude Code 当成非阻断错误放行，
# 这道检查（连同下面的编译门）从来没拦过。现在改调 qq_engine，但只在可能是 virgin 的时候才调：
#   - linked git worktree（.git 是文件）一律跳过：Library/ .godot/ Intermediate/ 都被 git 忽略，worktree 里本来
#     就没有，那不是「编辑器从没打开过」——拦了 agent 自己也打不开编辑器，所有源文件在这棵树里都改不了；
#   - 有引擎标记文件、却缺对应缓存目录时才需要知道引擎（每次改源文件都要跑，少起一个 python 是一个）。
ENGINE=""
if [[ ! -f "$PROJECT/.git" ]]; then
  if [[ -f "$PROJECT/ProjectSettings/ProjectVersion.txt" && ! -d "$PROJECT/Library" ]] \
     || [[ -f "$PROJECT/project.godot" && ! -d "$PROJECT/.godot" ]] \
     || { compgen -G "$PROJECT/*.uproject" >/dev/null && [[ ! -d "$PROJECT/Intermediate" ]]; }; then
    ENGINE="$(qq_engine)"
  fi
fi
case "$ENGINE" in
  unity)
    if [[ ! -d "$PROJECT/Library" ]]; then
      echo "⛔ BLOCKED: Virgin project — Library/ 不存在，Unity 从未打开过此项目。请先用 Unity Hub 打开项目并等待初始导入完成，然后再继续。" >&2
      exit 2
    fi
    ;;
  godot)
    if [[ ! -d "$PROJECT/.godot" ]]; then
      echo "⛔ BLOCKED: Virgin project — .godot/ 不存在，Godot 从未打开过此项目。请先打开 Godot Editor，然后再继续。" >&2
      exit 2
    fi
    ;;
  unreal)
    if [[ ! -d "$PROJECT/Intermediate" ]]; then
      echo "⛔ BLOCKED: Virgin project — Intermediate/ 不存在，Unreal Editor 从未打开过此项目。请先打开 Unreal Editor，然后再继续。" >&2
      exit 2
    fi
    ;;
esac

# ── Check 2: compile gate（按会话 + 项目隔离；拿不到会话 id 就不查，也不会有人替它建门）──
qq_session_id || exit 0
GATE_PREFIX="$QQ_TEMP_DIR/compile-gate-$QQ_SESSION_ID"
compgen -G "$GATE_PREFIX-*" >/dev/null || exit 0   # 本会话哪个项目都没有门：不起 python

# 门是 auto-compile.sh 在编译定性失败时立的。报错的文件、触发编译的文件、错误里点名的类型所在的文件、
# 新建文件、项目外的文件都放行（要修错误就得改它们），其余已有的源文件等编译转绿再改；1 小时自动过期。
# 判定在 qq_compile_gate.py check：放行 0、拦截 3。判定脚本自己出错（其他退出码）时放行——门坏了宁可不拦，
# 也不把整个会话的源文件锁住。
GATE_RC=0
"$QQ_PY" "$SCRIPT_DIR/qq_compile_gate.py" check --project "$PROJECT" --gate-prefix "$GATE_PREFIX" --file "$file_path" || GATE_RC=$?
if [[ "$GATE_RC" -eq 3 ]]; then
  exit 2
fi
exit 0
