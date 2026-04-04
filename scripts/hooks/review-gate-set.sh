#!/usr/bin/env bash
# PostToolUse hook (Bash): 检测 review 脚本执行完毕后激活 gate
# Gate 文件: $QQ_TEMP_DIR/review-gate-<PPID>（按 session 隔离）
# Gate 文件格式: <unix_timestamp>:<completed>:<expected>
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
source "$(cd "$(dirname "$0")/.." && pwd)/qq-runtime.sh"

if [ "$(qq_hook_enabled review_gate)" != "true" ]; then
  exit 0
fi

cmd=$(jq -r '.tool_input.command // ""')

if echo "$cmd" | grep -qE '\./scripts/(code-review|plan-review|claude-review|claude-plan-review)\.sh'; then
  echo "$(date +%s):0:0" > "$QQ_TEMP_DIR/review-gate-$PPID"
  qq_run_record_state_only "review_gate" "review-gate-set" "locked" "Review gate activated after code review" >/dev/null
  cat <<'HOOK'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"⛔ [REVIEW-GATE 已激活] 流程强制要求：你必须对每个 [Critical] 和 [Moderate] 发现开 subagent 并行验证（subagent_type: general-purpose, model: opus）。在所有验证 subagent 完成前，Edit 工具对 .cs 和 Docs/*.md 文件会被阻止。这是机械约束，不是建议。"}}
HOOK
fi
