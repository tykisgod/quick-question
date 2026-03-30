#!/usr/bin/env bash
# PreToolUse hook (Edit|Write): gate 激活期间阻止修改代码/文档，直到有 subagent 验证
# 按 $PPID 隔离：只检查本 session 的 gate，不影响其他 session
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
source "$(cd "$(dirname "$0")/.." && pwd)/qq-runtime.sh"

GATE_FILE="$QQ_TEMP_DIR/claude-codex-review-gate-$PPID"
[[ -f "$GATE_FILE" ]] || exit 0

file_path=$(jq -r '.tool_input.file_path // ""')

# 只拦截相关文件类型
case "$file_path" in
  *.cs) ;;
  */Docs/*.md) ;;
  *) exit 0 ;;
esac

IFS=: read -r ts count < "$GATE_FILE"

# 超过 2 小时自动过期
now=$(date +%s)
age=$(( now - ${ts:-0} ))
if [[ $age -gt 7200 ]]; then
  rm -f "$GATE_FILE"
  exit 0
fi

# 没有 subagent 验证记录 → 阻止
if [[ ${count:-0} -eq 0 ]]; then
  run_json=$(qq_run_record_start "review_gate" "codex-review-gate-check" "local" "hook" "Review gate blocked edit")
  run_id=$(printf '%s' "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
  qq_run_record_finish "$run_id" "blocked" "review_verification_required" "Edit blocked until review findings are verified" >/dev/null
  echo "⛔ BLOCKED: Codex 审阅 gate 已激活，但尚未检测到验证 subagent。你必须先对 [严重] 和 [中等] 发现开 subagent 并行验证（subagent_type: general-purpose, model: opus），然后才能修改代码/文档。不要 rationalize 跳过这一步。" >&2
  exit 1
fi
