#!/usr/bin/env bash
# PostToolUse hook (Write|Edit): auto-compile engine source files when enabled by the active qq profile
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$SCRIPT_DIR/platform/detect.sh"
source "$SCRIPT_DIR/qq-runtime.sh"

if [ "$(qq_hook_enabled auto_compile)" != "true" ]; then
  exit 0
fi

file_path="$(jq -r '.tool_input.file_path // ""')"
if [[ -z "$file_path" ]]; then
  exit 0
fi

if [[ "$(python3 "$SCRIPT_DIR/qq_engine.py" matches-source --project "$(qq_project_dir)" "$file_path" 2>/dev/null || printf 'false\n')" != "true" ]]; then
  exit 0
fi

"$SCRIPT_DIR/qq-compile.sh" --project "$(qq_project_dir)" --timeout 15 || true
