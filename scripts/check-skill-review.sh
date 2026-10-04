#!/usr/bin/env bash
# check-skill-review.sh — Stop hook: block if skill files were modified but not reviewed
#
# Flow:
# 1. PostToolUse hook appends modified skill paths to a marker file
# 2. /qq:self-review deletes the marker file after review
# 3. This Stop hook checks if the marker file exists; if so, blocks
_qq_self="${BASH_SOURCE[0]//\\//}"; [[ "$_qq_self" == */* ]] || _qq_self="./$_qq_self"
_qq_dir="${_qq_self%/*}"; [[ "$_qq_dir" == /* || "$_qq_dir" == [A-Za-z]:/* ]] || _qq_dir="$PWD/$_qq_dir"   # 纯 bash 取目录，不 fork；Claude Code 在 Windows 上用 C:/… 调钩子，盘符路径也是绝对路径
source "$_qq_dir/platform/detect.sh"

# 快路径：没有待审的 skill 改动标记就直接放行，不起 python 读配置、不起 jq 解析输入
# （每次收尾都会跑，机器一忙那串进程就超过 5 秒上限，2026-10-04 实测）。
MARKER="$QQ_TEMP_DIR/claude-skill-modified-marker-$PPID"
[ -f "$MARKER" ] || exit 0

source "$_qq_dir/qq-runtime.sh"

if [ "$(qq_hook_enabled skill_review)" != "true" ]; then
  exit 0
fi

# Read stdin (Stop hook input)
INPUT=$(cat)

# Prevent infinite loop: if already in stop hook, allow
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

# Check marker file
if [ -f "$MARKER" ]; then
  MODIFIED_FILES=$(sort -u "$MARKER" | tr '\n' ', ' | sed 's/,$//')
  echo "{\"decision\":\"block\",\"reason\":\"BLOCKED: Skill files modified without review: ${MODIFIED_FILES}. You MUST invoke /qq:self-review now (use the Skill tool with skill=qq:self-review) before the session can end.\"}"
  exit 0
fi

# No unreviewed changes, allow
exit 0
