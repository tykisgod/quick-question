#!/usr/bin/env bash
# Stop hook: 验证未全部完成时阻止会话退出
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"

GATE_FILE="$QQ_TEMP_DIR/review-gate-$PPID"
[[ -f "$GATE_FILE" ]] || exit 0

IFS=: read -r ts count expected < "$GATE_FILE"

# 验证已全部完成或还没开始派（expected=0）→ 允许退出
if [[ ${expected:-0} -eq 0 || ${count:-0} -ge ${expected:-0} ]]; then
  exit 0
fi

echo "⛔ BLOCKED: 审阅验证未完成（${count:-0}/${expected:-0} subagent 已返回）。请等待剩余验证完成后再退出。" >&2
exit 1
