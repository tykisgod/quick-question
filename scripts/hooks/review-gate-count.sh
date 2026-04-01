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

if [[ $new_count -ge 1 ]] && [[ ${expected:-0} -eq 0 || $new_count -ge ${expected:-0} ]]; then
  run_json=$(qq_run_record_start "review_gate" "review-gate-count" "local" "hook" "Review gate verification recorded")
  run_id=$(printf '%s' "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
  qq_run_record_finish "$run_id" "verified" "" "All verification subagents completed" "{\"verified_count\":$new_count}" >/dev/null
  cat <<HOOK
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[REVIEW-GATE] 所有验证 subagent 已完成（${new_count}/${expected}），Edit gate 放行。"}}
HOOK
fi
