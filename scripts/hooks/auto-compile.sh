#!/usr/bin/env bash
# PostToolUse hook (Write|Edit): auto-compile engine source files when enabled by the active qq profile
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$SCRIPT_DIR/platform/detect.sh"
source "$SCRIPT_DIR/qq-runtime.sh"

if [ "$(qq_hook_enabled auto_compile)" != "true" ]; then
  exit 0
fi

file_path="$(jq -r '.tool_input.file_path // ""')"
if [[ -z "$file_path" ]]; then
  exit 0
fi

if [[ "$($QQ_PY "$SCRIPT_DIR/qq_engine.py" matches-source --project "$(qq_project_dir)" "$file_path" 2>/dev/null || printf 'false\n')" != "true" ]]; then
  exit 0
fi

COMPILE_EXIT=0
"$SCRIPT_DIR/qq-compile.sh" --project "$(qq_project_dir)" --timeout 15 || COMPILE_EXIT=$?

# ── compile gate: 写/清 gate 文件 ──
GATE_FILE="$QQ_TEMP_DIR/compile-gate-$PPID"
if [[ "$COMPILE_EXIT" -eq 0 ]]; then
  rm -f "$GATE_FILE"
else
  echo "$(date +%s):compile_failed" > "$GATE_FILE"
  cat <<HOOK
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"⛔ [COMPILE-GATE 已激活] 编译失败（exit $COMPILE_EXIT）。在编译恢复绿灯前，对引擎源文件的 Edit/Write 会被阻止。请先修复编译错误。"}}
HOOK
fi
