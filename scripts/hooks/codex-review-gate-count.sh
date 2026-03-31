#!/usr/bin/env bash
# PostToolUse hook (Agent): gate 激活期间记录 subagent 完成数
# 按 $PPID 隔离：只更新本 session 的 gate
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
source "$(cd "$(dirname "$0")/.." && pwd)/qq-runtime.sh"

if [ "$(qq_hook_enabled review_gate)" != "true" ]; then
  exit 0
fi

GATE_FILE="$QQ_TEMP_DIR/claude-codex-review-gate-$PPID"
[[ -f "$GATE_FILE" ]] || exit 0

IFS=: read -r ts count < "$GATE_FILE"
new_count=$(( ${count:-0} + 1 ))
echo "${ts}:${new_count}" > "$GATE_FILE"

if [[ $new_count -eq 1 ]]; then
  run_json=$(qq_run_record_start "review_gate" "codex-review-gate-count" "local" "hook" "Review gate verification recorded")
  run_id=$(printf '%s' "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
  qq_run_record_finish "$run_id" "verified" "" "First verification subagent completed" "{\"verified_count\":$new_count}" >/dev/null
  cat <<'HOOK'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[CODEX-REVIEW-GATE] 已记录第 1 个验证 subagent 完成，Edit gate 放行。如果还有未验证的发现，继续开 subagent 完成全部验证。"}}
HOOK
fi
