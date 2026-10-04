#!/usr/bin/env bash
# PostToolUse hook (Write|Edit): auto-compile engine source files when enabled by the active qq profile
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$SCRIPT_DIR/platform/detect.sh"
source "$SCRIPT_DIR/qq-runtime.sh"
# stdin 用 cat 一次读完（Write 大文件时内建 read 逐字节读管道太慢），存进 qq_hook_input 的缓存：
# 会话 id 和 file_path 都从这里取（$(qq_hook_input …) 跑在子 shell 里，缓存必须先在这里建好）
if [[ -t 0 ]]; then _QQ_HOOK_INPUT_CACHE=""; else _QQ_HOOK_INPUT_CACHE="$(cat 2>/dev/null || true)"; fi

if [ "$(qq_hook_enabled auto_compile)" != "true" ]; then
  exit 0
fi

file_path="$(qq_hook_input tool_input.file_path)"
if [[ -z "$file_path" ]]; then
  exit 0
fi

PROJECT="$(qq_project_dir)"
if [[ "$($QQ_PY "$SCRIPT_DIR/qq_engine.py" matches-source --project "$PROJECT" "$file_path" 2>/dev/null || printf 'false\n')" != "true" ]]; then
  exit 0
fi

# 编译日志落临时文件，再整体转到 stderr：本钩子的 stdout 只能放下面那段 JSON。
# 日志和 JSON 混在 stdout 里时 Claude Code 不认 JSON，编译错误和门的提示从来没送到过模型。
COMPILE_LOG="$(mktemp "${QQ_TEMP_DIR:-/tmp}/qq-auto-compile.XXXXXX")"
trap 'rm -f "$COMPILE_LOG"' EXIT
COMPILE_EXIT=0
# 告诉编译脚本这次改的是哪个文件：Unity 官方 CLI 通道拿它判「recompile 回 up_to_date 是不是 Unity 没看见改动」。
# 用环境变量而不是参数：qq-compile.sh 会把参数原样传给 godot / unreal / sbox 的编译脚本，它们不认新参数。
export QQ_COMPILE_CHANGED_FILES="$file_path"
"$SCRIPT_DIR/qq-compile.sh" --project "$PROJECT" --timeout 15 >"$COMPILE_LOG" 2>&1 || COMPILE_EXIT=$?
cat "$COMPILE_LOG" >&2

# ── compile gate：按会话 + 项目写/清门文件（拿不到会话 id 就不建门，不退回全机共用的文件）──
# 何时立门、门里放行哪些文件、注入什么上下文，都在 qq_compile_gate.py record 里：只有编译脚本退 1 且
# 输出里有落在项目文件上的错误位置才立门；退 2（没拿到裁决）不立门也不清门。
# compile_gate 钩子关着时不立门（check 不会拦，再立门、再说「会被拒绝」就是骗模型），编译错误照样告诉它。
GATE_PREFIX=""
if qq_session_id && [ "$(qq_hook_enabled compile_gate)" = "true" ]; then
  GATE_PREFIX="$QQ_TEMP_DIR/compile-gate-$QQ_SESSION_ID"
fi
"$QQ_PY" "$SCRIPT_DIR/qq_compile_gate.py" record --project "$PROJECT" --gate-prefix "$GATE_PREFIX" \
  --file "$file_path" --exit-code "$COMPILE_EXIT" --log "$COMPILE_LOG" || true
