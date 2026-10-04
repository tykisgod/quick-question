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
# 标记按会话 id 命名，只看本会话的；拿不到会话 id 就放行（不去拦别的会话留下的标记）。
# 会话 id 先取环境变量 CLAUDE_CODE_SESSION_ID（钩子进程里也有），没有时才读 stdin 的 session_id。
qq_session_id || { qq_hook_read_stdin; qq_session_id; } || exit 0
MARKER="$QQ_TEMP_DIR/claude-skill-modified-marker-$QQ_SESSION_ID"
[ -f "$MARKER" ] || exit 0

# 有标记才读 stdin（下面的 stop_hook_active 也从这份缓存里取），并以 stdin 的 session_id 为准
qq_hook_read_stdin
qq_session_id || exit 0
MARKER="$QQ_TEMP_DIR/claude-skill-modified-marker-$QQ_SESSION_ID"
[ -f "$MARKER" ] || exit 0

source "$_qq_dir/qq-runtime.sh"

if [ "$(qq_hook_enabled skill_review)" != "true" ]; then
  exit 0
fi

# Prevent infinite loop: if already in stop hook, allow
# （qq_hook_input 走 jq 时布尔值打成 true，走 python 兜底时打成 True，两种都认）
STOP_ACTIVE="$(qq_hook_input stop_hook_active)"
if [[ "$STOP_ACTIVE" == "true" || "$STOP_ACTIVE" == "True" ]]; then
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
