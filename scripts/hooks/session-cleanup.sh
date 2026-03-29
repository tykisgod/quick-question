#!/usr/bin/env bash
# Stop hook: clean up session temp files
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"

rm -f "$QQ_TEMP_DIR/claude-codex-review-gate-$PPID"
