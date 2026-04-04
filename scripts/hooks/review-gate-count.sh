#!/usr/bin/env bash
# PostToolUse hook (Agent): gate 激活期间记录 subagent 完成数
# 按 $PPID 隔离：只更新本 session 的 gate
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
source "$(cd "$(dirname "$0")/.." && pwd)/qq-runtime.sh"

if [ "$(qq_hook_enabled review_gate)" != "true" ]; then
  exit 0
fi

GATE_FILE="$QQ_TEMP_DIR/review-gate-$PPID"
[[ -f "$GATE_FILE" ]] || exit 0

IFS=: read -r ts count expected < "$GATE_FILE"
new_count=$(( ${count:-0} + 1 ))
echo "${ts}:${new_count}:${expected}" > "$GATE_FILE"

if [[ ${expected:-0} -gt 0 && $new_count -eq ${expected:-0} ]]; then
  qq_run_record_state_only "review_gate" "review-gate-count" "verified" "All verification subagents completed" >/dev/null
  cat <<HOOK
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[REVIEW-GATE] 所有验证 subagent 已完成（${new_count}/${expected}），Edit gate 放行。"}}
HOOK
fi
