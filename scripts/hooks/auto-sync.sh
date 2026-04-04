#!/usr/bin/env bash
# SessionStart hook [startup]: auto-sync project scripts after plugin upgrade
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -d "$PROJECT_DIR/.qq" ] || exit 0

$QQ_PY "$(dirname "${BASH_SOURCE[0]}")/../qq-auto-sync.py" \
  --project "$PROJECT_DIR" \
  --plugin-root "${CLAUDE_PLUGIN_ROOT}"
