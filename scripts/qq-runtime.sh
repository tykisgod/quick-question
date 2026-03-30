#!/usr/bin/env bash
# qq-runtime.sh — runtime data helpers shared by qq shell scripts

qq_project_dir() {
    if [[ -n "${PROJECT_DIR:-}" ]]; then
        printf '%s\n' "$PROJECT_DIR"
        return
    fi
    git rev-parse --show-toplevel 2>/dev/null || pwd
}

qq_runtime_root() {
    printf '%s/.qq\n' "$(qq_project_dir)"
}

qq_runtime_runs_dir() {
    printf '%s/runs\n' "$(qq_runtime_root)"
}

qq_runtime_ensure() {
    mkdir -p "$(qq_runtime_root)/runs" "$(qq_runtime_root)/state" "$(qq_runtime_root)/telemetry"
}

qq_run_record_start() {
    local stage="$1"
    local command="$2"
    local backend="${3:-}"
    local transport="${4:-}"
    local summary="${5:-}"
    local extra_json="${6:-}"

    qq_runtime_ensure
    python3 "$(dirname "${BASH_SOURCE[0]}")/qq-run-record.py" start \
        --project "$(qq_project_dir)" \
        --stage "$stage" \
        --command "$command" \
        --backend "$backend" \
        --transport "$transport" \
        --summary "$summary" \
        ${extra_json:+--extra-json "$extra_json"}
}

qq_run_record_finish() {
    local run_id="$1"
    local status="$2"
    local failure_category="${3:-}"
    local summary="${4:-}"
    local extra_json="${5:-}"

    qq_runtime_ensure
    python3 "$(dirname "${BASH_SOURCE[0]}")/qq-run-record.py" finish \
        --project "$(qq_project_dir)" \
        --run-id "$run_id" \
        --status "$status" \
        ${failure_category:+--failure-category "$failure_category"} \
        ${summary:+--summary "$summary"} \
        ${extra_json:+--extra-json "$extra_json"}
}

qq_latest_run_json() {
    local stage="${1:-}"
    python3 "$(dirname "${BASH_SOURCE[0]}")/qq-run-record.py" latest \
        --project "$(qq_project_dir)" \
        ${stage:+--stage "$stage"} 2>/dev/null || true
}

qq_runtime_prune() {
    qq_runtime_ensure
    python3 "$(dirname "${BASH_SOURCE[0]}")/qq-run-record.py" prune \
        --project "$(qq_project_dir)" >/dev/null 2>&1 || true
}
