#!/usr/bin/env bash
# PostToolUse hook (Write|Edit): auto-compile engine source files when enabled by the active qq profile
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$SCRIPT_DIR/platform/detect.sh"
source "$SCRIPT_DIR/qq-runtime.sh"
qq_hook_read_stdin   # 内建读完 stdin：会话 id 和 file_path 都从这份缓存里取

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
COMPILE_EXIT=0
"$SCRIPT_DIR/qq-compile.sh" --project "$PROJECT" --timeout 15 >"$COMPILE_LOG" 2>&1 || COMPILE_EXIT=$?
cat "$COMPILE_LOG" >&2

# ── compile gate：按会话 id 写/清门文件（拿不到会话 id 就不建门，不退回全机共用的文件）──
# 何时立门、门里放行哪些文件、注入什么上下文，都在 qq_compile_gate.py record 里：只有编译脚本退 1 且
# 输出里有落在项目文件上的错误位置才立门；退 2（没拿到裁决）不立门也不清门。
GATE_FILE=""
if qq_session_id; then
  GATE_FILE="$QQ_TEMP_DIR/compile-gate-$QQ_SESSION_ID"
fi
"$QQ_PY" "$SCRIPT_DIR/qq_compile_gate.py" record --project "$PROJECT" --gate-file "$GATE_FILE" \
  --file "$file_path" --exit-code "$COMPILE_EXIT" --log "$COMPILE_LOG" || true
rm -f "$COMPILE_LOG"
