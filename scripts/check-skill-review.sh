#!/usr/bin/env bash
# check-skill-review.sh — Stop hook: block if skill files were modified but not reviewed
#
# Flow:
# 1. PostToolUse hook appends modified skill paths to a marker file
# 2. /qq-self-review deletes the marker file after review
# 3. This Stop hook checks if the marker file exists; if so, blocks

# Use $PWD (project dir where hook runs) to scope marker, matching PostToolUse hook
MARKER="/tmp/claude-skill-modified-$(echo "$PWD" | md5sum 2>/dev/null | cut -c1-8 || md5 -q -s "$PWD" | cut -c1-8)"

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
  echo "{\"decision\":\"block\",\"reason\":\"You modified skill files but haven't run /qq:self-review yet: ${MODIFIED_FILES}. Please run /qq:self-review first.\"}"
  exit 0
fi

# No unreviewed changes, allow
exit 0
