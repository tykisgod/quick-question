#!/usr/bin/env bash
# PostToolUse hook (Write|Edit): track skill file modifications
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"

jq -r '.tool_input.file_path' | {
  read -r f
  [[ $f == */.claude/commands/*.md || $f == */skills/*/SKILL.md ]] && {
    echo "$f" >> "$QQ_TEMP_DIR/claude-skill-modified-marker-$PPID"
    echo '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[skill-modified] Skill file change recorded. Will check for /qq:self-review before ending."}}'
  } || true
}
