#!/usr/bin/env bash
# SessionStart hook [compact]: inject execute-progress resume hint after context compaction
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
source "$(cd "$(dirname "$0")/.." && pwd)/qq-runtime.sh"

PROGRESS_FILE="$(qq_project_dir)/.qq/state/execute-progress.json"
[ -f "$PROGRESS_FILE" ] || exit 0

STATUS=$($QQ_PY -c "
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
    print(d.get('status', ''))
except Exception:
    print('')
" "$PROGRESS_FILE")

[ "$STATUS" = "running" ] || [ "$STATUS" = "paused" ] || exit 0

$QQ_PY "$(dirname "${BASH_SOURCE[0]}")/../qq-execute-checkpoint.py" resume --project "$(qq_project_dir)" --format hint
