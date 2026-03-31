#!/usr/bin/env bash
# Stop hook: clean up session temp files
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
source "$(cd "$(dirname "$0")/.." && pwd)/qq-runtime.sh"

rm -f "$QQ_TEMP_DIR/claude-codex-review-gate-$PPID"
run_json=$(qq_run_record_start "review_gate" "session-cleanup" "local" "hook" "Review gate cleanup")
run_id=$(printf '%s' "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
qq_run_record_finish "$run_id" "cleared" "" "Session cleanup removed review gate" >/dev/null
qq_context_capsule_maybe_build "pre_clear" >/dev/null
qq_runtime_prune
