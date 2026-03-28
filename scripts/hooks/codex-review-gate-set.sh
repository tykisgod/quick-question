#!/usr/bin/env bash
# PostToolUse hook (Bash): 检测 codex review 脚本执行完毕后激活 gate
# Gate 文件: /tmp/claude-codex-review-gate-<PPID>（按 session 隔离）
# Gate 文件格式: <unix_timestamp>:<agent_count>

cmd=$(jq -r '.tool_input.command // ""')

if echo "$cmd" | grep -qE '\./scripts/(code-review|plan-review)\.sh'; then
  echo "$(date +%s):0" > "/tmp/claude-codex-review-gate-$PPID"
  cat <<'HOOK'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"⛔ [CODEX-REVIEW-GATE 已激活] 流程强制要求：你必须对每个 [严重] 和 [中等] 发现开 subagent 并行验证（subagent_type: general-purpose, model: opus）。在至少 1 个验证 subagent 完成前，Edit 工具对 .cs 和 Docs/*.md 文件会被阻止。这是机械约束，不是建议。"}}
HOOK
fi
