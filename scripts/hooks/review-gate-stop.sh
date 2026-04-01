#!/usr/bin/env bash
# Stop hook: 验证未全部完成时阻止会话退出
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
source "$(cd "$(dirname "$0")/.." && pwd)/qq-runtime.sh"

if [ "$(qq_hook_enabled review_gate)" != "true" ]; then
  exit 0
fi

GATE_FILE="$QQ_TEMP_DIR/review-gate-$PPID"
[[ -f "$GATE_FILE" ]] || exit 0

IFS=: read -r _ts count expected < "$GATE_FILE"

# 验证已全部完成或还没开始派（expected=0）→ 允许退出
if [[ ${expected:-0} -eq 0 || ${count:-0} -ge ${expected:-0} ]]; then
  exit 0
fi

echo "{\"decision\":\"block\",\"reason\":\"BLOCKED: Review verification incomplete (${count:-0}/${expected:-0} subagents returned). You MUST wait for remaining verification subagents to finish before the session can end.\"}"
exit 0
