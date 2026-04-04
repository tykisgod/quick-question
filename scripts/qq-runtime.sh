#!/usr/bin/env bash
# qq-runtime.sh — runtime data helpers shared by qq shell scripts

# Python compatibility
: "${QQ_PY:=python3}"
command -v "$QQ_PY" >/dev/null 2>&1 || QQ_PY="python"

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
    $QQ_PY "$(dirname "${BASH_SOURCE[0]}")/qq-run-record.py" start \
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
    $QQ_PY "$(dirname "${BASH_SOURCE[0]}")/qq-run-record.py" finish \
        --project "$(qq_project_dir)" \
        --run-id "$run_id" \
        --status "$status" \
        ${failure_category:+--failure-category "$failure_category"} \
        ${summary:+--summary "$summary"} \
        ${extra_json:+--extra-json "$extra_json"}

}

qq_latest_run_json() {
    local stage="${1:-}"
    $QQ_PY "$(dirname "${BASH_SOURCE[0]}")/qq-run-record.py" latest \
        --project "$(qq_project_dir)" \
        ${stage:+--stage "$stage"} 2>/dev/null || true
}

qq_runtime_prune() {
    qq_runtime_ensure
    $QQ_PY "$(dirname "${BASH_SOURCE[0]}")/qq-run-record.py" prune \
        --project "$(qq_project_dir)" >/dev/null 2>&1 || true
}

qq_project_state_json() {
    $QQ_PY "$(dirname "${BASH_SOURCE[0]}")/qq-project-state.py" \
        --project "$(qq_project_dir)" \
        --no-write 2>/dev/null || printf '{}\n'
}

qq_config_json() {
    $QQ_PY "$(dirname "${BASH_SOURCE[0]}")/qq-config.py" resolve \
        --project "$(qq_project_dir)" 2>/dev/null || printf '{}\n'
}

qq_config_field() {
    local field="$1"
    local payload
    payload="$(qq_config_json)"
    QQ_CONFIG_PAYLOAD="$payload" $QQ_PY - "$field" <<'PY'
import json
import os
import sys

field = sys.argv[1]
try:
    payload = json.loads(os.environ.get("QQ_CONFIG_PAYLOAD", "{}"))
except Exception:
    payload = {}

value = payload.get(field, "")
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False, sort_keys=True))
else:
    print(value)
PY
}

qq_engine() {
    local engine
    engine="$(qq_config_field "engine")"
    if [[ -n "$engine" ]]; then
        printf '%s\n' "$engine"
        return
    fi
    $QQ_PY "$(dirname "${BASH_SOURCE[0]}")/qq_engine.py" detect --project "$(qq_project_dir)" 2>/dev/null | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin).get("engine",""))' 2>/dev/null || printf '\n'
}

qq_project_state_field() {
    local field="$1"
    local payload
    payload="$(qq_project_state_json)"
    QQ_PROJECT_STATE_PAYLOAD="$payload" $QQ_PY - "$field" <<'PY'
import json
import os
import sys

field = sys.argv[1]
try:
    payload = json.loads(os.environ.get("QQ_PROJECT_STATE_PAYLOAD", "{}"))
except Exception:
    payload = {}

value = payload.get(field, "")
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False, sort_keys=True))
else:
    print(value)
PY
}

qq_policy_profile() {
    local profile
    profile="$(qq_config_field "policy_profile")"
    case "$profile" in
        core|feature|hardening)
            printf '%s\n' "$profile"
            ;;
        *)
            printf 'feature\n'
            ;;
    esac
}

qq_work_mode() {
    local mode
    mode="$(qq_config_field "work_mode")"
    case "$mode" in
        prototype|feature|fix|hardening)
            printf '%s\n' "$mode"
            ;;
        *)
            printf 'feature\n'
            ;;
    esac
}

qq_trust_level() {
    local level
    level="$(qq_config_field "trust_level")"
    case "$level" in
        trusted|balanced|strict)
            printf '%s\n' "$level"
            ;;
        *)
            printf 'trusted\n'
            ;;
    esac
}

qq_default_test_scope() {
    local scope
    scope="$(qq_config_field "default_test_scope")"
    case "$scope" in
        editmode|playmode|all|unit)
            printf '%s\n' "$scope"
            ;;
        *)
            if [ "$(qq_policy_profile)" = "core" ]; then
                printf 'editmode\n'
            else
                printf 'all\n'
            fi
            ;;
    esac
}

qq_active_profile() {
    local profile
    profile="$(qq_config_field "profile")"
    if [[ -n "$profile" ]]; then
        printf '%s\n' "$profile"
    else
        printf 'feature\n'
    fi
}

qq_hook_enabled() {
    local hook_name="$1"
    local value
    value="$($QQ_PY "$(dirname "${BASH_SOURCE[0]}")/qq-config.py" hook-enabled "$hook_name" --project "$(qq_project_dir)" 2>/dev/null || printf 'false\n')"
    case "$value" in
        true) printf 'true\n' ;;
        *) printf 'false\n' ;;
    esac
}

qq_skill_enabled() {
    local skill_name="$1"
    local value
    value="$($QQ_PY "$(dirname "${BASH_SOURCE[0]}")/qq-config.py" skill-enabled "$skill_name" --project "$(qq_project_dir)" 2>/dev/null || printf 'false\n')"
    case "$value" in
        true) printf 'true\n' ;;
        *) printf 'false\n' ;;
    esac
}

qq_is_managed_worktree() {
    local value
    value="$(qq_project_state_field "is_managed_worktree")"
    case "$value" in
        true) printf 'true\n' ;;
        *) printf 'false\n' ;;
    esac
}

qq_worktree_source_branch() {
    qq_project_state_field "worktree_source_branch"
}

qq_worktree_source_path() {
    qq_project_state_field "worktree_source_worktree_path"
}

qq_execute_checkpoint_save() {
    local plan="$1"
    local step="$2"
    local total="$3"
    local mode="$4"
    local phase="${5:-}"
    local step_title="${6:-}"
    local status="${7:-running}"

    $QQ_PY "$(dirname "${BASH_SOURCE[0]}")/qq-execute-checkpoint.py" save \
        --project "$(qq_project_dir)" \
        --plan "$plan" \
        --step "$step" \
        --total "$total" \
        --mode "$mode" \
        ${phase:+--phase "$phase"} \
        ${step_title:+--step-title "$step_title"} \
        --status "$status"
}

qq_execute_checkpoint_resume() {
    local format="${1:-json}"
    $QQ_PY "$(dirname "${BASH_SOURCE[0]}")/qq-execute-checkpoint.py" resume \
        --project "$(qq_project_dir)" \
        --format "$format"
}

qq_execute_checkpoint_clear() {
    local status="${1:-completed}"
    $QQ_PY "$(dirname "${BASH_SOURCE[0]}")/qq-execute-checkpoint.py" clear \
        --project "$(qq_project_dir)" \
        --status "$status"
}
