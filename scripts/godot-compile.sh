#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TIMEOUT_SEC=60

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)
            PROJECT_DIR="$(cd "$2" && pwd)"
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

RUN_ID="$(qq_run_record_start "compile" "godot-compile" "godot-cli" "godot-headless" "Godot compile/check started" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')"
TMP_OUTPUT="$(mktemp)"
trap 'rm -f "$TMP_OUTPUT"' EXIT

set +e

qq_import_godot_project "$PROJECT_DIR" "$GODOT_BIN" >>"$TMP_OUTPUT" 2>&1
if [[ $? -ne 0 ]]; then
    set -e
    cat "$TMP_OUTPUT"
    qq_run_record_finish "$RUN_ID" "failed" "import_failed" "Godot project import failed" >/dev/null
    exit 1
fi

CSHARP_PROJECTS=()
while IFS= read -r csproj; do
    [[ -n "$csproj" ]] && CSHARP_PROJECTS+=("$csproj")
done < <(find "$PROJECT_DIR" -maxdepth 2 -type f -name '*.csproj' 2>/dev/null | sort)

if [[ ${#CSHARP_PROJECTS[@]} -gt 0 ]]; then
    if ! command -v dotnet >/dev/null 2>&1; then
        printf 'Godot C# project detected but dotnet is not installed.\n' | tee -a "$TMP_OUTPUT"
        qq_run_record_finish "$RUN_ID" "failed" "dotnet_missing" "Godot C# project requires dotnet" >/dev/null
        exit 1
    fi
    for csproj in "${CSHARP_PROJECTS[@]}"; do
        dotnet build "$csproj" -nologo >>"$TMP_OUTPUT" 2>&1
        if [[ $? -ne 0 ]]; then
            cat "$TMP_OUTPUT"
            qq_run_record_finish "$RUN_ID" "failed" "compile_failed" "dotnet build failed for Godot C# project" >/dev/null
            exit 1
        fi
    done
fi

"$GODOT_BIN" --headless --path "$PROJECT_DIR" -s "$PROJECT_DIR/scripts/godot-compile-check.gd" >>"$TMP_OUTPUT" 2>&1
STATUS=$?

set -e

cat "$TMP_OUTPUT"

if [[ $STATUS -ne 0 ]]; then
    qq_run_record_finish "$RUN_ID" "failed" "compile_failed" "Godot headless compile/check failed" >/dev/null
    exit 1
fi

qq_run_record_finish "$RUN_ID" "passed" "" "Godot compile/check passed" >/dev/null
echo "Godot compile/check passed (${TIMEOUT_SEC}s budget)"
