#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MODE="all"
FILTER=""
TIMEOUT_SEC=300

if [[ $# -gt 0 && "$1" != --* ]]; then
    MODE="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)
            PROJECT_DIR="$(cd "$2" && pwd)"
            shift 2
            ;;
        --filter)
            FILTER="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT_SEC="$2"
            shift 2
            ;;
        --timeout=*)
            TIMEOUT_SEC="${1#--timeout=}"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

source "$SCRIPT_DIR/godot-common.sh"
source "$SCRIPT_DIR/qq-runtime.sh"

if ! qq_is_godot_project "$PROJECT_DIR"; then
    echo "Error: $PROJECT_DIR is not a valid Godot project (project.godot not found)" >&2
    exit 1
fi

GODOT_BIN="$(qq_find_godot_binary || true)"
if [[ -z "$GODOT_BIN" ]]; then
    echo "Error: Godot binary not found. Set GODOT_BIN or install a godot/godot4 command." >&2
    exit 1
fi

BACKEND="$(qq_detect_godot_test_backend "$PROJECT_DIR")"
if [[ "$BACKEND" == "none" ]]; then
    echo "Error: no supported Godot test backend found. Install GUT or GdUnit4 under addons/." >&2
    exit 1
fi

case "$MODE" in
    all|gut|gdunit4) ;;
    *)
        MODE="all"
        ;;
esac

if [[ "$MODE" != "all" && "$MODE" != "$BACKEND" ]]; then
    echo "Error: requested backend '$MODE' is not available for this project (detected: $BACKEND)" >&2
    exit 1
fi

RUN_ID="$(qq_run_record_start "test" "godot-test" "$BACKEND" "godot-headless" "Godot test run started" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')"
TMP_OUTPUT="$(mktemp)"
trap 'rm -f "$TMP_OUTPUT"' EXIT

TEST_ROOT="test"
if [[ ! -d "$PROJECT_DIR/$TEST_ROOT" && -d "$PROJECT_DIR/tests" ]]; then
    TEST_ROOT="tests"
fi

set +e
STATUS=1
FINAL_STATUS="failed"
SUMMARY="Godot tests failed"

qq_import_godot_project "$PROJECT_DIR" "$GODOT_BIN" >>"$TMP_OUTPUT" 2>&1
if [[ $? -ne 0 ]]; then
    set -e
    cat "$TMP_OUTPUT"
    qq_run_record_finish "$RUN_ID" "failed" "import_failed" "Godot project import failed before running tests" >/dev/null
    exit 1
fi

if [[ "$BACKEND" == "gdunit4" ]]; then
    export GODOT_BIN
    RUNNER="$(qq_find_gdunit_runner "$PROJECT_DIR")"
    if [[ -n "$RUNNER" ]]; then
        if [[ -d "$PROJECT_DIR/$TEST_ROOT" ]]; then
            bash "$RUNNER" -a "$PROJECT_DIR/$TEST_ROOT" >>"$TMP_OUTPUT" 2>&1
        else
            bash "$RUNNER" >>"$TMP_OUTPUT" 2>&1
        fi
        STATUS=$?
    else
        TOOL_PATH="$(qq_find_gdunit_tool "$PROJECT_DIR")"
        if [[ -z "$TOOL_PATH" ]]; then
            printf 'GdUnit4 backend detected but no runner or tool script was found.\n' >>"$TMP_OUTPUT"
            STATUS=1
        else
            "$GODOT_BIN" --headless --path "$PROJECT_DIR" -s "$TOOL_PATH" >>"$TMP_OUTPUT" 2>&1
            STATUS=$?
        fi
    fi

    if [[ $STATUS -eq 0 ]]; then
        FINAL_STATUS="passed"
        SUMMARY="GdUnit4 tests passed"
    elif [[ $STATUS -eq 101 ]]; then
        FINAL_STATUS="warning"
        SUMMARY="GdUnit4 tests completed with warnings"
    fi
else
    GUT_ARGS=(--headless -d --path "$PROJECT_DIR" -s addons/gut/gut_cmdln.gd -gexit)
    if [[ -d "$PROJECT_DIR/$TEST_ROOT" ]]; then
        GUT_ARGS+=("-gdir=res://$TEST_ROOT")
        GUT_ARGS+=("-ginclude_subdirs")
    fi
    if [[ -n "$FILTER" ]]; then
        GUT_ARGS+=("-gselect=$FILTER")
    fi
    "$GODOT_BIN" "${GUT_ARGS[@]}" >>"$TMP_OUTPUT" 2>&1
    STATUS=$?
    if [[ $STATUS -eq 0 ]] && grep -q "Nothing was run." "$TMP_OUTPUT"; then
        STATUS=1
        SUMMARY="GUT did not discover any tests"
    elif [[ $STATUS -eq 0 ]]; then
        FINAL_STATUS="passed"
        SUMMARY="GUT tests passed"
    fi
fi

set -e

cat "$TMP_OUTPUT"

if [[ "$FINAL_STATUS" == "passed" || "$FINAL_STATUS" == "warning" ]]; then
    qq_run_record_finish "$RUN_ID" "$FINAL_STATUS" "" "$SUMMARY" >/dev/null
    echo "$SUMMARY (${TIMEOUT_SEC}s budget)"
    exit 0
fi

qq_run_record_finish "$RUN_ID" "failed" "test_failed" "$SUMMARY" >/dev/null
echo "$SUMMARY (${TIMEOUT_SEC}s budget)" >&2
exit 1
