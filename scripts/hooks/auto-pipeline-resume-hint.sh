#!/usr/bin/env bash
# SessionStart[compact] hook: inject auto-pipeline resume hint after context compaction.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/platform/detect.sh"
source "$SCRIPT_DIR/qq-runtime.sh"

PROJECT_DIR="$(qq_project_dir)"
PIPELINE_FILE="$PROJECT_DIR/.qq/state/auto-pipeline.json"
[ -f "$PIPELINE_FILE" ] || exit 0

HINT=$($QQ_PY "$SCRIPT_DIR/qq-execute-checkpoint.py" pipeline-status --project "$PROJECT_DIR" --format hint 2>/dev/null || true)
[ -n "$HINT" ] && echo "$HINT"
exit 0
