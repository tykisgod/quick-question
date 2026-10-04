#!/usr/bin/env bash
# PostToolUse hook (Write|Edit): track skill file modifications
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
source "$(cd "$(dirname "$0")/.." && pwd)/qq-runtime.sh"
qq_hook_read_stdin   # 内建读完 stdin：会话 id 和 file_path 都从这份缓存里取

# 标记文件按会话 id 命名，收尾时 check-skill-review.sh 只认本会话的标记。拿不到会话 id 就不记：
# 记进全机共用的文件，别的会话收尾时会被它拦住。
qq_session_id || exit 0

if [ "$(qq_hook_enabled skill_review)" != "true" ]; then
  exit 0
fi

f="$(qq_hook_input tool_input.file_path)"
if [[ -n "$f" && ( $f == */.claude/commands/*.md || $f == */skills/*/SKILL.md ) ]]; then
  echo "$f" >> "$QQ_TEMP_DIR/claude-skill-modified-marker-$QQ_SESSION_ID"
  run_json=$(qq_run_record_start "skill_gate" "skill-modified-track" "local" "hook" "Skill file modification tracked")
  run_id=$(printf '%s' "$run_json" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
  escaped_file=$(printf '%s' "$f" | $QQ_PY -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')
  qq_run_record_finish "$run_id" "warning" "skill_modified" "Skill modification recorded" "{\"file\":${escaped_file}}" >/dev/null
  echo '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[skill-modified] Skill file change recorded. Will check for /qq:self-review before ending."}}'
fi
