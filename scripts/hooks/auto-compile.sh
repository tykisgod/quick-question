#!/usr/bin/env bash
# PostToolUse hook (Write|Edit): auto-compile C# when enabled by the active qq profile
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
source "$(cd "$(dirname "$0")/.." && pwd)/qq-runtime.sh"

if [ "$(qq_hook_enabled auto_compile)" != "true" ]; then
  exit 0
fi

file_path="$(jq -r '.tool_input.file_path // ""')"
case "$file_path" in
  *.cs) ;;
  *) exit 0 ;;
esac

"$(cd "$(dirname "$0")/.." && pwd)/unity-compile-smart.sh" --timeout 15 || true
