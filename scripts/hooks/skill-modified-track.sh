#!/usr/bin/env bash
# PostToolUse hook (Write|Edit): track skill file modifications
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
source "$(cd "$(dirname "$0")/.." && pwd)/qq-runtime.sh"

if [ "$(qq_hook_enabled skill_review)" != "true" ]; then
  exit 0
fi

jq -r '.tool_input.file_path' | {
  read -r f
  [[ $f == */.claude/commands/*.md || $f == */skills/*/SKILL.md ]] && {
    echo "$f" >> "$QQ_TEMP_DIR/claude-skill-modified-marker-$PPID"
    run_json=$(qq_run_record_start "skill_gate" "skill-modified-track" "local" "hook" "Skill file modification tracked")
    run_id=$(printf '%s' "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
    escaped_file=$(printf '%s' "$f" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')
    qq_run_record_finish "$run_id" "warning" "skill_modified" "Skill modification recorded" "{\"file\":${escaped_file}}" >/dev/null
    echo '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[skill-modified] Skill file change recorded. Will check for /qq:self-review before ending."}}'
  } || true
}
