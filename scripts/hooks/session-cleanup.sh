#!/usr/bin/env bash
# Stop hook: clean up session temp files
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
source "$(cd "$(dirname "$0")/.." && pwd)/qq-runtime.sh"

rm -f "$QQ_TEMP_DIR/review-gate-$PPID"
qq_run_record_state_only "review_gate" "session-cleanup" "cleared" "Session cleanup removed review gate" >/dev/null
qq_runtime_prune
